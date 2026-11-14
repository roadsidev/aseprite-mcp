import SwiftUI
import AppKit

/// Advances the model once per display refresh (vsync), outside SwiftUI's
/// view updates, so the Canvas only ever reads state.
@MainActor
final class DisplayDriver: NSObject {
    private var link: CADisplayLink?
    private let model: LiveModel

    init(model: LiveModel) {
        self.model = model
    }

    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--self-test"), i + 1 < args.count {
            let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 6
            let every = args.firstIndex(of: "--capture-every").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 0
            let test = SelfTest(directory: URL(fileURLWithPath: args[i + 1], isDirectory: true),
                                seconds: seconds, captureEvery: every)
            test.model = model
            selfTest = test
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        model.tick(now: link.targetTimestamp)
        selfTest?.frame(link: link)
    }

    // MARK: - Self-test (--self-test <dir>): frame-time stats plus window captures.
    var selfTest: SelfTest?
}

@MainActor
final class SelfTest {
    private let directory: URL
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var lastCapture: CFTimeInterval = 0
    private var captures = 0
    private let started = CACurrentMediaTime()
    private let seconds: Double
    weak var model: LiveModel?
    private let captureEvery: Double

    init(directory: URL, seconds: Double, captureEvery: Double) {
        self.directory = directory
        self.seconds = seconds
        self.captureEvery = captureEvery
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func frame(link: CADisplayLink) {
        let now = link.timestamp
        if last > 0 { intervals.append((now - last) * 1000) }
        last = now
        if let model, captureEvery > 0, now - lastCapture >= captureEvery {
            lastCapture = now
            let renderNow = CACurrentMediaTime()
            let renderer = ImageRenderer(content: Canvas { gc, size in
                PixelCanvas.draw(model: model, gc: &gc, size: size, now: renderNow)
            }.frame(width: 300, height: 220).background(Color(white: 0.11)))
            renderer.scale = 1
            if let image = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: image)
                let url = directory.appendingPathComponent(String(format: "shot-%03d.png", captures))
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                captures += 1
            }
        }
        if CACurrentMediaTime() - started >= seconds { finish(link: link) }
    }

    private func finish(link: CADisplayLink) {
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let expected = (link.targetTimestamp - link.timestamp) * 1000
        let dropped = intervals.filter { $0 > expected * 1.5 }.count
        let report = String(format: "frames=%d expected=%.2fms p50=%.2fms p99=%.2fms max=%.2fms dropped=%d captures=%d\n",
                            intervals.count, expected, pct(0.5), pct(0.99), sorted.last ?? 0, dropped, captures)
        try? report.write(to: directory.appendingPathComponent("frametime.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

/// Hosts the display link on the window's screen (follows it across displays).
struct DisplayLinkHost: NSViewRepresentable {
    let driver: DisplayDriver
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { driver.attach(to: view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PixelCanvas: View {
    let model: LiveModel

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas(rendersAsynchronously: false) { gc, size in
                PixelCanvas.draw(model: model, gc: &gc, size: size, now: CACurrentMediaTime())
            }
        }
    }

    static func draw(model: LiveModel, gc: inout GraphicsContext, size: CGSize, now: CFTimeInterval) {
        let engine = model.engine
        guard engine.width > 0, let image = engine.currentImage() else { return }
        let w = CGFloat(engine.width), h = CGFloat(engine.height)
        let fit = min(size.width / w, size.height / h)
        let scale = max(1, fit >= 1 ? floor(fit) : fit)
        let rect = CGRect(x: ((size.width - w * scale) / 2).rounded(),
                          y: ((size.height - h * scale) / 2).rounded(),
                          width: w * scale, height: h * scale)

        drawChecker(gc: &gc, rect: rect, scale: scale)
        gc.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)

        if model.showGrid && scale >= 6 {
            var grid = Path()
            for i in 0...engine.width { let x = rect.minX + CGFloat(i) * scale; grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY)) }
            for j in 0...engine.height { let y = rect.minY + CGFloat(j) * scale; grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y)) }
            gc.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
        }

        // Freshly painted pixels: a soft bloom, then a crisp pixel that pops and settles.
        let pops = engine.pops
        guard !pops.isEmpty else { return }
        gc.drawLayer { layer in
            layer.addFilter(.blur(radius: max(2, scale * 0.9)))
            layer.blendMode = .plusLighter
            for p in pops {
                let k = min(1, (now - p.t) / Engine.popLife)
                let color = color(p.color)
                let r = cell(p, rect: rect, scale: scale, grow: 1.9 - 0.9 * k)
                layer.fill(Path(r), with: .color(color.opacity(0.85 * (1 - k))))
            }
        }
        for p in pops {
            let k = min(1, (now - p.t) / Engine.popLife)
            let ease = 1 - pow(1 - k, 3)
            let r = cell(p, rect: rect, scale: scale, grow: 1.35 - 0.35 * ease)
            gc.fill(Path(r), with: .color(color(p.color)))
            gc.fill(Path(r), with: .color(.white.opacity(0.55 * (1 - ease))))
        }
    }

    private static func cell(_ p: Engine.Pop, rect: CGRect, scale: CGFloat, grow: CGFloat) -> CGRect {
        let s = scale * grow
        let cx = rect.minX + (CGFloat(p.x) + 0.5) * scale
        let cy = rect.minY + (CGFloat(p.y) + 0.5) * scale
        return CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
    }

    private static func drawChecker(gc: inout GraphicsContext, rect: CGRect, scale: CGFloat) {
        gc.fill(Path(rect), with: .color(Color(white: 0.20)))
        let tile = max(scale * 2, 8)
        var path = Path()
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : tile)
            while x < rect.maxX {
                path.addRect(CGRect(x: x, y: y, width: min(tile, rect.maxX - x), height: min(tile, rect.maxY - y)))
                x += tile * 2
            }
            y += tile; row += 1
        }
        gc.fill(path, with: .color(Color(white: 0.25)))
    }

    static func color(_ c: UInt32) -> Color {
        let a = Double((c >> 24) & 0xff) / 255
        guard a > 0 else { return Color(white: 0.22) }
        let r = Double(c & 0xff) / 255 / a
        let g = Double((c >> 8) & 0xff) / 255 / a
        let b = Double((c >> 16) & 0xff) / 255 / a
        return Color(.sRGB, red: min(1, r), green: min(1, g), blue: min(1, b), opacity: a)
    }
}

