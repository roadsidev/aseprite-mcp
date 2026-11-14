import SwiftUI
import AppKit

/// Everything the window shows. Sprite work and animation work have separate
/// models, separate sessions and separate looks; they never share a step.
@MainActor
@Observable
final class AppState {
    enum Space: String, CaseIterable { case sprites, animaciones }
    enum AnimationTab: String, CaseIterable { case enCurso, biblioteca }

    var space: Space = .sprites
    var animationTab: AnimationTab = .enCurso
    var showSessions = false
    var showInfo = false

    let workspace: URL
    let sprites: LiveModel
    let animation: LiveModel
    let sessions: SessionStore
    let library: AnimationLibrary
    let player = AnimationPlayer()

    init(liveDirectory: URL) {
        workspace = liveDirectory.deletingLastPathComponent()
        sprites = LiveModel(directory: liveDirectory, accepts: { !$0.isAnimationWork })
        animation = LiveModel(directory: liveDirectory, accepts: { $0.isAnimationWork }, autoPlay: true)
        let args = CommandLine.arguments
        func arg(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        sessions = SessionStore(workspace: workspace,
                                support: arg("--support-dir").map { URL(fileURLWithPath: $0, isDirectory: true) })
        library = AnimationLibrary(workspace: workspace)
        // Launch flags for self-tests: --space sprites|animaciones|biblioteca, --show-sessions
        switch arg("--space") {
        case "animaciones": space = .animaciones
        case "biblioteca": space = .animaciones; animationTab = .biblioteca
        default: break
        }
        if args.contains("--show-sessions") {
            // ContentView opens the panel once the window exists, like pressing S.
            if let latest = sessions.sessions(of: kind).first { select(session: latest.id, kind: kind) }
        }
    }

    var kind: SessionKind { space == .sprites ? .sprites : .animacion }
    var accent: Color { space == .sprites ? .mint : .orange }
    var liveModel: LiveModel { space == .sprites ? sprites : animation }

    /// Show only the selected session's steps on the matching canvas.
    func select(session id: UUID?, kind: SessionKind) {
        sessions.selected[kind] = id
        if let id { sessions.open(id) }
        let model = kind == .sprites ? sprites : animation
        model.sessionFilter = id?.uuidString.lowercased()
    }

    func start() {
        sprites.start()
        animation.start()
        library.refresh()
    }
}

/// Hands the hosting NSWindow to SwiftUI code (pin level, opacity, resize).
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = configure
        return view
    }
    func updateNSView(_ view: AccessorView, context: Context) {
        view.onWindow = configure
        if let window = view.window { configure(window) }
    }

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

struct TopBar: View {
    @Bindable var state: AppState
    @Binding var pinned: Bool
    @Binding var opacity: Double
    let window: NSWindow?
    @State private var showOpacity = false

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 64)   // traffic lights
            Picker("Espacio", selection: $state.space) {
                Text("Sprites").tag(AppState.Space.sprites)
                Text("Animaciones").tag(AppState.Space.animaciones)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 190)
            .help("Taller de sprites o animaciones (1 · 2)")
            Spacer(minLength: 4)
            barButton(opacity < 0.995 ? "circle.lefthalf.filled" : "circle.fill",
                      help: "Transparencia de la ventana", active: opacity < 0.995) { showOpacity.toggle() }
                .popover(isPresented: $showOpacity, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Transparencia").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text("\(Int((opacity * 100).rounded())) %").font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $opacity, in: 0.25...1).controlSize(.small)
                    }
                    .padding(12).frame(width: 220)
                }
            barButton(pinned ? "pin.fill" : "pin", help: pinned ? "Desfijar: ventana normal (P)" : "Fijar encima de todo (P)",
                      active: pinned) { pinned.toggle() }
            barButton("sidebar.right", help: "Sesiones de Claude (S)", active: state.showSessions) { toggleSessions() }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private func barButton(_ symbol: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? state.accent : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    func toggleSessions() { Self.toggleSessions(state: state, window: window) }

    /// Opening the panel widens the window instead of shrinking the canvas.
    static func toggleSessions(state: AppState, window: NSWindow?) {
        let opening = !state.showSessions
        guard let window else { state.showSessions = opening; return }
        var frame = window.frame
        let width = SessionPanel.width
        if opening {
            frame.size.width += width
            if let visible = window.screen?.visibleFrame, frame.maxX > visible.maxX {
                frame.origin.x = max(visible.minX, visible.maxX - frame.width)
            }
            // Grow first, then show: SwiftUI's min size never fights the resize.
            window.setFrame(frame, display: true, animate: true)
            withAnimation(.easeOut(duration: 0.2)) { state.showSessions = true }
        } else {
            frame.size.width = max(360, frame.width - width)
            state.showSessions = false
            DispatchQueue.main.async { window.setFrame(frame, display: true, animate: true) }
        }
    }
}
