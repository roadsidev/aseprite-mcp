import Foundation
import Observation

/// Design work and animation work never share a session.
enum SessionKind: String, Codable, CaseIterable {
    case sprites, animacion
    var label: String { self == .sprites ? "Sprites" : "Animación" }
}

struct ModelChoice: Hashable {
    let id: String
    let label: String
    static let all = [ModelChoice(id: "claude-opus-5-5", label: "Opus 5.5"),
                      ModelChoice(id: "claude-sonnet-5-5", label: "Sonnet 5.5"),
                      ModelChoice(id: "claude-haiku-5-5", label: "Haiku 5.5")]
    static func label(_ id: String) -> String { all.first { $0.id == id }?.label ?? id }
}

let effortLevels = ["low", "medium", "high", "xhigh", "max"]

/// One persistent Claude conversation (claude -p --resume), as listed in the panel.
struct SessionRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    let kind: SessionKind
    var model: String
    var effort: String
    let created: Date
    var started = false            // Claude has the session on disk: use --resume
    var turns = 0
    var lastTurnEnd: Date?         // the 1 h prompt cache is measured from here
    var contextTokens = 0          // input + cache write + cache read of the last request
    var contextWindow = 1_000_000
    var lastInput = 0, lastCacheWrite = 0, lastCacheRead = 0, lastOutput = 0
    var lastCostUSD = 0.0
    var totalCostUSD = 0.0

    static let cacheTTL: TimeInterval = 3600

    func cacheRemaining(at now: Date = .now) -> TimeInterval {
        guard let end = lastTurnEnd, contextTokens > 0 else { return 0 }
        return max(0, Self.cacheTTL - now.timeIntervalSince(end))
    }
}

struct ChatLine: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant, tool, error, info }
    var id = UUID()
    let role: Role
    var text: String
    var date = Date()
}

/// Usage windows from the CLI's rate_limit_event (subscription utilization).
struct UsageWindow: Hashable {
    let name: String
    let utilization: Double
    let resetsAt: Date?
}

