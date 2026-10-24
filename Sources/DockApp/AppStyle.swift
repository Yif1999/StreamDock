import DockCore
import SwiftUI

/// How the app presents devices and scenes, shared by the menu bar panel and the settings window.
extension DockController.Connection {
    var summary: String {
        switch self {
        case .searching: "未连接 · 等待 M18 插入"
        case .connecting: "正在连接 M18…"
        case .connected: "已连接 M18"
        case .failed: "M18 连接失败"
        }
    }

    var statusColor: Color {
        switch self {
        case .searching: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}

extension DockScene {
    var symbolName: String {
        switch id {
        case "general": "slider.horizontal.3"
        case "vibecoding": "chevron.left.forwardslash.chevron.right"
        case "synth": "pianokeys"
        default: "square.grid.3x3"
        }
    }
}

/// The device's name, connection state and a status dot.
struct DeviceHeader: View {
    let connection: DockController.Connection
    var large = false

    var body: some View {
        HStack(spacing: large ? 14 : 10) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(large ? .system(size: 30) : .title2)
                .foregroundStyle(.tint)
                .frame(width: large ? 56 : 36, height: large ? 56 : 36)
                .glassEffect(.regular, in: .rect(cornerRadius: large ? 16 : 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("StreamDock M18").font(large ? .title3.weight(.semibold) : .headline)
                HStack(spacing: 6) {
                    Circle().fill(connection.statusColor).frame(width: 7, height: 7)
                    Text(connection.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The three scenes as glass tiles; the active one is tinted with its light-strip color.
struct ScenePicker: View {
    let controller: DockController

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(controller.scenes.indices, id: \.self) { index in
                    tile(index)
                }
            }
        }
    }

    private func tile(_ index: Int) -> some View {
        let scene = controller.scenes[index]
        let selected = controller.activeSceneIndex == index
        let color = Color(rgb: controller.ledColor(for: scene))
        return Button {
            withAnimation(.smooth) { controller.activateScene(at: index) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: scene.symbolName).font(.title3)
                Text(scene.name).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                // The scene's light-strip color, lit while it is the active scene.
                Capsule()
                    .fill(color.opacity(selected ? 1 : 0.35))
                    .frame(width: selected ? 22 : 12, height: 4)
                    .shadow(color: selected ? color.opacity(0.8) : .clear, radius: 4)
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .frame(maxWidth: .infinity, minHeight: 72)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(color.opacity(0.3)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 14))
        .help("圆键 \(index + 1)：\(scene.name)")
    }
}

/// A 0–100 % slider with a leading symbol and the value.
struct PercentSlider: View {
    let symbol: String
    let title: String
    let value: Int
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help(title)
            // Snaps to 5 % without a stepped slider's row of tick marks.
            Slider(value: Binding(get: { Double(value) }, set: { set(Int(($0 / 5).rounded()) * 5) }), in: 0...100)
                .accessibilityLabel(title)
            Text("\(value)%")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
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
