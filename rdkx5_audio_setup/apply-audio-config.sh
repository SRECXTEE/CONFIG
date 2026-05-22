#!/bin/bash
# RDK X5 音频自配置 - 运行时应用脚本
# 由 systemd user service 在开机时自动调用
# 也可手动执行用于测试

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="$SCRIPT_DIR/audio.conf"

if [ ! -f "$CONF_FILE" ]; then
    echo "[错误] 配置文件不存在：$CONF_FILE"
    echo "请先运行 ./setup.sh"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# ---------- 等 PulseAudio 就绪（开机时可能还没起来）----------
for i in {1..30}; do
    if pactl info >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! pactl info >/dev/null 2>&1; then
    echo "[错误] PulseAudio 在 30 秒内未就绪，放弃"
    exit 1
fi

# ---------- 设置默认输出 sink ----------
if [ -n "$SINK_KEYWORD" ]; then
    sink=$(pactl list sinks short | awk '{print $2}' | grep -- "$SINK_KEYWORD" | head -1 || true)
    if [ -n "$sink" ]; then
        pactl set-default-sink "$sink"
        # 把已有的播放流迁移过去
        pactl list sink-inputs short 2>/dev/null | awk '{print $1}' | \
            xargs -rI{} pactl move-sink-input {} "$sink" 2>/dev/null || true
        echo "[OK] 默认输出 -> $sink"
    else
        echo "[警告] 未找到匹配关键字 '$SINK_KEYWORD' 的输出设备"
    fi
fi

# ---------- 设置默认输入 source ----------
if [ -n "$SOURCE_KEYWORD" ]; then
    source=$(pactl list sources short | awk '{print $2}' | \
        grep -- "$SOURCE_KEYWORD" | grep -v '\.monitor$' | head -1 || true)
    if [ -n "$source" ]; then
        pactl set-default-source "$source"
        pactl list source-outputs short 2>/dev/null | awk '{print $1}' | \
            xargs -rI{} pactl move-source-output {} "$source" 2>/dev/null || true
        echo "[OK] 默认输入 -> $source"
    else
        echo "[警告] 未找到匹配关键字 '$SOURCE_KEYWORD' 的输入设备"
    fi
fi
