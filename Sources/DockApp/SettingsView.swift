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
            Section("设备") {
                LabeledContent("状态", value: controller.connection.summary)
                if case .connected(let serial, let firmware) = controller.connection {
                    LabeledContent("固件", value: firmware.isEmpty ? "—" : firmware)
                    LabeledContent("序列号", value: serial)
                }
                if case .failed(let message) = controller.connection {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("亮度") {
                percentSlider("按键屏幕", value: controller.settings.screenBrightness, set: controller.setScreenBrightness)
                percentSlider("灯条", value: controller.settings.ledBrightness, set: controller.setLEDBrightness)
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
        .frame(width: 460)
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

    private func percentSlider(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { Double(value) }, set: { set(Int($0)) }), in: 0...100, step: 5)
                Text("\(value)%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func sceneRow(_ index: Int) -> some View {
        let scene = controller.scenes[index]
        let hasOverride = controller.settings.ledColorOverrides[scene.id] != nil
        return HStack {
            Text("圆键 \(index + 1)").foregroundStyle(.secondary)
            Text(scene.name)
            if controller.activeSceneIndex == index {
                Text("当前").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.tint.opacity(0.2), in: Capsule())
            }
            Spacer()
            ColorPicker("灯条颜色", selection: Binding(
                get: { Color(rgb: controller.ledColor(for: scene)) },
                set: { controller.setLEDColor(RGB(color: $0), for: scene) }
            ), supportsOpacity: false)
            .labelsHidden()
            Button("默认") { controller.setLEDColor(nil, for: scene) }
                .disabled(!hasOverride)
        }
    }
}

extension Color {
    init(rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

extension RGB {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            UInt8((ns.redComponent * 255).rounded()),
            UInt8((ns.greenComponent * 255).rounded()),
            UInt8((ns.blueComponent * 255).rounded())
        )
    }
}
