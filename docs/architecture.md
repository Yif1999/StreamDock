# StreamDock 架构

为 MiraBox StreamDock M18 写的自定义控制软件，原生 Swift 菜单栏 App。

## 设计原则

1. **单进程**。菜单栏图标在 = 程序在运行；退出后进程完全结束。
   不注册 launchd、不加登录项、不带 helper / XPC。以后若有外部进程（如合成器引擎），
   由 App 启动并随 App 退出；外部钩子（如 Claude Code hooks）只发消息，App 不在就丢弃，绝不拉起 App。
2. **退出时清理设备**：正常显示时灯条恢复默认效果、清空按键并通知断开；屏幕已休眠时保持设备熄灭，只释放连接。
3. **场景隔离**。三个场景各是一个独立的 SwiftPM target，只依赖 `DockCore`（和共享模块），
   彼此不可见。非前台场景可以继续工作，但不能画按键，也不能点亮灯带：通知和活动指示都属于各自场景，只在该场景显示时输出。
4. **环境不影响全局**。依赖都在项目内（`.build/`、`.venv/`），不装全局工具。

## 硬件：M18

- USB vendor `0x6603`，支持 product `0x1009`（M18）及 `0x1012`（M18EN）；固件版本读取可能为空。
- 15 个 LCD 键（3×5，图片 64×64 JPEG）+ 3 个圆键（无屏）+ 24 颗 RGB 灯（支持整条及逐灯输出）
- 15 个键其实是同一块 480×272 屏上的窗口；按键图 **1:1 点对点显示**（2026-10-24 用 1 像素棋盘格实拍确认，`dock-probe keytest`），
  图外还有一圈黑色窗口区域。屏幕可见 RGB 子像素，1 像素宽的线会带彩边
- 灯光分布：三个圆键左右各一根短灯条，加底座边缘一圈底部灯带
- 逐灯帧在 M18 上晚一帧显示，静态逐灯图案需要双发 settle；动画持续送帧。早期不稳定记录不再作为禁止逐灯输出的约束。
- 用户确认的物理布局：0–10 下半圈、11–21 上半圈，逆时针；22/23 为左右短灯条。映射集中在 `M18Layout`。
- 逻辑键号：LCD 键按"从左上开始、逐行"编 1–15；圆键从左到右编 1–3
- **按键编号的坑**：写图片用的槽位号和按键事件码不是同一套。
  图片槽位 11–15 是第一行，事件码 1–5 才是第一行。映射集中在 `DockKit/M18Layout.swift`。

## 分层

```
DockApp          菜单栏图标、液态玻璃面板、设置窗口（SwiftUI，macOS 26+）
SceneGeneral     通用控制场景      ┐
SceneVibeCoding  VibeCoding 场景   ├ 互相独立
SceneSynth       合成器场景        ┘
ControlModules   可复用模块：媒体、音量、亮度、音频设备、HA、OBS
DockCore         场景/模块协议、按键分发、渲染、灯条与场景提醒、设置
DockKit          设备层：枚举、插拔、按键事件、刷图、灯条、心跳
CTransport       官方闭源 libtransport.dylib 的 C 接口（ThirdParty/libtransport）
```

圆键 1/2/3 固定用于切换场景：通用控制 / VibeCoding / 合成器。

## 通用控制场景的实现要点

- **媒体**：只控制 Apple Music。命令走 AppleScript（需要「自动化」权限），播放状态
  来自 Music 广播的 `com.apple.Music.playerInfo` 通知。媒体控制位于第三排，封面和喜爱紧随其后；
  喜爱直接读写 `favorited`，用 persistent ID 防止切歌期间误操作。
- **亮度**：优先用系统接口 DisplayServices（键盘亮度键、控制中心用的同一个）——
  内置屏优先，其次系统能调的外接屏。系统调不了时退回 DDC。
  本机的 5K 外接屏：**开 HDR 时**系统能调（软件调光，显示器背光锁定，DDC 读到 0）；
  **关 HDR 时**系统调不了，走 DDC 调真实背光。
- **音量**：默认输出设备可调就用 CoreAudio；输出是显示器（DisplayPort/HDMI）时 macOS
  调不了，改走 DDC 调显示器音量。该显示器不支持 DDC 静音，静音用"音量归零 + 记住原值"模拟。
