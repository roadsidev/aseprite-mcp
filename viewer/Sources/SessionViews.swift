import SwiftUI
import AppKit

/// A tiny herdr: the Claude sessions of the current space, each one a
/// persistent `claude -p --resume` conversation with its token budget in view.
struct SessionPanel: View {
    static let width: CGFloat = 330
    let state: AppState

    private var store: SessionStore { state.sessions }
    private var kind: SessionKind { state.kind }
    private var selectedID: UUID? { store.selected[kind] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sesiones · \(kind.label)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    let record = store.create(kind: kind)
                    state.select(session: record.id, kind: kind)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help("Nueva sesión de \(kind.label.lowercased())")
            }
            .padding(.horizontal, 12).frame(height: 34)

            sessionList
            Divider().opacity(0.4)

            if let record = store.session(selectedID) {
                SessionDetail(store: store, record: record, accent: state.accent)
                    .id(record.id)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 22, weight: .light))
                        .foregroundStyle(state.accent.opacity(0.8))
                    Text(store.sessions(of: kind).isEmpty ? "Crea una sesión con +" : "Elige una sesión")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Cada sesión solo ve el MCP de Aseprite y persiste entre mensajes.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.width)
        .background(.black.opacity(0.18))
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 2) {
                row(title: "Todas las sesiones", subtitle: "El lienzo muestra cualquier cambio", id: nil, record: nil)
                ForEach(store.sessions(of: kind)) { record in
                    row(title: record.title, subtitle: subtitle(record), id: record.id, record: record)
                        .contextMenu {
                            Button("Quitar de Pixel Live", role: .destructive) {
                                if selectedID == record.id { state.select(session: nil, kind: kind) }
                                store.remove(record.id)
                            }
                        }
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitle(_ r: SessionRecord) -> String {
        let model = ModelChoice.label(r.model)
        return r.turns == 0 ? "\(model) · nueva" : "\(model) · \(r.contextTokens.tokens) tokens · \(r.turns) turnos"
    }

    private func row(title: String, subtitle: String, id: UUID?, record: SessionRecord?) -> some View {
        let selected = selectedID == id
        return Button { state.select(session: id, kind: kind) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(record.map { store.running.contains($0.id) ? state.accent : ($0.cacheRemaining() > 0 ? Color.green.opacity(0.7) : Color.white.opacity(0.18)) } ?? .clear)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? state.accent.opacity(0.14) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SessionDetail: View {
    let store: SessionStore
    let record: SessionRecord
    let accent: Color
    @State private var draft = ""
    @State private var confirmCold = false
    @State private var now = Date()
    @FocusState private var composing: Bool

    private var running: Bool { store.running.contains(record.id) }
    private var coldRewrite: Bool {
        record.turns > 0 && record.contextTokens > 20_000 && record.cacheRemaining(at: now) == 0
    }

    var body: some View {
        VStack(spacing: 0) {
            TokenMeter(record: record, usage: store.usage, now: now, accent: accent)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().opacity(0.4)
            transcript
            composer
        }
        .task {
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear { composing = true }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.lines(record.id)) { line in
                        ChatBubble(line: line, accent: accent).id(line.id)
                    }
                    if let partial = store.streaming[record.id], !partial.isEmpty {
                        ChatBubble(line: ChatLine(role: .assistant, text: partial), accent: accent)
                    }
                    if running {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: store.lines(record.id).count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: store.streaming[record.id]?.count ?? 0) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if confirmCold {
                VStack(alignment: .leading, spacing: 6) {
                    Label("La caché expiró: este mensaje vuelve a escribir ~\(record.contextTokens.tokens) tokens de contexto.",
                          systemImage: "snowflake")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    HStack {
                        Button("Enviar igual") { confirmCold = false; send(force: true) }
                        Button("Cancelar") { confirmCold = false }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
            }
            TextField(running ? "Claude está trabajando…" : "Pídele algo a Claude", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...6)
                .focused($composing)
                .onSubmit { send(force: false) }
                .padding(8)
                .background(.white.opacity(0.05), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            HStack(spacing: 6) {
                Menu {
                    ForEach(ModelChoice.all, id: \.id) { choice in
                        Button(choice.label) { store.update(record.id) { $0.model = choice.id } }
                    }
                } label: { Text(ModelChoice.label(record.model)) }
                .help("Modelo. Cambiarlo a mitad de sesión no reutiliza la caché.")
                Menu {
                    ForEach(effortLevels, id: \.self) { level in
                        Button(level) { store.update(record.id) { $0.effort = level } }
                    }
                } label: { Text("effort \(record.effort)") }
                .help("Nivel de esfuerzo (--effort)")
                Spacer()
                if running {
                    Button { store.stop(record.id) } label: { Label("Detener", systemImage: "stop.fill") }
                        .tint(.red)
                } else {
                    Button { send(force: false) } label: { Label("Enviar", systemImage: "arrow.up") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .tint(accent)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .controlSize(.small)
            .font(.system(size: 10))
        }
        .padding(10)
    }

    private func send(force: Bool) {
        guard !running, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if coldRewrite && !force { confirmCold = true; return }
        store.send(draft, to: record.id)
        draft = ""
    }
}

struct TokenMeter: View {
    let record: SessionRecord
    let usage: [UsageWindow]
    let now: Date
    let accent: Color

    var body: some View {
        let fraction = min(1, Double(record.contextTokens) / Double(max(1, record.contextWindow)))
        let remaining = record.cacheRemaining(at: now)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Contexto").font(.system(size: 10, weight: .semibold))
                Text("\(record.contextTokens.tokens) / \(record.contextWindow.tokens)")
                    .font(.system(size: 10).monospacedDigit())
                Text(String(format: "%.1f %%", fraction * 100)).font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                cacheBadge(remaining)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.07))
                    Capsule().fill(fraction > 0.8 ? Color.red : fraction > 0.5 ? Color.orange : accent)
                        .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
            if record.turns > 0 {
                Text("último pedido: entrada \(record.lastInput.tokens) · caché escrita \(record.lastCacheWrite.tokens) · leída \(record.lastCacheRead.tokens) · salida \(record.lastOutput.tokens)")
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(String(format: "turno $%.3f · sesión $%.2f (equivalente API)", record.lastCostUSD, record.totalCostUSD))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
            if !usage.isEmpty {
                HStack(spacing: 8) {
                    ForEach(usage, id: \.name) { window in
                        Text("\(Self.windowName(window.name)) \(Int((window.utilization * 100).rounded())) %")
                            .foregroundStyle(window.utilization > 0.9 ? Color.red : window.utilization > 0.7 ? Color.orange : Color.secondary)
                            .help(window.resetsAt.map { "Se renueva \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                    }
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
            }
        }
    }

    @ViewBuilder private func cacheBadge(_ remaining: TimeInterval) -> some View {
        if record.turns == 0 {
            Text("sin caché").font(.system(size: 9)).foregroundStyle(.tertiary)
        } else if remaining > 0 {
            Label("caché \(Int(remaining) / 60):\(String(format: "%02d", Int(remaining) % 60))", systemImage: "flame.fill")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(remaining < 300 ? Color.orange : Color.green)
                .help("La caché de 1 h sigue caliente: el próximo mensaje lee el contexto barato.")
        } else {
            Label("caché fría", systemImage: "snowflake")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.blue)
                .help("El próximo mensaje vuelve a escribir todo el contexto en caché.")
        }
    }

    static func windowName(_ key: String) -> String {
        switch key {
        case "five_hour": return "5 h"
        case "seven_day": return "7 días"
        case "seven_day_opus": return "7 d Opus"
        case "seven_day_sonnet": return "7 d Sonnet"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }
}

struct ChatBubble: View {
    let line: ChatLine
    let accent: Color

    var body: some View {
        switch line.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(line.text).font(.system(size: 12)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(accent.opacity(0.16), in: .rect(cornerRadius: 10))
            }
        case .assistant:
            Text((try? AttributedString(markdown: line.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line.text))
                .font(.system(size: 12)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(line.text, systemImage: "paintbrush.pointed")
                .font(.system(size: 10).monospaced()).foregroundStyle(.secondary).lineLimit(3)
        case .error:
            Label(line.text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10)).foregroundStyle(.red).textSelection(.enabled)
        case .info:
            Text(line.text).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
