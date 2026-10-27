import ControlModules
import DockCore
import SwiftUI

/// The 律动可视化 window: the music light's canvas seen from above (front at the bottom) with its
/// blobs, the low end's pull and the lifts, the LEDs round it as they show; beside it the last seconds of the low
/// end and the hits driving it.
struct GlowScopeView: View {
    private static let canvasSize = 460.0, inset = 30.0
    private static let plotHeight = 200.0, laneHeight = 30.0, laneGap = 6.0
    private static let lanes: [(String, Color)] = [("低频打击", .gray), ("重底鼓（压住高频闪点）", .red), ("中频（满格=重击，会闪）", .orange), ("高频", .cyan)]

    var body: some View {
        // Redrawn whenever the light records a frame (GlowScope is observable), not on a timer
        // of its own: a timeline left the window frozen on one frame.
        let scope = GlowScope.shared
        let frame = scope.frame
        HStack(alignment: .top, spacing: 20) {
            Canvas { context, size in _ = frame?.time; drawCanvas(scope, in: &context, size: size) }
                .frame(width: Self.canvasSize, height: Self.canvasSize)
                // Labels are laid out once, outside the canvas redrawn every frame.
                .overlay(alignment: .top) { Text("后").font(.caption).foregroundStyle(.secondary) }
                .overlay(alignment: .bottom) { Text("前").font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 10) {
                Picker("单独看", selection: Binding(get: { GlowScope.shared.layer }, set: { GlowScope.shared.layer = $0 })) {
                    ForEach([MusicGlowLayer.all, .draw, .lift, .high], id: \.self) { Text(Self.title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 440)
                Canvas { context, size in _ = frame?.time; drawHistory(scope, in: &context, size: size) }
                    .frame(width: 440, height: 360)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: Self.laneHeight + Self.laneGap - 13) {
                            ForEach(Self.lanes, id: \.0) { Text($0.0).font(.caption2).foregroundStyle($0.1).frame(height: 13) }
                        }
                        .padding(.leading, 4)
                        .padding(.top, Self.plotHeight + Self.laneGap + 2)
                    }
                readout(frame)
            }
        }
        .padding(20)
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)
        .onAppear { GlowScope.shared.watching = true }
        .onDisappear { GlowScope.shared.watching = false }
    }

    private static func title(_ layer: MusicGlowLayer) -> String {
        switch layer {
        case .all: "全部"
        case .flow: "只漂移"
        case .draw: "低频"
        case .lift: "中频"
        case .high: "高频"
        }
    }

    // MARK: - Canvas

    private func drawCanvas(_ scope: GlowScope, in context: inout GraphicsContext, size: CGSize) {
        let inset = Self.inset, side = size.width - 2 * inset
        // Seen from above, front at the bottom.
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: inset + x * side, y: inset + (1 - y) * side) }
        guard let frame = scope.frame else {
            context.draw(Text("等待音乐律动……（播放音乐，并停在有音乐律动的场景）").foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        // The canvas as one small image, smoothed up: one draw, not a rectangle per sample.
        if let image = Self.image(of: frame.canvas, side: GlowScope.grid) {
            context.draw(Image(decorative: image, scale: 1).interpolation(.high).resizable(),
                         in: CGRect(x: inset, y: inset, width: side, height: side))
        }
        context.stroke(Path(CGRect(x: inset, y: inset, width: side, height: side)), with: .color(.white.opacity(0.25)), lineWidth: 1)

        // Blobs: their 1/e reach, centre in their own color, where they are heading; the main
        // blob solid-ringed, with the place on the edge the low end pulls it to.
        for blob in frame.blobs {
            let center = point(blob.x, blob.y), r = blob.radius * side
            let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            if blob.main {
                context.stroke(ring, with: .color(.white.opacity(0.85)), lineWidth: 2.5)
            } else {
                // In front of the shuffle: bright and thick; behind: faint.
                let front = (blob.depth + 1) / 2
                context.stroke(ring, with: .color(.white.opacity(0.15 + 0.6 * front)), style: StrokeStyle(lineWidth: 0.5 + 2.5 * front, dash: [4, 4]))
                var heading = Path()
                heading.move(to: center)
                heading.addLine(to: point(blob.x + blob.vx * 0.5, blob.y + blob.vy * 0.5))
                context.stroke(heading, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
            }
            let d = blob.main ? 20.0 : 8 + 10 * (blob.depth + 1) / 2
            let dot = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            context.fill(Path(ellipseIn: dot), with: .color(Color(blob.color)))
            context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
        }
        if let anchor = frame.anchor, let main = frame.blobs.first(where: \.main) {
            let to = point(anchor.x, anchor.y)
            var pull = Path()
            pull.move(to: point(main.x, main.y))
            pull.addLine(to: to)
            context.stroke(pull, with: .color(.red.opacity(0.4 + 0.6 * frame.draw)), style: StrokeStyle(lineWidth: 1 + 4 * frame.draw, lineCap: .round, dash: [6, 4]))
            context.fill(Path(ellipseIn: CGRect(x: to.x - 6, y: to.y - 6, width: 12, height: 12)), with: .color(.red))
        }

        // Mid lifts: where they landed on the edge.
        for lift in frame.lifts where lift.level > 0.02 {
            let c = point(lift.x, lift.y), r = 6 + 18 * lift.level
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.yellow.opacity(min(1, lift.level * 1.5))), lineWidth: 2)
        }

        // LEDs: the ring just outside the edge, the short bars where they sit.
        for led in frame.leds {
            let c = point(led.x, led.y)
            if led.bar {
                let w = LightLayout.barLength * side
                let rect = CGRect(x: c.x - w / 2, y: c.y - 4, width: w, height: 8)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color(led.color)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.white.opacity(0.5)), lineWidth: 1)
                continue
            }
            let out = 16.0
            let dx = led.x < 1e-6 ? -out : led.x > 1 - 1e-6 ? out : 0
            let dy = led.y < 1e-6 ? out : led.y > 1 - 1e-6 ? -out : 0
            let rect = CGRect(x: c.x + dx - 7, y: c.y + dy - 7, width: 14, height: 14)
            context.fill(Path(ellipseIn: rect), with: .color(Color(led.color)))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.3)), lineWidth: 1)
        }
    }

    /// The canvas samples (row 0 at the front) as an image, front at the bottom.
    private static func image(of canvas: [RGB], side n: Int) -> CGImage? {
        guard canvas.count == n * n else { return nil }
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        for index in canvas.indices {
            let out = ((n - 1 - index / n) * n + index % n) * 4
            bytes[out] = canvas[index].red; bytes[out + 1] = canvas[index].green; bytes[out + 2] = canvas[index].blue
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - History

    private func drawHistory(_ scope: GlowScope, in context: inout GraphicsContext, size: CGSize) {
        guard let now = scope.frame?.time else { return }
        let span = GlowScope.history
        func x(_ time: Double) -> Double { size.width * (1 - (now - time) / span) }
        let plot = CGRect(x: 0, y: 0, width: size.width, height: Self.plotHeight)
        context.fill(Path(plot), with: .color(.white.opacity(0.04)))
        for second in 0...Int(span) {
            var line = Path()
            let gx = x(now - Double(second))
            line.move(to: CGPoint(x: gx, y: 0))
            line.addLine(to: CGPoint(x: gx, y: size.height))
            context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
        }
        func y(_ value: Double) -> Double { plot.maxY - min(1, max(0, value)) * (plot.height - 8) }

        // The low end's level (what draws) as an area, the drawn light and the rebound as lines.
        var area = Path()
        area.move(to: CGPoint(x: x(scope.samples.first?.time ?? now), y: plot.maxY))
        for sample in scope.samples { area.addLine(to: CGPoint(x: x(sample.time), y: y(sample.lowDraw))) }
        area.addLine(to: CGPoint(x: x(now), y: plot.maxY))
        context.fill(area, with: .color(.gray.opacity(0.35)))
        func curve(_ value: (GlowScope.Sample) -> Double, _ color: Color, dash: [CGFloat] = []) {
            var path = Path()
            for (index, sample) in scope.samples.enumerated() {
                let p = CGPoint(x: x(sample.time), y: y(value(sample)))
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
        }
        curve(\.draw, .blue)
        curve(\.rebound, .green)
        curve(\.intensity, .purple, dash: [4, 4])

        // Event lanes.
        let lanes = Self.lanes, laneHeight = Self.laneHeight
        let laneTop = plot.maxY + Self.laneGap
        for (index, lane) in lanes.enumerated() {
            let top = laneTop + Double(index) * (laneHeight + Self.laneGap)
            context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: laneHeight)), with: .color(.white.opacity(0.03)))
        }
        for mark in scope.marks {
            let (lane, strength): (Int, Double) = switch mark {
            case .lowHit(_, let s): (0, s)
            case .kick(_, let s): (1, s)
            case .lift(_, let s): (2, s)
            case .high(_, let s): (3, s)
            }
            let bottom = laneTop + Double(lane) * (laneHeight + Self.laneGap) + laneHeight
            let h = max(4, laneHeight * min(1, strength))
            let rect = CGRect(x: x(mark.time) - 1.5, y: bottom - h, width: 3, height: h)
            context.fill(Path(rect), with: .color(lanes[lane].1))
        }
    }

    private func readout(_ frame: GlowScope.Frame?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                legend(.gray, "低频能量（收的来源）", frame?.lowDraw)
                legend(.blue, "牵引（收紧贴边·变暗·加浓）", frame?.draw)
            }
            GridRow {
                legend(.green, "回弹", frame?.rebound)
                legend(.purple, "律动强度", frame?.intensity)
            }
            GridRow {
                Text("主色光团半径 \(frame.flatMap { $0.blobs.first(where: \.main) }.map { String(format: "%.2f", $0.radius) } ?? "–")")
                Text("粗圈：主色光团；虚线圈：其他颜色，越粗越亮越在前面（轮流换到前面）；红虚线：低频把主色拉向的边缘点")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .frame(width: 440, alignment: .leading)
    }

    private func legend(_ color: Color, _ title: String, _ value: Double?) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 4)
            Text(title)
            Text(value.map { String(format: "%.2f", $0) } ?? "–").foregroundStyle(.secondary)
        }
    }
}

private extension Color {
    init(_ rgb: RGB) {
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}
