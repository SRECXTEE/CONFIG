#!/bin/bash
# RDK X5 音频自配置 - 卸载工具
set -e

SERVICE_DEST="$HOME/.config/systemd/user/rdkx5-audio.service"

echo "正在卸载 rdkx5-audio service..."

if systemctl --user is-enabled rdkx5-audio.service >/dev/null 2>&1; then
    systemctl --user disable --now rdkx5-audio.service || true
    echo "[OK] 已停止并禁用 service"
fi

if [ -f "$SERVICE_DEST" ]; then
    rm -f "$SERVICE_DEST"
    echo "[OK] 已删除 $SERVICE_DEST"
fi

systemctl --user daemon-reload

echo
read -rp "是否同时关闭 linger？(开机时不再自动启动用户服务) [y/N]: " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    sudo loginctl disable-linger "$USER"
    echo "[OK] 已关闭 linger"
fi

echo
echo "卸载完成。配置文件 audio.conf 保留在原目录，如需彻底删除请手动 rm。"