@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [SessionRecord] = []
    private(set) var transcripts: [UUID: [ChatLine]] = [:]
    private(set) var streaming: [UUID: String] = [:]   // partial assistant text
    private(set) var running: Set<UUID> = []
    private(set) var usage: [UsageWindow] = []
    var selected: [SessionKind: UUID] = [:]

    let workspace: URL
    @ObservationIgnored private let support: URL
    @ObservationIgnored private var processes: [UUID: Process] = [:]

    init(workspace: URL, support: URL? = nil) {
        self.workspace = workspace
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.support = support ?? base.appendingPathComponent("Pixel Live", isDirectory: true)
        for sub in ["transcripts", "mcp"] {
            try? FileManager.default.createDirectory(at: self.support.appendingPathComponent(sub),
                                                     withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: self.support.appendingPathComponent("sessions.json")),
           let saved = try? JSONDecoder.iso.decode([SessionRecord].self, from: data) {
            sessions = saved
        }
    }

    func sessions(of kind: SessionKind) -> [SessionRecord] {
        sessions.filter { $0.kind == kind }.sorted { ($0.lastTurnEnd ?? $0.created) > ($1.lastTurnEnd ?? $1.created) }
    }

    func session(_ id: UUID?) -> SessionRecord? { id.flatMap { id in sessions.first { $0.id == id } } }

    /// Read-only for views; call open(_:) first so the transcript is loaded.
    func lines(_ id: UUID) -> [ChatLine] { transcripts[id] ?? [] }

    func open(_ id: UUID) { _ = transcript(id) }

    private func transcript(_ id: UUID) -> [ChatLine] {
        if let lines = transcripts[id] { return lines }
        let url = support.appendingPathComponent("transcripts/\(id.uuidString).json")
        let lines = (try? JSONDecoder.iso.decode([ChatLine].self, from: Data(contentsOf: url))) ?? []
        transcripts[id] = lines
        return lines
    }

    @discardableResult
    func create(kind: SessionKind) -> SessionRecord {
        let n = sessions.filter { $0.kind == kind }.count + 1
        let record = SessionRecord(id: UUID(), title: "\(kind.label) \(n)", kind: kind,
                                   model: ModelChoice.all[0].id, effort: "high", created: .now)
        sessions.append(record)
        selected[kind] = record.id
        save()
        return record
    }

    func update(_ id: UUID, _ change: (inout SessionRecord) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        save()
    }

    /// Forgets the session in Pixel Live. Claude's own transcript stays in ~/.claude.
    func remove(_ id: UUID) {
        stop(id)
        sessions.removeAll { $0.id == id }
        transcripts[id] = nil
        for (kind, value) in selected where value == id { selected[kind] = nil }
        try? FileManager.default.removeItem(at: support.appendingPathComponent("transcripts/\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("mcp/\(id.uuidString).json"))
        save()
    }

    // MARK: - Running claude -p

    func send(_ prompt: String, to id: UUID) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running.contains(id), let record = session(id) else { return }
        append(ChatLine(role: .user, text: text), to: id)
        if record.turns == 0, record.title.hasPrefix(record.kind.label) {
            update(id) { $0.title = String(text.prefix(42)) }
        }
        do {
            try launch(record: record, prompt: text)
        } catch {
            append(ChatLine(role: .error, text: error.localizedDescription), to: id)
        }
    }

    func stop(_ id: UUID) {
        processes[id]?.terminate()
    }

    private func launch(record: SessionRecord, prompt: String) throws {
        guard let claude = Self.claudeExecutable() else { throw RunError("No encontré el ejecutable de claude.") }
        let mcp = try writeMCPConfig(for: record)
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--model", record.model, "--effort", record.effort,
                    "--strict-mcp-config", "--mcp-config", mcp.path,
                    "--tools", "", "--allowedTools", "mcp__aseprite",
                    "--append-system-prompt", systemPrompt(for: record.kind)]
        args += record.started ? ["--resume", record.id.uuidString.lowercased()]
                               : ["--session-id", record.id.uuidString.lowercased()]

        let process = Process()
        process.executableURL = claude
        process.arguments = args
        process.currentDirectoryURL = workspace
        var env = ProcessInfo.processInfo.environment
        env["CLAUDECODE"] = nil
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let id = record.id
        let parser = StreamParser()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let events = parser.feed(data)
            if !events.isEmpty { Task { @MainActor in self?.handle(events, for: id) } }
        }
        let errors = ErrorBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in errors.append(handle.availableData) }
        process.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let rest = parser.feed(stdout.fileHandleForReading.readDataToEndOfFile()) + parser.flush()
            let status = proc.terminationStatus, reason = proc.terminationReason
            let message = errors.text
            Task { @MainActor in
                self?.handle(rest, for: id)
                self?.finished(id, status: status, interrupted: reason == .uncaughtSignal, stderr: message)
            }
        }
        try process.run()
        processes[id] = process
        running.insert(id)
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()
    }

    private func finished(_ id: UUID, status: Int32, interrupted: Bool, stderr: String) {
        processes[id] = nil
        running.remove(id)
        if let partial = streaming.removeValue(forKey: id), !partial.isEmpty {
            append(ChatLine(role: .assistant, text: partial), to: id)
        }
        if interrupted {
            append(ChatLine(role: .info, text: "Detenido."), to: id)
        } else if status != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            append(ChatLine(role: .error, text: detail.isEmpty ? "claude terminó con código \(status)." : String(detail.suffix(600))), to: id)
        }
        persistTranscript(id)
    }

    private func handle(_ events: [[String: Any]], for id: UUID) {
        for event in events {
            switch event["type"] as? String {
            case "system":
                if event["subtype"] as? String == "init" { update(id) { $0.started = true } }
            case "stream_event":
                guard let e = event["event"] as? [String: Any], e["type"] as? String == "content_block_delta",
                      let delta = e["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { continue }
                streaming[id, default: ""] += text
            case "assistant":
                guard let message = event["message"] as? [String: Any] else { continue }
                if let usage = message["usage"] as? [String: Any] { recordRequest(usage, for: id) }
                for block in message["content"] as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        streaming[id] = nil
                        if !text.isEmpty { append(ChatLine(role: .assistant, text: text), to: id) }
                    case "tool_use":
                        streaming[id] = nil
                        let name = (block["name"] as? String ?? "").replacingOccurrences(of: "mcp__aseprite__", with: "")
                        append(ChatLine(role: .tool, text: name), to: id)
                    default: break
                    }
                }
            case "user":
                guard let message = event["message"] as? [String: Any] else { continue }
                for block in message["content"] as? [[String: Any]] ?? [] where block["is_error"] as? Bool == true {
                    let text: String
                    if let s = block["content"] as? String { text = s }
                    else { text = (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? "" }
                    append(ChatLine(role: .error, text: String(text.prefix(300))), to: id)
                }
            case "rate_limit_event":
                guard let info = event["rate_limit_info"] as? [String: Any],
                      let windows = info["unifiedWindows"] as? [String: Any] else { continue }
                usage = windows.compactMap { key, value in
                    guard let w = value as? [String: Any], let u = w["utilization"] as? Double else { return nil }
                    return UsageWindow(name: key, utilization: u,
                                       resetsAt: (w["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
                }.sorted { $0.name < $1.name }
            case "result":
                let cost = event["total_cost_usd"] as? Double ?? 0
                let window = (event["modelUsage"] as? [String: Any])?.values
                    .compactMap { ($0 as? [String: Any])?["contextWindow"] as? Int }.max()
                update(id) {
                    $0.turns += 1
                    $0.lastTurnEnd = .now
                    $0.lastCostUSD = cost
                    $0.totalCostUSD += cost
                    if let window, window > 0 { $0.contextWindow = window }
                }
                if event["is_error"] as? Bool == true, let text = event["result"] as? String {
                    append(ChatLine(role: .error, text: text), to: id)
                }
            default: break
            }
        }
    }

    /// The last request's prompt size is the size of the conversation Claude carries.
    private func recordRequest(_ usage: [String: Any], for id: UUID) {
        let input = usage["input_tokens"] as? Int ?? 0
        let write = usage["cache_creation_input_tokens"] as? Int ?? 0
        let read = usage["cache_read_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        guard input + write + read > 0 else { return }
        update(id) {
            $0.lastInput = input; $0.lastCacheWrite = write; $0.lastCacheRead = read; $0.lastOutput = output
            $0.contextTokens = input + write + read
            $0.lastTurnEnd = .now
        }
    }

    private func append(_ line: ChatLine, to id: UUID) {
        var lines = transcript(id)
        if line.role == .tool, let last = lines.last, last.role == .tool {
            // Collapse runs of tool calls into one line: "tool ×3".
            lines[lines.count - 1].text = Self.mergeTools(last.text, line.text)
        } else {
            lines.append(line)
        }
        transcripts[id] = lines
        if line.role == .user || line.role == .error { persistTranscript(id) }
    }

    static func mergeTools(_ existing: String, _ name: String) -> String {
        var parts = existing.components(separatedBy: " · ")
        if let last = parts.last {
            let base = last.components(separatedBy: " ×").first ?? last
            if base == name {
                let count = (Int(last.components(separatedBy: " ×").dropFirst().first ?? "1") ?? 1) + 1
                parts[parts.count - 1] = "\(name) ×\(count)"
                return parts.joined(separator: " · ")
            }
        }
        return (parts + [name]).joined(separator: " · ")
    }

    private func persistTranscript(_ id: UUID) {
        guard let lines = transcripts[id], let data = try? JSONEncoder.iso.encode(lines) else { return }
        try? data.write(to: support.appendingPathComponent("transcripts/\(id.uuidString).json"), options: .atomic)
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(sessions) else { return }
        try? data.write(to: support.appendingPathComponent("sessions.json"), options: .atomic)
    }

    /// The user's aseprite MCP entry from ~/.claude.json, tagged with this session.
    private func writeMCPConfig(for record: SessionRecord) throws -> URL {
        let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        guard let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any],
              var server = (root["mcpServers"] as? [String: Any])?["aseprite"] as? [String: Any] else {
            throw RunError("No encontré el MCP «aseprite» en ~/.claude.json.")
        }
        var env = server["env"] as? [String: String] ?? [:]
        env["ASEPRITE_MCP_LIVE"] = "1"
        // Events must land in <workspace>/.live, the folder this window reads.
        env["ASEPRITE_MCP_ROOTS"] = workspace.path
        env["PIXEL_LIVE_SESSION"] = record.id.uuidString.lowercased()
        env["PIXEL_LIVE_KIND"] = record.kind.rawValue
        server["env"] = env
        let url = support.appendingPathComponent("mcp/\(record.id.uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["aseprite": server]], options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
        return url
    }

    private func systemPrompt(for kind: SessionKind) -> String {
        let root = workspace.path
        switch kind {
        case .sprites:
            return """
            Estás dentro de Pixel Live, en una sesión de SPRITES. Solo tienes las herramientas del MCP de Aseprite; \
            trabaja en archivos .aseprite dentro de \(root). El usuario ve cada llamada en vivo, así que avanza en pasos \
            claros (un cambio con sentido por llamada). No hagas animaciones aquí: eso va en sesiones de animación. \
            Responde breve y en español.
            """
        case .animacion:
            return """
            Estás dentro de Pixel Live, en una sesión de ANIMACIÓN. Solo tienes las herramientas del MCP de Aseprite. \
            Crea un archivo propio en \(root)/anim/ (por ejemplo copiando o redibujando un sprite) y construye ahí los \
            frames con sus duraciones. Nunca modifiques los sprites de otras sesiones ni nada en \(root)/animaciones/ \
            (son artefactos publicados e inmutables). Responde breve y en español.
            """
        }
    }

    static func claudeExecutable() -> URL? {
        let home = NSHomeDirectory()
        for path in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

struct RunError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Splits stdout into JSON lines. Used from the pipe's background queue.
final class StreamParser: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var out: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { out.append(obj) }
        }
        return out
    }

    func flush() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        defer { buffer.removeAll() }
        guard let obj = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else { return [] }
        return [obj]
    }
}

final class ErrorBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); if data.count > 16_384 { data = data.suffix(8192) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension Int {
    /// 1234 → "1,2k", 1_234_567 → "1,23M".
    var tokens: String {
        switch self {
        case ..<1000: return "\(self)"
        case ..<1_000_000: return String(format: "%.1fk", Double(self) / 1000)
        default: return String(format: "%.2fM", Double(self) / 1_000_000)
        }
    }
}
