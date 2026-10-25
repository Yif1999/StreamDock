import AppKit
import ApplicationServices
import CoreServices
import ControlModules
import DockCore
import SwiftUI

struct SettingsView: View {
    let controller: DockController
    @AppStorage("settingsPane") private var pane = "general"
    @State private var musicPermission = Self.musicAutomationStatus()
    @State private var keystrokePermission = CGPreflightPostEventAccess()

    var body: some View {
        TabView(selection: $pane) {
            Form { generalControls }
                .tabItem { Label("通用", systemImage: "gearshape") }.tag("general")
            Form {
                Section("场景灯光") {
                    ForEach(controller.scenes.indices, id: \.self) { sceneRow($0) }
                }
                Section("翻页") {
                    Text("设备下方三个圆键切换场景；重复按当前场景的圆键循环翻页。")
                    LabeledContent("通用控制", value: "日常控制 → 智能家居 → OBS")
                    LabeledContent("VibeCoding", value: "Codex 与 Claude 额度")
                }
            }.tabItem { Label("场景", systemImage: "square.grid.2x2") }.tag("scenes")
            Form {
                Section {
                    audioChoices(input: false)
                } footer: { Text("勾选多个候选设备后，输出切换键会依次轮换。勾选不会改变当前输出，也不会同时播放。") }
                Section {
                    audioChoices(input: true)
                } footer: { Text("输入切换键只在勾选且在线的设备之间轮换。麦克风静音作用于当前系统输入设备。") }
            }.tabItem { Label("音频", systemImage: "speaker.wave.2") }.tag("audio")
            Form { HASettingsSection() }
                .tabItem { Label("智能家居", systemImage: "house") }.tag("home")
            Form { OBSSettingsSection() }
                .tabItem { Label("OBS", systemImage: "video") }.tag("obs")
            Form { CPASettingsSection() }
                .tabItem { Label("VibeCoding", systemImage: "chevron.left.forwardslash.chevron.right") }.tag("vibecoding")
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 580)
        .task {
            AudioDevices.shared.start()
            while !Task.isCancelled {
                musicPermission = Self.musicAutomationStatus()
                keystrokePermission = CGPreflightPostEventAccess()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    @ViewBuilder private var generalControls: some View {
            Section {
                DeviceHeader(connection: controller.connection, large: true)
                    .padding(.vertical, 4)
                if case .connected(let serial, let firmware) = controller.connection {
                    if !firmware.isEmpty {
                        LabeledContent("固件", value: firmware)
                    }
                    LabeledContent("序列号", value: serial)
                }
                if case .failed(let message) = controller.connection {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("亮度") {
                LabeledContent("按键屏幕") {
                    PercentSlider(symbol: "sun.max.fill", title: "按键屏幕亮度", value: controller.settings.screenBrightness, set: controller.setScreenBrightness)
                }
                LabeledContent("灯条") {
                    PercentSlider(symbol: "light.strip.2", title: "灯条亮度", value: controller.settings.ledBrightness, set: controller.setLEDBrightness)
                }
            }

            Section("屏幕联动") {
                Text("随电脑屏幕休眠关闭按键屏幕和灯带，唤醒后恢复。控制器第一次按键仅唤醒屏幕，松手后再按才执行原功能。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("权限") {
                LabeledContent("控制「音乐」") {
                    switch musicPermission {
                    case noErr:
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case OSStatus(errAEEventNotPermitted):
                        Button("去系统设置授权") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                        .buttonStyle(.glassProminent)
                    case OSStatus(procNotFound):
                        Text("「音乐」未运行").foregroundStyle(.secondary)
                    default:
                        Text("首次按播放键时系统会询问").foregroundStyle(.secondary)
                    }
                }
                Text("媒体键只控制 Apple Music，需要「自动化」权限。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("向 Codex / Claude 发送按键") {
                    if keystrokePermission {
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("去系统设置授权") { _ = CGRequestPostEventAccess() }
                            .buttonStyle(.glassProminent)
                    }
                }
                Text("VibeCoding 第三排（Accept、Stop、New、Send、Voice）把按键发给前台的 Codex 或 Claude，需要「辅助功能」权限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func audioChoices(input: Bool) -> some View {
        let audio = AudioDevices.shared
        Text(input ? "参与轮换的输入设备" : "参与轮换的输出设备").font(.headline)
        ForEach(audio.devices.filter { input ? $0.input : $0.output }) { device in
            Toggle(device.name, isOn: Binding(
                get: { audio.isSelected(device, input: input) },
                set: { audio.select(device, input: input, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
        }
    }

    /// Checks Automation permission for Music without prompting.
    private static func musicAutomationStatus() -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    }

    private func sceneRow(_ index: Int) -> some View {
        let scene = controller.scenes[index]
        let hasOverride = controller.settings.ledColorOverrides[scene.id] != nil
        let active = controller.activeSceneIndex == index
        return HStack(spacing: 12) {
            Image(systemName: scene.symbolName)
                .frame(width: 32, height: 32)
                .glassEffect(active ? .regular.tint(Color(rgb: controller.ledColor(for: scene)).opacity(0.45)) : .regular, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name)
                Text(active ? "圆键 \(index + 1) · 当前" : "圆键 \(index + 1)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ColorPicker("灯条颜色", selection: Binding(
                get: { Color(rgb: controller.ledColor(for: scene)) },
                set: { controller.setLEDColor(RGB(color: $0), for: scene) }
            ), supportsOpacity: false)
            .labelsHidden()
            Button("默认") { controller.setLEDColor(nil, for: scene) }
                .buttonStyle(.glass)
                .disabled(!hasOverride)
        }
    }
}
