# StreamDock 架构

为 MiraBox StreamDock M18 写的自定义控制软件，原生 Swift 菜单栏 App。

## 设计原则

1. **单进程**。菜单栏图标在 = 程序在运行；退出后进程完全结束。
   不注册 launchd、不加登录项、不带 helper / XPC。以后若有外部进程（如合成器引擎），
   由 App 启动并随 App 退出；外部钩子（如 Claude Code hooks）只发消息，App 不在就丢弃，绝不拉起 App。
2. **退出时清理设备**：灯条恢复默认效果、清空按键、通知设备断开。
3. **场景隔离**。三个场景各是一个独立的 SwiftPM target，只依赖 `DockCore`（和共享模块），
   彼此不可见。非前台场景可以继续工作，但不能画按键，只能通过全局提醒（灯条）提示。
4. **环境不影响全局**。依赖都在项目内（`.build/`、`.venv/`），不装全局工具。

## 硬件：M18

- USB `0x6603:0x1012`（M18EN），固件 `V3.M18V3_E_HXJDF.03.021`
- 15 个 LCD 键（3×5，图片 64×64 JPEG）+ 3 个圆键（无屏）+ 24 颗 RGB 灯（只能整条一个颜色）
- 逻辑键号：LCD 键按"从左上开始、逐行"编 1–15；圆键从左到右编 1–3
- **按键编号的坑**：写图片用的槽位号和按键事件码不是同一套。
  图片槽位 11–15 是第一行，事件码 1–5 才是第一行。映射集中在 `DockKit/M18Layout.swift`。

## 分层

```
DockApp          菜单栏图标、下拉菜单、设置窗口（SwiftUI）
SceneGeneral     通用控制场景      ┐
SceneVibeCoding  VibeCoding 场景   ├ 互相独立
SceneSynth       合成器场景        ┘
ControlModules   可复用模块：媒体（Apple Music）、音量、亮度、DDC
DockCore         场景/模块协议、按键分发、渲染、灯条与全局提醒、设置
DockKit          设备层：枚举、插拔、按键事件、刷图、灯条、心跳
CTransport       官方闭源 libtransport.dylib 的 C 接口（ThirdParty/libtransport）
```

圆键 1/2/3 固定用于切换场景：通用控制 / VibeCoding / 合成器。

## 通用控制场景的实现要点

- **媒体**：只控制 Apple Music。命令走 AppleScript（需要「自动化」权限），播放状态
  来自 Music 广播的 `com.apple.Music.playerInfo` 通知。
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
swift build                 # 编译
scripts/build_app.sh        # 打包成 build/StreamDock.app 并用开发证书签名
open build/StreamDock.app
```

`scripts/` 里的 Python 脚本用官方 Python SDK 做快速实验（`.venv`）。
