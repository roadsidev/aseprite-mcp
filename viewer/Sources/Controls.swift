import SwiftUI

struct PlaybackControls: View {
    let model: LiveModel
    let clock: FrameClock
    let hovering: Bool
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sliderPosition = 0.0
    @State private var scrubbing = false
    @State private var scrubCount = 0
    @FocusState private var focusedControl: String?

    private var motion: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86) }
    private var caption: String {
        guard let step = model.currentStep else { return "Listo para crear" }
        return step.caption.isEmpty ? "Sprite actualizado" : step.caption
    }
    private var toolsVisible: Bool { hovering || focusedControl != nil }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(caption)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).truncationMode(.tail)
                            .contentTransition(.opacity)
                            .animation(motion, value: caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(caption)
                        if let step = model.currentStep {
                            Text("#\(step.id)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: Double(step.id)))
                                .animation(motion, value: step.id)
                                .accessibilityLabel("Paso \(step.id)")
                        }
                    }
                    HStack(spacing: 8) {
                        Text(model.currentStep?.spriteName ?? "Conexión local · MCP")
                            .lineLimit(1).truncationMode(.middle)
                            .contentTransition(.opacity)
                            .animation(motion, value: model.currentStep?.sprite)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let frame = model.currentStep?.frames[model.shownFrame] {
                            Text("\(frame.width) × \(frame.height)")
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(motion, value: frame.width)
                                .animation(motion, value: frame.height)
                                .accessibilityLabel("\(frame.width) por \(frame.height) píxeles")
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                    timeline

                    HStack(spacing: 10) {
                        liveButton
                        if let step = model.currentStep, step.frames.count > 1 {
                            Button { model.togglePlay() } label: {
                                Image(systemName: model.playingFrames ? "pause.fill" : "play.fill")
                                    .contentTransition(.symbolEffect(.replace))
                                    .frame(width: 24, height: 22)
                            }
                            .buttonStyle(.plain)
                            .focused($focusedControl, equals: "play")
                            .help(model.playingFrames ? "Pausar la animación (espacio)" : "Reproducir la animación (espacio)")
                            .accessibilityLabel(model.playingFrames ? "Pausar" : "Reproducir")
                            Text("\(model.shownFrame + 1) / \(step.frames.count)")
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                                // Do not start a text animation for every playback frame.
                                .transaction { $0.animation = nil }
                                .accessibilityLabel("Fotograma \(model.shownFrame + 1) de \(step.frames.count)")
                        }
                        Spacer(minLength: 0)
                        Text(model.steps.isEmpty ? "Sin pasos" : "\((model.shownIndex ?? 0) + 1) de \(model.steps.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(motion, value: model.shownIndex)
                            .animation(motion, value: model.steps.count)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .animation(motion, value: model.currentStep?.frames.count)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .glassEffectID("transport", in: glass)
                // Hover tools float above the transport, so they never take canvas height.
                .overlay(alignment: .topTrailing) {
                    ZStack {
                    if toolsVisible, model.currentStep != nil {
                        HStack(spacing: 2) {
                            tool("arrow.counterclockwise", help: "Repetir los cambios de este sprite (R)") { model.replayAll() }
                            tool(model.showGrid ? "square.grid.3x3.fill" : "square.grid.3x3", help: "Mostrar u ocultar la grilla (G)") { model.showGrid.toggle() }
                                .foregroundStyle(model.showGrid ? Color.mint : Color.primary)
                            tool("chevron.left", help: "Paso anterior (←)") { model.stepBy(-1) }
                                .disabled((model.shownIndex ?? 0) <= 0)
                            tool("chevron.right", help: "Paso siguiente (→)") { model.stepBy(1) }
                                .disabled((model.shownIndex ?? 0) >= model.steps.count - 1)
                        }
                        .padding(4)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("tools", in: glass)
                        .glassEffectTransition(.matchedGeometry)
                        .transition(.opacity.combined(with: .offset(y: 5)))
                    }
                    }
                    .offset(y: -40)
                }
            }
        }
        .animation(motion, value: toolsVisible)
        .animation(motion, value: model.following)
        .onAppear { syncSlider() }
        .onChange(of: model.shownIndex) { _, _ in syncSlider() }
        .onChange(of: model.steps.count) { _, _ in syncSlider() }
        .onChange(of: model.following) { _, _ in syncSlider() }
        .onChange(of: model.replaying) { _, _ in syncSlider() }
    }

    private var liveButton: some View {
        Button { model.toggleLive() } label: {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(model.following ? Color.mint : Color.secondary)
                    .symbolEffect(.pulse, options: .nonRepeating,
                                  value: model.following && !reduceMotion ? model.arrival : 0)
                    .frame(width: 8, height: 12)
                Text(model.following ? "LIVE" : "HISTORIAL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(model.following ? Color.mint.opacity(0.10) : Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(model.following ? Color.mint.opacity(0.16) : Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: "live")
        .help(model.following ? "Pausar el seguimiento en vivo (L)" : "Volver al último paso y seguir en vivo (L)")
        .accessibilityLabel(model.following ? "Seguimiento en vivo activado" : "Volver al directo")
    }

    private var timeline: some View {
        VStack(spacing: 1) {
            ZStack(alignment: .bottom) {
                Canvas { gc, size in
                    let count = scrubbing ? scrubCount : model.steps.count
                    let marks = min(40, count)
                    guard marks > 1 else { return }
                    for i in 0..<marks {
                        let x = 6 + (size.width - 12) * Double(i) / Double(marks - 1)
                        let mark = CGRect(x: x, y: size.height - 2, width: 1, height: 2)
                        gc.fill(Path(mark), with: .color(.white.opacity(0.18)))
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
                Slider(value: Binding(get: { sliderPosition }, set: { value in
                    sliderPosition = value
                    let count = scrubbing ? scrubCount : model.steps.count
                    let index = Int((value * Double(max(0, count - 1))).rounded())
                    if index != model.shownIndex { model.scrub(to: index) }
                }), in: 0...1, onEditingChanged: { editing in
                    if editing {
                        scrubCount = model.steps.count
                        scrubbing = true
                        if model.following { model.toggleLive() }
                    } else {
                        scrubbing = false
                        syncSlider()
                    }
                })
                .focused($focusedControl, equals: "timeline")
                .controlSize(.mini)
                .tint(.mint.opacity(0.8))
                .disabled(model.steps.count < 2)
                .accessibilityLabel("Historial de pasos")
                .accessibilityValue(model.steps.isEmpty ? "Sin pasos" : "Paso \((model.shownIndex ?? 0) + 1) de \(model.steps.count)")
                .help("Recorrer los cambios del sprite (← →)")
                .padding(.bottom, 3)
            }
            .frame(height: 18)
            RevealProgress(engine: model.engine, clock: clock)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    private func syncSlider() {
        guard !scrubbing else { return }
        // While following, incoming events extend the live endpoint instead of
        // pulling the thumb backwards before the queued reveal begins.
        let fraction = model.following && !model.replaying && !model.steps.isEmpty ? 1 :
            Double(model.shownIndex ?? 0) / Double(max(1, model.steps.count - 1))
        withAnimation(motion) { sliderPosition = fraction }
    }

    private func tool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focusedControl, equals: help).help(help).accessibilityLabel(help)
    }
}

/// Isolate the vsync observation: the glass and text don't rebuild at 120 Hz.
private struct RevealProgress: View {
    let engine: Engine
    let clock: FrameClock

    var body: some View {
        let tick = clock.tick
        Canvas { gc, size in
            _ = tick
            guard engine.isRevealing else { return }
            let progress = engine.revealProgress(now: engine.renderTime)
            let opacity = Engine.smooth(progress / 0.08) * Engine.smooth((1 - progress) / 0.15)
            gc.fill(Path(CGRect(x: 0, y: 0, width: size.width * progress, height: size.height)),
                    with: .color(.mint.opacity(opacity * 0.7)))
        }
    }
}
