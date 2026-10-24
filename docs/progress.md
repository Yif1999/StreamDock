# 开发进度

设计见 [architecture.md](architecture.md)，节奏识别与灯效见 [rhythm.md](rhythm.md)（含每次问题的分析记录）。

## 已完成

### 框架（2026-10-24）
- 原生 Swift 菜单栏应用：单进程，有菜单栏图标和设置窗口，退出即消失；不开机自启，没有 launchd、登录项或常驻助手进程
- 设备层：厂商 libtransport 封装、IOHIDManager 热插拔 + 3 s 兜底巡检、断线重连
- 三个互相隔离的场景，用底部三个圆键切换（通用控制 / VibeCoding / 合成器），灯带颜色跟随场景
- 灯光引擎：所有变化都有缓动，没有瞬切；逐灯帧"晚一帧"问题用 settle 双发解决

### 通用控制场景
- 媒体控制：只控制 Apple Music（上一首 / 播放暂停 / 下一首）
- 音量：系统音量，或通过 DDC 调显示器音量
- 亮度：HDR 开启时走 DisplayServices，关闭时走 DDC；切换 HDR 后能正常重连

### 音乐灯效
- 取色：先用 Music 自带的封面，没有再查 iTunes（按 ID → 精确名称，覆盖多个地区商店）；在 OKLCh 里调色
- 节奏识别 RhythmKit：三频段特征 → 打击检测 → 重击（与拍点网格无关）、速度与拍点网格、平缓/寻拍/锁定状态机
- 渲染：统一的亮度分配（GlowBudget），按感知亮度计算，暗部防抖；OKLab 混色，峰值偏白；
  重击从一点扩散（重的铺满整圈、轻的局部）；流光只做加减速、不换向；高频闪烁点；
  暂停时收成慢呼吸，切歌时颜色渐变
- 调试工具：节奏特征录制与离线回放（`dock-probe rhythm-eval` / `glowsim`），打拍对照（仅供参考）
- 测试：RhythmKitTests 15 个、ControlModulesTests 11 个

## 待做

- VibeCoding 场景：ChatGPT / Claude 额度显示，hooks 触发闪烁提醒（只确定了方向）
- 合成器场景（类 Teenage Engineering）
- 速度偶尔跳到一倍或一半（173 / 77 BPM）：可以把 TempoEstimator 换成 HMM 速度跟踪；目前只影响柔和的网格脉动
- 底鼓和贝斯都在低频，暂时分不开：可以结合"同时出现的高频敲击声"来区分
- 设备固件版本号读出来是空字符串

## 已知、暂不处理

- 灯带整体亮度上限 / 夜间降亮（光效品味第 6 条，用户决定不做）
- 2026-10-24 遇到 Apple Music 切歌时清空播放列表、不开始播放：退出 StreamDock 后同样出现，之后自行恢复，判断为 Music 自身问题。
  如果以后只在开着 StreamDock 时出现，就把切歌后读取封面的时间推迟一两秒
