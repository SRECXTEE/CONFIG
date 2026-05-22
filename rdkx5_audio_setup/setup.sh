#!/bin/bash
# RDK X5 音频自配置 - 交互式初始化工具
# 用法：./setup.sh
# 作用：扫描音频设备 -> 用户选择 -> 写配置 -> 注册开机自启

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="$SCRIPT_DIR/audio.conf"
SERVICE_TEMPLATE="$SCRIPT_DIR/rdkx5-audio.service"
SERVICE_DEST="$HOME/.config/systemd/user/rdkx5-audio.service"

echo "================================================"
echo "  RDK X5 音频自配置工具"
echo "================================================"
echo

# ---------- 1. 依赖检查 ----------
if ! command -v pactl >/dev/null 2>&1; then
    echo "[错误] 未找到 pactl，请先安装：sudo apt install pulseaudio-utils"
    exit 1
fi

if ! pactl info >/dev/null 2>&1; then
    echo "[错误] PulseAudio 未运行，请先启动音频服务后重试"
    exit 1
fi

# ---------- 工具函数：从设备完整名提取关键字 ----------
# 示例：
#   alsa_output.usb-Generic_USB2.0_Device_20170726905923-01.analog-stereo
#   -> USB2.0_Device
#   alsa_input.usb-Generic_AB13X_USB_Audio_20210926172016-00.mono-fallback
#   -> AB13X
#   alsa_output.platform-snd0.stereo-fallback
#   -> platform-snd0
extract_keyword() {
    local full="$1"
    # 去掉 alsa_output. / alsa_input. 前缀
    local body="${full#alsa_output.}"
    body="${body#alsa_input.}"
    # 去掉常见后缀（profile 部分）
    body="${body%.analog-stereo}"
    body="${body%.analog-stereo.monitor}"
    body="${body%.mono-fallback}"
    body="${body%.stereo-fallback}"
    body="${body%.stereo-fallback.monitor}"
    body="${body%.iec958-stereo}"
    # 如果是 USB 设备 (usb-Generic_XXX_YYY-NN)，提取核心型号
    # 模式：usb-厂商_型号_序列号-端口
    if [[ "$body" =~ ^usb-[^_]+_([^_]+(_[^_]+)*)_[0-9]+-[0-9]+ ]]; then
        # 取厂商后第一段到序列号前
        local mid="${body#usb-*_}"     # 去掉 usb-厂商_
        mid="${mid%_*-*}"              # 去掉 _序列号-端口
        # 进一步精简：取最有标识性的那段（一般是第一个单词）
        echo "${mid%%_*}"
        return
    fi
    # 非 USB（如板载）直接返回主体
    echo "$body"
}

# ---------- 工具函数：拿到设备的 Description（便于用户辨认）----------
get_description() {
    local list_cmd="$1"   # "sinks" or "sources"
    local name="$2"
    pactl list "$list_cmd" | awk -v n="$name" '
        $1=="Name:" && $2==n { found=1; next }
        found && /Description:/ {
            sub(/^[ \t]*Description:[ \t]*/, "")
            print
            exit
        }
    '
}

# ---------- 2. 列出 sinks（输出/扬声器）----------
echo "=== 可用的【输出设备 / 扬声器】 ==="
mapfile -t SINKS < <(pactl list sinks short | awk '{print $2}')
if [ "${#SINKS[@]}" -eq 0 ]; then
    echo "[错误] 未发现任何输出设备"
    exit 1
fi
for i in "${!SINKS[@]}"; do
    desc=$(get_description sinks "${SINKS[$i]}")
    printf "  [%d] %s\n       描述: %s\n" "$i" "${SINKS[$i]}" "$desc"
done
echo
read -rp "请选择【输出设备】编号 (0-$((${#SINKS[@]}-1))): " SINK_IDX
if ! [[ "$SINK_IDX" =~ ^[0-9]+$ ]] || [ "$SINK_IDX" -ge "${#SINKS[@]}" ]; then
    echo "[错误] 无效的编号"
    exit 1
fi
SELECTED_SINK="${SINKS[$SINK_IDX]}"
SINK_KW=$(extract_keyword "$SELECTED_SINK")
echo "已选择：$SELECTED_SINK"
echo "提取关键字：$SINK_KW"
echo

# ---------- 3. 列出 sources（输入/麦克风），排除 .monitor ----------
echo "=== 可用的【输入设备 / 麦克风】 ==="
mapfile -t SOURCES < <(pactl list sources short | awk '{print $2}' | grep -v '\.monitor$')
if [ "${#SOURCES[@]}" -eq 0 ]; then
    echo "[错误] 未发现任何输入设备"
    exit 1
fi
for i in "${!SOURCES[@]}"; do
    desc=$(get_description sources "${SOURCES[$i]}")
    printf "  [%d] %s\n       描述: %s\n" "$i" "${SOURCES[$i]}" "$desc"
done
echo
read -rp "请选择【输入设备】编号 (0-$((${#SOURCES[@]}-1))): " SRC_IDX
if ! [[ "$SRC_IDX" =~ ^[0-9]+$ ]] || [ "$SRC_IDX" -ge "${#SOURCES[@]}" ]; then
    echo "[错误] 无效的编号"
    exit 1
fi
SELECTED_SRC="${SOURCES[$SRC_IDX]}"
SRC_KW=$(extract_keyword "$SELECTED_SRC")
echo "已选择：$SELECTED_SRC"
echo "提取关键字：$SRC_KW"
echo

# ---------- 4. 写配置文件 ----------
cat > "$CONF_FILE" <<EOF
# RDK X5 音频配置 - 由 setup.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 修改后可手动重启服务生效：
#   systemctl --user restart rdkx5-audio.service
#
# 关键字会用 grep 模糊匹配 pactl list sinks/sources 的设备名
SINK_KEYWORD="$SINK_KW"
SOURCE_KEYWORD="$SRC_KW"
EOF
echo "[OK] 已写入配置：$CONF_FILE"

# ---------- 5. 部署 systemd user service ----------
mkdir -p "$(dirname "$SERVICE_DEST")"
sed "s|@SCRIPT_DIR@|$SCRIPT_DIR|g" "$SERVICE_TEMPLATE" > "$SERVICE_DEST"
echo "[OK] 已部署 service：$SERVICE_DEST"

systemctl --user daemon-reload
systemctl --user enable rdkx5-audio.service >/dev/null 2>&1
systemctl --user restart rdkx5-audio.service
echo "[OK] 已启用并立即执行一次配置"

# ---------- 6. 启用 linger（无头模式必需）----------
if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
    echo
    echo "需要 sudo 权限启用 linger（让用户服务在开机时不依赖登录启动）"
    sudo loginctl enable-linger "$USER"
    echo "[OK] 已启用 linger"
else
    echo "[OK] linger 已是启用状态"
fi

# ---------- 7. 验证 ----------
sleep 1
echo
echo "=== 配置完成，当前默认设备 ==="
pactl info | grep -E "Default Sink|Default Source"
echo
echo "建议测试："
echo "  扬声器:  speaker-test -t sine -f 440 -l 1"
echo "  麦克风:  arecord -d 3 /tmp/t.wav && aplay /tmp/t.wav"
echo
echo "如需更换设备，重新运行：cd $SCRIPT_DIR && ./setup.sh"