- DDC 读写各要几十毫秒，在后台队列执行，连按时只发送最新的值。

## 设备连接

- M18 插在显示器的 USB Hub 上，**切换 HDR 时显示器会重置 Hub，M18 会断开再重新枚举**
  （路径 `DevSrvsID:…` 会变）。
- 系统的拔出通知不可靠（实测没有送达），所以 `DockController` 每 3 秒核对一次实际插着的设备，
  自动丢弃失效连接、连接新设备。
- 连接事件写入系统日志：
  `/usr/bin/log show --last 10m --predicate 'subsystem == "StreamDock"'`
  （zsh 里 `log` 是内置命令，要写完整路径）。

## 构建

```sh
swift build                 # 编译（需要 macOS 26 SDK，Swift 6.2+）
scripts/build_app.sh        # 打包成 build/StreamDock.app 并用开发证书签名
open build/StreamDock.app
```

`scripts/` 里的 Python 脚本用官方 Python SDK 做快速实验（`.venv`）。

## 通用控制扩展

- `AudioDevices` 共享输入/输出设备列表，每秒刷新默认路由与输入静音状态；勾选项按设备 UID 持久化，离线设备跳过，重连后保留选择。
- 输入静音优先硬件 mute，否则对主输入增益或全部输入通道归零，并保存各通道原值；设备不支持时明确显示不可用。它不代表会议软件自己的静音状态。
- `DisplaySleepModule` 持续按住 1 秒确认，提前松手或场景退出取消；完成后调用系统 `pmset displaysleepnow`。测试注入替代动作，不会真的关屏。
- `KeyFace.artwork` 支持封面图片，渲染时居中裁切为正方形，图片无效时回退图标。

## 按键设计（KeyDesign）

模块只描述按键"是什么、处于什么状态"（`KeyFace`：系统图标名 / 数值 / 英文标签 / `KeyTone`），
外观由 `KeyDesign` 统一决定，模块不能自选颜色；`KeyRenderer` 编码成全色度 JPEG。
网格、颜色、文案、按下反馈等规则见 [design.md](design.md)。

## 场景内分页与 OBS

