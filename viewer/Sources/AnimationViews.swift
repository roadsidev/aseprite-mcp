import SwiftUI
import AppKit

/// The animation space: work in progress from animation sessions, and the
/// library of published (immutable) animations. Orange, never mint.
struct AnimationStage: View {
    @Bindable var state: AppState
    let clock: FrameClock
    let hovering: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Vista", selection: $state.animationTab) {
                Text("En curso").tag(AppState.AnimationTab.enCurso)
                Text("Publicadas · \(state.library.items.count)").tag(AppState.AnimationTab.biblioteca)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.mini)
            .frame(maxWidth: 230)
            .padding(.top, 2)
            if state.animationTab == .enCurso {
                WorkInProgress(state: state, clock: clock, hovering: hovering)
            } else {
                LibraryView(state: state, clock: clock)
            }
        }
    }
}

private struct WorkInProgress: View {
    let state: AppState
    let clock: FrameClock
    let hovering: Bool
    @State private var publishing = false
    @State private var name = ""
    @State private var error: String?

    private var model: LiveModel { state.animation }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PixelCanvas(model: model, clock: clock)
                    .opacity(model.steps.isEmpty ? 0 : 1)
                if model.steps.isEmpty {
                    StageEmpty(symbol: "film.stack", accent: .orange,
                               title: "Sin animación en curso",
                               detail: "Abre una sesión de animación (S) y pídele frames a Claude. Aquí se ve el loop mientras trabaja.")
                }
                if state.showInfo, let step = model.currentStep {
                    InfoOverlay(rows: StepInfo.rows(step, sessions: state.sessions))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 4)

            if let step = model.currentStep {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.caption.isEmpty ? "Animación en curso" : step.caption)
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(step.spriteName) · \(step.frames.count) frames · \(step.frames.reduce(0) { $0 + max(16, $1.durationMs) }) ms")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playingFrames ? "pause.fill" : "play.fill").frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(step.frames.count < 2)
                    .help("Reproducir o pausar (espacio)")
                    Button("Publicar…") {
                        name = (step.spriteName as NSString).deletingPathExtension
                        error = nil
                        publishing = true
                    }
                    .controlSize(.small)
                    .tint(.orange)
                    .buttonStyle(.borderedProminent)
                    .help("Congelar estos frames como un artefacto final con nombre")
                    .popover(isPresented: $publishing, arrowEdge: .top) { publishSheet(step) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private func publishSheet(_ step: Step) -> some View {
        let slug = AnimationLibrary.slug(name)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Publicar animación").font(.system(size: 13, weight: .semibold))
            TextField("Nombre", text: $name).textFieldStyle(.roundedBorder)
                .onSubmit { publish(step) }
            Text("animaciones/\(slug)/ · \(step.frames.count) frames · \(step.frames.count + 2) archivos (frames, sheet.png y meta.json)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Queda en solo lectura. Si el sprite cambia después, esta copia no cambia; si vuelves a publicar se crea una versión nueva.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancelar") { publishing = false }
                Button("Publicar") { publish(step) }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 300)
    }

