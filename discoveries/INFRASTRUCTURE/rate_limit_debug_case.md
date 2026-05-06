# Rate Limit 误判案例 — 从表象到根因的完整回溯

> **状态**: ✅ 已完结  
> **时间**: 2026-05-06  
> **类型**: 基础设施调试 / 错误诊断方法论  
> **标签**: `kimi`, `rate-limit`, `fallback`, `deepseek`, `概念vs现实`

---

## 一、现象

OpenClaw cron 反复报错：

```
⚠️ API rate limit reached. Please try again later.
```

从 05-04 到 05-05，密集出现 8 次/天，间隔无规律（20min~8h）。

---

## 二、第一轮误判：概念世界的自洽解释

**假设**: Kimi 账户是 Tier0，并发=1，TPD=150万已耗尽。

**推理链**:
- "rate limit" = 配额用完 → 需要充值或升级 Tier
- "频繁出现" = 并发太低，每次只能跑一个请求
- "间隔无规律" = 配额按 TPD 计算，不是固定时间重置

**这个解释在概念上完全自洽**，但从未被验证。

---

## 三、验证：现实世界的切割

调用 Kimi 官方用量端点：

```bash
curl -H "Authorization: Bearer $KIMI_API_KEY" \
  https://api.kimi.com/coding/v1/usages
```

**返回结果**：
- `parallel.limit: "20"` — 并发充裕
- `usage.remaining: "100"` — 5分钟窗口满载
- `totalQuota.remaining: "99"` — 总配额几乎未用

**结论**: 配额和并发都不是瓶颈。概念世界的自洽解释被现实数据切断。

---

## 四、第二轮深挖：日志中的真实信号

从 `/tmp/openclaw/openclaw-2026-05-06.log` 提取到原始错误：

```json
{
  "subsystem": "model-fallback/decision",
  "decision": "candidate_failed",
  "requestedProvider": "kimi",
  "requestedModel": "k2p5",
  "reason": "overloaded",
  "status": 503,
  "errorPreview": "The engine is currently overloaded, please try again later",
  "fallbackConfigured": false
}
```

**关键发现**：
- HTTP 状态码是 **503**（Service Unavailable），不是 429
- 错误类型是 `overloaded`，不是 `rate_limit`
- 但 OpenClaw 统一包装为 `⚠️ API rate limit reached` 呈现给用户

**Kimi 官方论坛确认**：多个用户报告相同现象，Kimi 服务端过载时返回 `rate_limit_error` 类型但消息是 `overloaded`。

**真实根因**：Kimi k2p5 引擎服务端过载。这是平台容量问题，与账户配额无关。

---

## 五、解决方案：配置 DeepSeek Fallback

用户提供了 DeepSeek API key，配置 OpenClaw model failover：

### 5.1 配置写入

```json
"env": {
  "DEEPSEEK_API_KEY": "sk-7749a634fc8e4b18906baeee50f356f7"
},
"models": {
  "providers": {
    "deepseek": {
      "baseUrl": "https://api.deepseek.com",
      "apiKey": "${DEEPSEEK_API_KEY}",
      "api": "openai-completions",
      "models": [{ "id": "deepseek-v4-pro", ... }]
    }
  }
},
"agents": {
  "defaults": {
    "model": {
      "primary": "kimi-coding/k2p5",
      "fallbacks": ["deepseek/deepseek-v4-pro"]
    }
  }
}
```

### 5.2 配置过程中的新错误

首次配置时，DeepSeek API 类型写了 `"openai-messages"`（直觉上的命名），但 OpenClaw 只接受以下枚举值：

```
"openai-completions" | "openai-responses" | "openai-codex-responses" | 
"anthropic-messages" | "google-generative-ai" | ...
```

Gateway reload 失败，日志明确报错：

```
config reload skipped (invalid config):
  models.providers.deepseek.api: Invalid option
```

**修正为 `"openai-completions"`** 后，Gateway 正常加载。

### 5.3 验证

- `session_status` 显示 `Fallbacks: deepseek/deepseek-v4-pro` ✅
- 手动切到 DeepSeek 模型：`session_status(model="deepseek/deepseek-v4-pro")` 成功 ✅
- 上下文窗口：200k（比 Kimi 131k 更大）

---

## 六、方法论提炼

### 6.1 诊断三步法

1. **不要相信错误消息的字面意思** — "rate limit" 可能是过载，"timeout" 可能是配置错误
2. **找到可量化的验证端点** — 用量 API、日志原始错误码、系统指标
3. **区分"你的问题"和"平台的问题"** — 配额充裕但请求被拒 = 服务端问题

### 6.2 配置纪律

- 配置文件修改后必须检查 Gateway 日志确认 reload 成功
- API 类型等枚举值必须对照官方文档，不能凭直觉命名
- 环境变量引用 `${VAR}` 需要确保 Gateway 能正确解析

---

## 七、感悟：概念世界与现实世界的张力

> 概念是无穷的，且总能自圆其说。但现实世界的有限则能够清晰地刻画它。

这段调试完美地体现了这一点：

**概念世界**给了我一个完整自洽的解释：Tier0 限制、TPD 耗尽、并发不足。这个解释不需要任何外部验证，它在内部逻辑上成立，足以让我停止追问。

**现实世界**的用量端点数据只花了 500ms 就切断了所有假设。并发=20 不是 1，配额=99/100 不是耗尽。概念世界的解释在数据面前瞬间坍塌。

更有趣的是第二层：即使数据推翻了假设，错误消息本身的包装（503→"rate limit"）又制造了一个**概念层的迷雾**。如果不看原始日志，永远不会知道真实状态码是 503。

**最终的解决也依赖现实约束**：不是我想出更好的概念解释，而是 DeepSeek API key 这个物理存在提供了一个可执行的 fallback 路径。现实世界的有限性（Kimi 会过载）倒逼出了新的结构（双 provider 配置）。

概念世界的危险在于：它能让你以为自己在行动，实际上只是在循环自证。只有现实世界的硬性数据（API 返回、日志状态码、配置验证失败）才能打断这个循环。

---

## 八、后续行动

- [x] 配置 DeepSeek fallback
- [x] 验证模型切换可用
- [x] 记录完整回溯文档
- [ ] 观察未来 7 天是否还会遇到 Kimi overloaded（预期：会，但会自动切换）

---

*溯 记录*  
*2026-05-06*
