# RDK X5 WiFi 配网系统

## 简介

RDK X5 作为机器人主控，通常没有键盘、鼠标、显示器。这套系统通过 **AP 热点 + 手机配网页** 的方式，让用户用手机即可完成 WiFi 配置。

## 工作流程

```
开机 → 检测默认路由 → 已连接? → 退出,不操作
                        ↓ 未连接
                  开启AP热点 "RDK-X5-Setup-XXXX"
                        ↓
                  手机连接热点 → 自动弹出配网页面
                        ↓
                  扫描周边WiFi → 选择目标 → 输入密码
                        ↓
                  自动连接 → 保存配置 → 关闭热点
```

## 文件说明

| 文件 | 作用 |
|------|------|
| `wifi_config.py` | Flask 主程序，提供配网页面和 REST API |
| `ap_manager.py` | AP 模式管理，启停 hostapd / dnsmasq / iptables |
| `status_led.py` | LED 状态指示（慢闪=等待配网，常亮=连接成功） |
| `start_wifi_setup.sh` | systemd 入口脚本，编排整个配网流程 |
| `stop_wifi_setup.sh` | systemd 停止脚本，清理 AP 模式 |
| `install.sh` | 一键部署脚本 |
| `hostapd.conf` | hostapd 配置模板 |
| `dnsmasq.conf` | dnsmasq 配置模板（DHCP + DNS 劫持） |
| `wifi-setup.service` | systemd 服务单元 |
| `templates/index.html` | 手机配网页面（单文件，内嵌 CSS/JS） |

## 部署

在 RDK X5 上执行：

```bash
sudo bash install.sh
sudo reboot
```

重启后如果没有联网，手机可搜索到 `RDK-X5-Setup-XXXX` 热点，连接即可配网。

## 重新配网

如需更换 WiFi，在 X5 终端执行：

```bash
sudo systemctl start wifi-setup
```

或先删除已保存的 WiFi 后重启：

```bash
nmcli connection delete <WiFi名称>
sudo reboot
```

## 查看日志

```bash
sudo journalctl -u wifi-setup -f
```

## 依赖

- Python 3 + Flask
- hostapd
- dnsmasq
- NetworkManager (nmcli)
- iptables