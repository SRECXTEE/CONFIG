# RDK X5 音频自动配置工具

> 解决 RDK X5（Ubuntu 22.04 + PulseAudio）开机时默认音频设备选错的问题，支持**无显示器无键鼠**部署场景。

## 背景

RDK X5 默认使用 PulseAudio 管理音频。当同时存在多个声卡（板载 ES8326 + 多个 USB 音频设备）时，PulseAudio 经常会把默认输出/输入指向错误的设备。例如本项目针对的典型场景：

- 板载声卡（`platform-snd0`）通过 3.5mm 接口连接扬声器
- USB 麦克风（如 AB13X）插在 USB 口
- 开机后默认输出被路由到 USB 麦克风（该设备硬件无扬声器） → **扬声器无声**

更糟糕的是，某些 USB 音频芯片会在固件中**虚假上报** playback 能力，导致无法通过 ALSA 层面（`aplay -l`）或 PulseAudio 端口属性自动判断真实设备角色。

## 解决思路

放弃自动判断，改为**首次手动选择 + 持久化配置 + 开机自动应用**：

1. 用户跑一次交互式工具 `setup.sh`，从列出的设备里选自己的扬声器和麦克风
2. 工具提取设备名中的关键字（如 `USB2.0_Device`、`AB13X`、`platform-snd0`）写入 `audio.conf`
3. 注册 systemd user service，开机时自动按配置调用 `pactl set-default-sink/source`
4. 通过 `loginctl enable-linger` 让用户服务在**无登录**情况下也能开机自启

更换硬件时，只需重新跑一次 `setup.sh` 即可。

## 文件清单

| 文件 | 作用 |
|---|---|
| `setup.sh` | 交互式初始化工具（首次配置 / 换设备时跑） |
| `apply-audio-config.sh` | 运行时应用配置的脚本（由 systemd 调用，也可手动跑） |
| `rdkx5-audio.service` | systemd user service 模板（`@SCRIPT_DIR@` 占位符会被 setup.sh 替换为实际路径） |
| `audio.conf` | 由 `setup.sh` 生成的配置文件（`SINK_KEYWORD` / `SOURCE_KEYWORD`） |
| `uninstall.sh` | 卸载工具（停服务 + 删 service 文件 + 可选关闭 linger） |
| `README.md` | 本说明文档 |

## 环境要求

- RDK X5 / Ubuntu 22.04（或其他基于 systemd + PulseAudio 的 Linux 发行版）
- 已安装 `pulseaudio-utils`（提供 `pactl` 命令）
  ```bash
  sudo apt update && sudo apt install -y pulseaudio-utils alsa-utils
  ```
- 用户有 sudo 权限（仅 `setup.sh` 中调用 `loginctl enable-linger` 时需要）

## 快速开始

### 1. 把文件夹推到 RDK X5

```bash
# 在你的电脑上
scp -r rdkx5_audio_setup/ sunrise@<RDK X5 的 IP>:/home/sunrise/Desktop/
```

### 2. 在 RDK X5 上首次配置

```bash
ssh sunrise@<RDK X5 的 IP>
cd ~/Desktop/rdkx5_audio_setup
chmod +x setup.sh apply-audio-config.sh uninstall.sh
./setup.sh
```

按提示输入数字选择：

```
=== 可用的【输出设备 / 扬声器】 ===
  [0] alsa_output.platform-snd0.stereo-fallback
       描述: Built-in Audio Stereo
  [1] alsa_output.usb-Generic_AB13X_USB_Audio_...
       描述: AB13X USB Audio Analog Stereo
  [2] alsa_output.usb-Generic_USB2.0_Device_...
       描述: USB2.0 Device Analog Stereo

请选择【输出设备】编号 (0-2): 2

=== 可用的【输入设备 / 麦克风】 ===
  [0] alsa_input.platform-snd0.stereo-fallback
       描述: Built-in Audio Stereo
  [1] alsa_input.usb-Generic_AB13X_USB_Audio_...
       描述: AB13X USB Audio Mono

请选择【输入设备】编号 (0-1): 1
```

