import SwiftUI
import AppKit

/// Advances the model once per display refresh (vsync), outside SwiftUI's
/// view updates, so the Canvas only ever reads state.
@MainActor
final class DisplayDriver: NSObject {
    private var link: CADisplayLink?
    private let model: LiveModel
    let clock = FrameClock()

    init(model: LiveModel) {
        self.model = model
    }

    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        updateRefreshRate(screen: view.window?.screen)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--self-test"), i + 1 < args.count {
            let seconds = args.firstIndex(of: "--seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 6
            let every = args.firstIndex(of: "--capture-every").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 0
            let test = SelfTest(directory: URL(fileURLWithPath: args[i + 1], isDirectory: true),
                                seconds: seconds, captureEvery: every)
            test.model = model
            test.window = view.window
            test.captureWindow = args.contains("--capture-window")
            selfTest = test
        }
    }

    func updateRefreshRate(screen: NSScreen?) {
        let reported = screen?.maximumFramesPerSecond ?? 120
        let maximum = Float(reported > 0 ? reported : 120)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
    }

    func detach() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        model.tick(now: link.targetTimestamp)
        clock.tick &+= 1
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
    weak var window: NSWindow?
    var captureWindow = false
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
        if captureWindow, captureEvery > 0, now - lastCapture >= captureEvery, let view = window?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            lastCapture = now
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = directory.appendingPathComponent(String(format: "win-%03d.png", captures))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            captures += 1
        }
        if !captureWindow, let model, captureEvery > 0, now - lastCapture >= captureEvery {
            lastCapture = now
            let renderNow = model.engine.renderTime
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
    func makeNSView(context: Context) -> DisplayLinkView { DisplayLinkView(driver: driver) }
    func updateNSView(_ nsView: DisplayLinkView, context: Context) {}
    static func dismantleNSView(_ nsView: DisplayLinkView, coordinator: ()) { nsView.driver.detach() }
}

final class DisplayLinkView: NSView {
    let driver: DisplayDriver

    init(driver: DisplayDriver) {
        self.driver = driver
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            // In particular, --capture-window now always receives a window.
            driver.attach(to: self)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                name: NSWindow.didChangeScreenNotification, object: window)
        } else {
            driver.detach()
        }
    }

    @objc private func screenChanged() { driver.updateRefreshRate(screen: window?.screen) }
}

/// Bumped after the model advances. Only PixelCanvas and the thin reveal
/// progress indicator observe it, keeping the glass/text out of the vsync loop.
@MainActor
@Observable
final class FrameClock {
    var tick = 0
}

struct ContentView: View {
    @State var model: LiveModel
    @State private var driver: DisplayDriver
    @FocusState private var focused: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: LiveModel) {
        _model = State(initialValue: model)
        _driver = State(initialValue: DisplayDriver(model: model))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.105, green: 0.119, blue: 0.139), Color(red: 0.065, green: 0.073, blue: 0.088)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    PixelCanvas(model: model, clock: driver.clock)
                        .opacity(model.steps.isEmpty ? 0 : 1)
                    if model.steps.isEmpty { emptyState.transition(.opacity) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 4)
                PlaybackControls(model: model, clock: driver.clock, hovering: hovering)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        .background(DisplayLinkHost(driver: driver))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            model.engine.reduceMotion = reduceMotion
            model.start()
        }
        .onChange(of: reduceMotion) { _, value in model.engine.reduceMotion = value }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: model.steps.isEmpty)
        .onKeyPress(.leftArrow) { model.stepBy(-1); return .handled }
        .onKeyPress(.rightArrow) { model.stepBy(1); return .handled }
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "lLgGrR")) { press in
            switch press.characters.lowercased() {
            case "l": model.toggleLive()
            case "g": model.showGrid.toggle()
            case "r": model.replayAll()
            default: break
            }
            return .handled
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 29, weight: .light))
                .foregroundStyle(.mint.opacity(0.8))
                .frame(width: 66, height: 66)
                .background(.white.opacity(0.035), in: .rect(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            VStack(spacing: 5) {
                Text("Esperando al MCP…")
                    .font(.system(size: 15, weight: .medium))
                Text("Cada cambio, píxel a píxel.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Label(model.connected ? "Conectado · esperando un sprite" : "Escuchando cambios locales", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .help(model.directory.path)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
