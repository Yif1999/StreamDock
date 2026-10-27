import AppKit
import DockCore
import SwiftUI

/// The menu bar panel: device state, scene tiles, the two brightness sliders, settings and quit.
struct MenuPanel: View {
    let controller: DockController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceHeader(connection: controller.connection)

            ScenePicker(controller: controller)
            if controller.activeScene.pageTitles.count > 1 {
                Text("\(controller.activePageTitle) · \(controller.activePageIndex + 1)/\(controller.activeScene.pageTitles.count) · 再按场景按钮翻页")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                PercentSlider(symbol: "sun.max.fill", title: "按键屏幕亮度", value: controller.settings.screenBrightness, set: controller.setScreenBrightness)
                PercentSlider(symbol: "light.strip.2", title: "灯条亮度", value: controller.settings.ledBrightness, set: controller.setLEDBrightness)
            }

            GlassEffectContainer {
                HStack {
                    SettingsLink {
                        Label("设置", systemImage: "gearshape")
                    }
                    .keyboardShortcut(",")
                    Button {
                        openWindow(id: "glow-scope")
                        NSApp.activate()
                    } label: {
                        Label("律动", systemImage: "waveform")
                    }
                    Spacer()
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("退出", systemImage: "power")
                    }
                    .keyboardShortcut("q")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
