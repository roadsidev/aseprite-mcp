import SwiftUI
import AppKit

/// Advances the model once per display refresh (vsync), outside SwiftUI's
/// view updates, so the Canvas only ever reads state.
@MainActor
final class DisplayDriver: NSObject {
    private var link: CADisplayLink?
    private let model: LiveModel
    private let others: [(CFTimeInterval) -> Void]
    let clock = FrameClock()

    /// `model` drives self-test captures; `others` advance on the same vsync.
    init(model: LiveModel, others: [(CFTimeInterval) -> Void] = []) {
        self.model = model
        self.others = others
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
        for tick in others { tick(link.targetTimestamp) }
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
    @State var state: AppState
    @State private var driver: DisplayDriver
    @State private var window: NSWindow?
    @FocusState private var focused: Bool
    @State private var hovering = false
    @AppStorage("pinned") private var pinned = true
    @AppStorage("windowOpacity") private var opacity = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState) {
        _state = State(initialValue: state)
        let animation = state.animation, player = state.player
        _driver = State(initialValue: DisplayDriver(model: state.sprites, others: [
            { animation.tick(now: $0) }, { player.tick(now: $0) }]))
    }

    private var model: LiveModel { state.sprites }

    var body: some View {
        ZStack {
            LinearGradient(colors: state.space == .sprites
                           ? [Color(red: 0.105, green: 0.119, blue: 0.139), Color(red: 0.065, green: 0.073, blue: 0.088)]
                           : [Color(red: 0.135, green: 0.112, blue: 0.098), Color(red: 0.078, green: 0.068, blue: 0.062)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.3), value: state.space)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TopBar(state: state, pinned: $pinned, opacity: $opacity, window: window)
                    if state.space == .sprites { spriteStage } else {
                        AnimationStage(state: state, clock: driver.clock, hovering: hovering)
                    }
                }
                .frame(minWidth: 340)
                if state.showSessions {
                    Divider().opacity(0.5)
                    SessionPanel(state: state)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .background(DisplayLinkHost(driver: driver))
        .background(WindowAccessor { w in
            if window !== w { DispatchQueue.main.async { window = w } }
            let level: NSWindow.Level = pinned ? .floating : .normal
            if w.level != level { w.level = level }
            let alpha = CGFloat(max(0.25, min(1, opacity)))
            if abs(w.alphaValue - alpha) > 0.001 { w.alphaValue = alpha }
        })
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            model.engine.reduceMotion = reduceMotion
            state.animation.engine.reduceMotion = reduceMotion
            state.player.reduceMotion = reduceMotion
            state.start()
            if CommandLine.arguments.contains("--show-sessions") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    TopBar.toggleSessions(state: state, window: window)
                }
            }
        }
        .onChange(of: reduceMotion) { _, value in
            model.engine.reduceMotion = value
            state.animation.engine.reduceMotion = value
            state.player.reduceMotion = value
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: model.steps.isEmpty)
        .animation(.easeOut(duration: 0.2), value: state.showInfo)
        .onKeyPress(.leftArrow) { key { arrow(-1) } }
        .onKeyPress(.rightArrow) { key { arrow(1) } }
        .onKeyPress(.space) { key { space() } }
        .onKeyPress(characters: .init(charactersIn: "lLgGrRiIpPsS12")) { press in
            key {
                switch press.characters.lowercased() {
                case "l": state.liveModel.toggleLive()
                case "g": state.liveModel.showGrid.toggle()
                case "r": state.liveModel.replayAll()
                case "i": state.showInfo.toggle()
                case "p": pinned.toggle()
                case "s": TopBar.toggleSessions(state: state, window: window)
                case "1": state.space = .sprites
                case "2": state.space = .animaciones
                default: break
                }
            }
        }
    }

    /// Shortcuts never steal keys from the chat field.
    private func key(_ action: () -> Void) -> KeyPress.Result {
        if window?.firstResponder is NSText { return .ignored }
        action()
        return .handled
    }

    private var inLibrary: Bool { state.space == .animaciones && state.animationTab == .biblioteca }

    private func arrow(_ delta: Int) {
        if inLibrary { state.player.step(delta) } else { state.liveModel.stepBy(delta) }
    }

    private func space() {
        // The sprite workshop is a gallery of changes: nothing to play there.
        if inLibrary { state.player.togglePlay() }
        else if state.space == .animaciones { state.animation.togglePlay() }
    }

    private var spriteStage: some View {
        VStack(spacing: 0) {
            ZStack {
                PixelCanvas(model: model, clock: driver.clock)
                    .opacity(model.steps.isEmpty ? 0 : 1)
                if model.steps.isEmpty { emptyState.transition(.opacity) }
                if state.showInfo, let step = model.currentStep {
                    InfoOverlay(rows: StepInfo.rows(step, sessions: state.sessions))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
            PlaybackControls(model: model, clock: driver.clock, hovering: hovering)
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            StageEmpty(symbol: "square.stack.3d.up", accent: .mint,
                       title: model.sessionFilter == nil ? "Esperando al MCP…" : "Esta sesión todavía no dibuja",
                       detail: model.sessionFilter == nil
                           ? "Cada cambio de sprite, píxel a píxel. Las animaciones van aparte (2)."
                           : "Aparecerá aquí con su primer cambio. «Todas las sesiones» muestra el resto.")
                .frame(maxHeight: 200)
            Label(model.connected ? "Conectado · esperando un sprite" : "Escuchando cambios locales", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .help(model.directory.path)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
