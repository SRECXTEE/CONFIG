# CONFIG

RDK X5 机器人配置工具集合。

## 项目列表

### [rdkx5_wifi_setup](rdkx5_wifi_setup/)

RDK X5 WiFi 配网系统。通过 AP 热点 + 手机配网页，实现无键鼠无显示器的 WiFi 配置。

- 开机自启，有网则跳过，无网则自动开启配网热点
- 手机连接热点后自动弹出配网页面
- 扫描周边 WiFi → 选择目标 → 输入密码 → 自动连接并保存
- 一键部署：`sudo bash install.sh`

### [rdkx5_audio_setup](rdkx5_audio_setup/)

RDK X5 音频自动配置工具。解决开机时默认音频设备选错（如 USB 麦克风被误认为扬声器）导致扬声器无声的问题，支持无显示器无键鼠部署。

- 交互式选择输出/输入设备，自动写入配置
- systemd user service 开机自动应用，配合 linger 实现无头模式
- 更换硬件只需重跑 `./setup.sh`
- 一键部署：`cd rdkx5_audio_setup && ./setup.sh`

### 待续...

后续配置工具将在此仓库中逐步添加。