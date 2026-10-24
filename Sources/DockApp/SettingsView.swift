import AppKit
import ApplicationServices
import CoreServices
import DockCore
import SwiftUI

struct SettingsView: View {
    static let windowID = "settings"

    let controller: DockController
    @State private var musicPermission = Self.musicAutomationStatus()

    var body: some View {
        Form {
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

            Section {
                ForEach(controller.scenes.indices, id: \.self) { index in
                    sceneRow(index)
                }
            } header: {
                Text("场景")
            } footer: {
                Text("设备下方三个圆键从左到右切换场景，灯条颜色跟随当前场景。")
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            while !Task.isCancelled {
                musicPermission = Self.musicAutomationStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Show in the Dock and ⌘-Tab only while this window is open.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
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
