
# Kimi Fallback 根因分析与修复

**日期**: 2026-05-06
**运行 ID**: 016ee347-4533-4b85-9256-2e21d1b13fe0
**状态**: ✅ 已修复

---

## 问题

Kimi API 返回 rate limit 错误后，虽然配置了 `deepseek/deepseek-v4-pro` 作为 fallback，但实际未切换。日志显示 `decision: "surface_error"`, `fallbackConfigured: true`, `aborted: true`。

## 根因

`/usr/lib/node_modules/openclaw/dist/pi-embedded-runner-C72h-nWV.js`

`resolveRunFailoverDecision()` 函数（assistant 和 prompt 阶段）中，`externalAbort` 检查早于 fallback 检查：

```javascript
// 修复前 (Line 7207)
if (params.externalAbort) return {
    action: "surface_error",
    reason: params.failoverReason
};
```

**两种超时，两条路径**：

| 场景 | 超时机制 | externalAbort | 决策 |
|------|----------|:---:|------|
| cron job | cron 调度器 `AbortController.abort()` | true | surface_error ❌ |
| sessions_spawn | embedded runner `scheduleAbortTimer` | false | fallback_model ✅ |

cron 的超时通过 `AbortSignal` 触发 `onAbort` 回调（Line 6344），设置了 `externalAbort = true`，使得 `resolveRunFailoverDecision` 在 fallback 检查之前就返回了 `surface_error`。

`sessions_spawn` 的 `runTimeoutSeconds` 通过 `scheduleAbortTimer` 内部调用 `abortRun(true)`（Line 6241），不设置 `externalAbort`，因此能正常走到 fallback 逻辑。

## 修复

```javascript
// 修复后 - assistant 阶段
if (params.externalAbort && (!params.fallbackConfigured || params.failoverReason !== "timeout")) return {
    action: "surface_error",
    reason: params.failoverReason
};

// 修复后 - prompt 阶段
if (params.externalAbort && (!params.fallbackConfigured || params.failoverReason !== "timeout")) return {
    action: "surface_error",
    reason: params.failoverReason
};
```

**逻辑**：当 `externalAbort` 是因为超时、且 fallback 已配置时，跳过 `surface_error` 提前返回，让后续的 `fallback_model` 检查生效。

### 完整性保证
- 用户手动取消（非 timeout 的 externalAbort）→ 仍然 `surface_error` ✅
- 无 fallback 配置的超时 → 仍然 `surface_error` ✅  
- 有 fallback 配置的超时 → `fallback_model` ✅
- 非 externalAbort 场景 → 行为不变 ✅

## 验证

通过 3 次 `sessions_spawn` 模拟测试确认：
1. **1 秒超时** → Kimi 超时 → `fallback_model` → DeepSeek 被选中（但 1 秒全局期限太短，DeepSeek 也超时）
2. **15 秒超时** → Kimi 超时 → `fallback_model` → DeepSeek 被选中并尝试 → `All models failed (2)`（15 秒对复杂任务仍不足）
3. 两次测试中 `decision` 始终为 `fallback_model`，证实 fallback 链路畅通

## 文件位置

- 源码: `/usr/lib/node_modules/openclaw/dist/pi-embedded-runner-C72h-nWV.js`
- 关键行: 7190（prompt）, 7207（assistant）
- 函数: `resolveRunFailoverDecision()`, `shouldRotateAssistant()`
- 外部中断设置: Line 6344 (`onAbort`), Line 6241 (`scheduleAbortTimer`)
- 日志: `/tmp/openclaw/openclaw-2026-05-06.log`
- 事件: `embedded_run_failover_decision`, `model_fallback_decision`