工具会自动完成：

- ✅ 写入配置 `audio.conf`
- ✅ 部署 systemd user service 到 `~/.config/systemd/user/rdkx5-audio.service`
- ✅ 启用 service（开机自启 + 立即执行一次）
- ✅ 启用 linger（首次需要 sudo 密码）

## 验证

```bash
# 看默认设备是否正确
pactl info | grep -E "Default Sink|Default Source"

# 扬声器测试（应能听到 1 秒的 440Hz 正弦波）
speaker-test -t sine -f 440 -l 1

# 麦克风测试（录3秒后回放）
arecord -d 3 /tmp/t.wav && aplay /tmp/t.wav

# 看 service 状态和日志
systemctl --user status rdkx5-audio.service
journalctl --user -u rdkx5-audio.service -n 20
```

重启验证：

```bash
sudo reboot
# 重新 ssh 上来后
pactl info | grep -E "Default Sink|Default Source"
```

## 更换设备

把新设备插好（或拔掉旧设备）后，重新跑一遍：

```bash
cd ~/Desktop/rdkx5_audio_setup
./setup.sh
```

也可直接编辑配置文件：

```bash
nano ~/Desktop/rdkx5_audio_setup/audio.conf
# 修改 SINK_KEYWORD 或 SOURCE_KEYWORD 后
systemctl --user restart rdkx5-audio.service
```

## 工作原理

```
开机
  └─► systemd user 启动（linger 让它不依赖登录）
        └─► rdkx5-audio.service 触发
              └─► apply-audio-config.sh 执行
                    ├─► 等待 PulseAudio 就绪（最多 30 秒）
                    ├─► 读 audio.conf
                    ├─► 用 grep 在 pactl list sinks/sources 里按关键字匹配
                    ├─► pactl set-default-sink / set-default-source
                    └─► 把已有的播放/录音流迁移到新默认设备
```

**为什么用关键字而非完整设备名？**  
USB 设备的完整名包含序列号和总线端口号，例如 `alsa_output.usb-Generic_AB13X_USB_Audio_20210926172016-00.analog-stereo`。换 USB 口或换同型号设备时序列号/端口号会变，硬编码完整名会失效。关键字（如 `AB13X`、`USB2.0_Device`、`platform-snd0`）则保持稳定。

**为什么需要 `loginctl enable-linger`？**  
systemd user service 默认只在用户登录后启动。无显示器无键鼠场景下，用户不会登录任何 tty，linger 让 systemd 把该用户当作"始终在线"，开机就启动其服务。

## 卸载

```bash
cd ~/Desktop/rdkx5_audio_setup
./uninstall.sh
```

会停掉并禁用 service、删除 `~/.config/systemd/user/rdkx5-audio.service`，并询问是否同时关闭 linger。配置文件 `audio.conf` 保留，需要手动删。

## 故障排查

**service 启动了但默认设备没变**  
看日志：
```bash
journalctl --user -u rdkx5-audio.service -n 50
```
大概率是 `audio.conf` 里的关键字没匹配上当前设备名。先看实际设备名：
```bash
pactl list sinks short
pactl list sources short
```
然后调整 `audio.conf` 中的关键字，或重跑 `./setup.sh`。

**重启后 service 没自动启动**  
确认 linger 已启用：
```bash
loginctl show-user $USER | grep Linger
# 期望输出 Linger=yes
```
确认 service 已 enable：
```bash
systemctl --user is-enabled rdkx5-audio.service
# 期望输出 enabled
```

**扬声器选对了仍无声**  
- 检查音量是否被设为 0 或静音：
  ```bash
  pactl list sinks | grep -A 10 "Name: $(pactl get-default-sink)"
  ```
- 取消静音 + 调音量：
  ```bash
  pactl set-sink-mute @DEFAULT_SINK@ 0
  pactl set-sink-volume @DEFAULT_SINK@ 80%
  ```

**找不到 pactl 命令**  
```bash
sudo apt install -y pulseaudio-utils
```

## 许可

MIT