struct ContentView: View {
    @State var model: LiveModel
    @State private var driver: DisplayDriver
    @FocusState private var focused: Bool
    @State private var hovering = false

    init(model: LiveModel) {
        _model = State(initialValue: model)
        _driver = State(initialValue: DisplayDriver(model: model))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(white: 0.11).ignoresSafeArea()
            PixelCanvas(model: model)
                .padding(.horizontal, 14)
                .padding(.top, 30)
                .padding(.bottom, 70)
            if model.steps.isEmpty { emptyState }
            controls
        }
        .background(DisplayLinkHost(driver: driver))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; model.start() }
        .onHover { hovering = $0 }
        .onKeyPress(.leftArrow) { model.stepBy(-1); return .handled }
        .onKeyPress(.rightArrow) { model.stepBy(1); return .handled }
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "lLgGrR")) { press in
            switch press.characters.lowercased() {
            case "l": model.goLive()
            case "g": model.showGrid.toggle()
            case "r": model.replayAll()
            default: break
            }
            return .handled
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.3x3.square").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("Esperando al MCP…").font(.callout).foregroundStyle(.secondary)
            Text(model.directory.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
        }
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { if model.following { model.following = false } else { model.goLive() } } label: {
                    HStack(spacing: 4) {
                        Circle().fill(model.following ? Color.red : Color.gray).frame(width: 7, height: 7)
                        Text("LIVE").font(.caption2.weight(.bold))
                    }
                }
                .buttonStyle(.plain)
                .help("Seguir los cambios en vivo (L)")

                Text(model.currentStep?.caption ?? " ")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: model.currentStep?.id)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let step = model.currentStep {
                    if step.frames.count > 1 {
                        Button { model.togglePlay() } label: {
                            Image(systemName: model.playingFrames ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Reproducir la animación (espacio)")
                        Text("\(model.shownFrame + 1)/\(step.frames.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("#\(step.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if model.steps.count > 1 {
                Slider(value: Binding(
                    get: { Double(model.shownIndex ?? 0) },
                    set: { model.scrub(to: Int($0.rounded())) }),
                       in: 0...Double(model.steps.count - 1))
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(10)
    }
}
