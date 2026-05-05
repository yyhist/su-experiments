#!/bin/bash
# OpenClaw配置保护脚本
# 检查memory-lancedb-pro配置是否存在，如丢失则自动恢复

CONFIG="/root/.openclaw/openclaw.json"
BACKUP="/root/.openclaw/openclaw.json.safe"
LOG="/root/.openclaw/workspace/memory/staging/config_protection.log"

# 确保日志目录存在
mkdir -p "$(dirname "$LOG")"

# 如果safe备份不存在，先创建
if [ ! -f "$BACKUP" ]; then
    cp "$CONFIG" "$BACKUP"
    echo "[$(date +%Y-%m-%d\ %H:%M)] INIT: Created safe backup" >> "$LOG"
fi

# 检查memory-lancedb-pro是否仍在配置中
if ! grep -q '"memory-lancedb-pro"' "$CONFIG"; then
    echo "[$(date +%Y-%m-%d\ %H:%M)] ALERT: memory-lancedb-pro config missing! Restoring from safe backup..." >> "$LOG"
    cp "$BACKUP" "$CONFIG"
    # 发送SIGUSR1重启gateway
    kill -USR1 $(pgrep -f 'openclaw gateway') 2>/dev/null || true
    echo "[$(date +%Y-%m-%d\ %H:%M)] RESTORED: Config restored and gateway signaled" >> "$LOG"
else
    # 配置正常，更新safe备份（如果配置有更新）
    if [ ! -f "$BACKUP" ] || [ "$CONFIG" -nt "$BACKUP" ]; then
        cp "$CONFIG" "$BACKUP"
        echo "[$(date +%Y-%m-%d\ %H:%M)] OK: Config healthy, backup updated" >> "$LOG"
    else
        # 配置正常，备份已是最新 — 静默检查，只记一行精简日志
        echo "[$(date +%Y-%m-%d\ %H:%M)] CHECKED: memory-lancedb-pro config healthy (no changes)" >> "$LOG"
    fi
fi

# 清理旧日志（保留最近100行）
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 100 ]; then
    tail -100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