- `DockScene` 的模块绑定到页，`ModuleContext` 记录所属页；只有当前页接收按键和屏幕更新，各页保留自己的灯效。
- `DockController.activateScene` 对当前场景执行循环翻页，先释放旧页按键，再停用旧页、激活新页；菜单栏显示页名及页码。
- 通用控制为日常 / Home Assistant / OBS 三页；OBS 属于通用控制页，不占用另两个圆键。
- `OBSClient` 只连接本机，通过 WebSocket 5 的挑战认证读取 OBS 保存的凭据；服务开关由用户在 OBS 中设置。
- 所有请求带唯一 ID 与 5 秒超时；断线结束等待请求、清除运行状态，重连只同步状态，不重发操作。
- 状态同步以 OBS 事件为主（`OBSState`）：状态按来源分为场景、输出（录制/暂停/推流/回放/虚拟相机/工作室模式）、输入静音、来源、热键五块。带新值的事件（如 `RecordStateChanged`、`CurrentProgramSceneChanged`、`InputMuteStateChanged`）直接更新，不回读 OBS；只说明"列表变了"的事件（新建/删除场景、输入、来源）只重新读取对应那一块。输出事件按 `outputState` 解释而不是 `outputActive`（后者只在 STARTED/RESUMED 时为真，暂停和重连时为假，但输出仍在进行）；STARTING/STOPPING 只是过渡，不改状态。每块有版本号，事件到达即加一；读取期间若有事件到达，这次回包作废并重读，旧回包不会覆盖新事件。兜底核对只针对"安静"的状态块：某块 10 秒内既没有事件、也没有读过，才读回一次，弥补可能漏掉的事件；刚收到事件的块不会被读回覆盖——OBS 繁忙时（例如 4K60 双路编码丢帧），状态查询的答复可能落后于它自己发出的事件，曾出现停止录制后读回"仍在录制"。来源显隐绑定场景及 item ID（同名来源可区分），已删除目标不回退到其他目标。
- 测试使用独立的本机 WebSocket fixture，不会控制用户真实的 OBS。
- 参考：[多 OBS 控制器](https://key123.vip/product/20250217000167?lang=zh)、[obs-websocket 5 协议](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md)。本项目范围为本机单个 OBS，不包括多实例同步与任意协议请求编辑器。

### 场景活动灯光

每个场景有自己的 `LightActivityCenter`（跨页面的活动动画）和 `AlertCenter`（提醒），只在该场景显示时参与灯光仲裁；场景内优先级为通知 > 活动（OBS）> 当前页动画 > 场景色。`OBSLightMonitor` 挂在通用控制场景上，随应用启动，通过独立状态回调同步录制、暂停及推流状态，断线清除指示。OBS 录制纯红色、推流纯绿色、暂停橙琥珀色；同时输出时各占半圈。

`LightAnimation` 输出浮点 `LightPixel`（颜色通道比例 + 感知亮度），不在模块中做 Gamma 或量化。`isActive` 标识活动状态；音乐暂停仍在显示灯效，算活动（不再叠加 50% 的非活动调暗），暂停亮度由灯效自己决定。引擎在感知空间完成颜色渐变、用户亮度与活动倍率（活动 100% / 非活动 50%），由 DockCore 的 `LEDOutput` 将组合亮度一次性进行 Gamma 2.2 映射，再量化为 RGB，并保留暗部防抖。颜色通道比例不参与 Gamma，避免改变色相。

硬件总亮度固定 100%，调光直接合入每帧，避免硬件百分比整数损失暗部精度。设置滑块保持原值、改为感知亮度语义；满设置的非活动纯色输出峰值约 55/255（22%）。设备重连重发硬件总亮度，退出淡出也经过同一映射。离线音乐回放使用同一个输出器；通知黑色间隔仍算活动。

### Home Assistant

`HAClient` 管理独立的 WebSocket 会话，通过 `subscribe_events`/`get_states`/`get_services` 同步实体及服务能力。初始化订阅事件先于快照，并缓冲合并期间事件；每 20 秒心跳，6 秒请求超时，连接失败后 3 秒重试。失效令牌停止自动重试，待用户更换。会话代号隔离旧请求，断线不重放指令。

`HAModule` 占通用控制第 2 页的 15 键；设置以实体 ID 保存绑定，默认全部留空。`HAKeychain` 使用服务名 dev.yif.StreamDock.HomeAssistant、服务器地址作为 account 保存令牌，普通设置只保存地址与绑定。只读状态键不发命令；控制范围包括开关、空调温度/模式、风扇调速/摇头/风型、灯光亮度/色温、场景、脚本和窗帘。

设置采用 SwiftUI Settings + TabView，分为通用、场景、音频、智能家居和 OBS，保存最后访问的面板。音频设备候选列表使用 checkbox，不更改其原有多选轮换语义。

`HACommand.make` 根据实体属性、特性位和服务列表构造命令，调温遵循 target_temp_step/min_temp/max_temp，调速遵循 percentage_step，色温以 Kelvin 下发并限制范围。空调/风扇关闭时调整键禁用，避免调整附带开机。

`safePower` 仅适用于 switch：关闭采用明确的 turn_off，不用 toggle；HAModule 要求持续按住 1 秒且页面可见、连接与绑定/状态有效，释放、翻页、断线或绑定变化取消。HAClient 默认拒绝未经长按确认的断电请求，设备已关闭时短按仅发送 turn_on。

### 跟随电脑屏幕休眠

`DisplayPowerMonitor` 订阅 NSWorkspace 的屏幕休眠/唤醒及整机休眠/唤醒通知，启动时和每 2 秒用 CGDisplayIsAsleep 校验全部在线显示器，整机睡眠优先于查询结果。`DockController` 进入休眠时先释放按键、取消长按，再暂停 LightEngine、将屏幕/LED 亮度归零并发送设备 sleep；保留页面和用户设置。后台状态变化不会重亮设备，重连也按休眠状态初始化。

唤醒后发送 wakeup_screen，重绘当前页并恢复屏幕设置与灯光渐入。WakeKeyGate 吞掉唤醒键整个按下/释放周期，并处理系统先报告唤醒、USB 按键随后到达的短暂竞态；只有重新按键才执行模块动作。通过 IOPMAssertionDeclareUserActivity 请求显示器唤醒，不绕过锁屏。整机深度睡眠时能否接收按键仍取决于 USB/系统硬件唤醒支持。