    private func publish(_ step: Step) {
        do {
            let title = step.session.flatMap { s in state.sessions.sessions.first { $0.id.uuidString.lowercased() == s }?.title }
            let meta = try state.library.publish(name: name, step: step, sessionTitle: title)
            publishing = false
            state.animationTab = .biblioteca
            state.player.open(state.library.load(meta))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct LibraryView: View {
    let state: AppState
    let clock: FrameClock

    private var player: AnimationPlayer { state.player }

    var body: some View {
        VStack(spacing: 0) {
            if state.library.items.isEmpty {
                StageEmpty(symbol: "shippingbox", accent: .orange, title: "Nada publicado todavía",
                           detail: "En «En curso», Publicar congela los frames en animaciones/<nombre>/.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.library.items, id: \.slug) { meta in
                            let selected = player.artifact?.meta.slug == meta.slug
                            Button { player.open(state.library.load(meta)) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(meta.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        if let version = meta.version {
                                            Text(version).font(.system(size: 9, weight: .semibold).monospacedDigit())
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text("\(meta.frames.count) frames · \(meta.files) archivos")
                                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(selected ? Color.orange.opacity(0.18) : Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 8)

                ZStack {
                    ArtifactCanvas(player: player, clock: clock)
                    if player.artifact == nil {
                        Text("Elige una animación").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if state.showInfo, let artifact = player.artifact {
                        InfoOverlay(rows: ArtifactInfo.rows(artifact))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24).padding(.vertical, 8)

                if let artifact = player.artifact {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(artifact.meta.name + (artifact.meta.version.map { " · \($0)" } ?? ""))
                                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Image(systemName: artifact.intact ? "lock.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(artifact.intact ? Color.secondary : Color.red)
                                    .help(artifact.intact ? "Solo lectura; los archivos coinciden con su sha256" : "Algún archivo no coincide con meta.json")
                            }
                            Text("\(artifact.meta.frames.count) frames · \(artifact.meta.files) archivos · \(artifact.meta.width)×\(artifact.meta.height) · \(artifact.meta.totalMs) ms")
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 20)
                        }
                        .buttonStyle(.plain).help("Reproducir o pausar (espacio)")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([artifact.directory]) } label: {
                            Image(systemName: "folder").frame(width: 20)
                        }
                        .buttonStyle(.plain).help("Mostrar en Finder")
                        Button { state.showInfo.toggle() } label: {
                            Image(systemName: state.showInfo ? "info.circle.fill" : "info.circle").frame(width: 20)
                        }
                        .buttonStyle(.plain).help("Metadata (I)")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
        .onAppear {
            state.library.refresh()
            if player.artifact == nil, let first = state.library.items.first { player.open(state.library.load(first)) }
        }
    }
}

struct ArtifactCanvas: View {
    let player: AnimationPlayer
    let clock: FrameClock
    @Environment(\.displayScale) private var backing

    var body: some View {
        let tick = clock.tick
        let backing = backing
        Canvas(rendersAsynchronously: false) { gc, size in
            _ = tick
            guard let artifact = player.artifact, !artifact.images.isEmpty else { return }
            let image = artifact.images[min(player.frame, artifact.images.count - 1)]
            let w = artifact.meta.width, h = artifact.meta.height
            let target = PixelCanvas.targetScale(width: w, height: h, size: size, backing: backing)
            let scale = player.approachScale(target, now: player.renderTime)
            let rect = PixelCanvas.spriteRect(width: w, height: h, size: size, scale: scale, backing: backing)
            var shadow = gc
            shadow.addFilter(.shadow(color: .black.opacity(0.3), radius: 14, x: 0, y: 7))
            shadow.fill(Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 5), with: .color(Color(white: 0.12)))
            PixelCanvas.drawChecker(gc: &gc, rect: rect, scale: scale)
            gc.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
            gc.stroke(Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 5),
                      with: .color(.orange.opacity(0.25)), lineWidth: 0.5)
        }
        .accessibilityLabel("Animación publicada")
    }
}

struct StageEmpty: View {
    let symbol: String
    let accent: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(accent.opacity(0.8))
                .frame(width: 62, height: 62)
                .background(.white.opacity(0.035), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 260)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Key/value panel toggled with I.
struct InfoOverlay: View {
    let rows: [(String, String)]

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.0).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                        Text(row.1).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .padding(10)
            .frame(maxWidth: 360)
            .background(.black.opacity(0.72), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            Spacer()
        }
        .transition(.opacity)
    }
}

enum StepInfo {
    @MainActor
    static func rows(_ step: Step, sessions: SessionStore) -> [(String, String)] {
        let session = step.session.flatMap { s in sessions.sessions.first { $0.id.uuidString.lowercased() == s } }
        let size = step.frames.first.map { "\($0.width) × \($0.height)" } ?? "—"
        return [("paso", "#\(step.id) · \(step.tool)"),
                ("sprite", step.sprite),
                ("tamaño", size),
                ("frames", "\(step.frames.count) · \(step.frames.reduce(0) { $0 + max(16, $1.durationMs) }) ms"),
                ("sesión", session?.title ?? step.session ?? "fuera de Pixel Live"),
                ("tipo", step.kind ?? "—"),
                ("hora", Date(timeIntervalSince1970: step.timestamp).formatted(date: .abbreviated, time: .standard))]
    }
}

enum ArtifactInfo {
    static func rows(_ a: AnimationArtifact) -> [(String, String)] {
        let m = a.meta
        return [("nombre", m.name),
                ("carpeta", a.directory.path),
                ("publicada", m.created.formatted(date: .abbreviated, time: .shortened)),
                ("archivos", "\(m.files) (\(m.frames.count) frames, sheet.png, meta.json)"),
                ("duraciones", m.frames.map { "\($0.durationMs ?? 100)" }.joined(separator: " · ") + " ms"),
                ("sesión", m.source.sessionTitle ?? m.source.session ?? "fuera de Pixel Live"),
                ("origen", "\((m.source.sprite as NSString).lastPathComponent) · paso #\(m.source.seq)"),
                ("editado", m.source.editedAt.formatted(date: .abbreviated, time: .standard)),
                ("integridad", a.intact ? "sha256 ok · solo lectura" : "¡no coincide con meta.json!")]
    }
}
