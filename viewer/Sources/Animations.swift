import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Observation
import QuartzCore

/// meta.json of a published animation. Written once; never rewritten.
struct AnimationMeta: Codable, Hashable {
    struct FileEntry: Codable, Hashable {
        let file: String
        let sha256: String
        var durationMs: Int?
    }
    struct Source: Codable, Hashable {
        let session: String?
        let sessionTitle: String?
        let kind: String?
        let sprite: String
        let seq: Int
        let tool: String
        let caption: String
        let editedAt: Date
    }
    let name: String
    let slug: String
    let created: Date
    let width: Int
    let height: Int
    let frames: [FileEntry]
    let sheet: FileEntry
    let files: Int          // frames + sheet + meta.json
    let source: Source
    var totalMs: Int { frames.reduce(0) { $0 + ($1.durationMs ?? 100) } }
    /// "v2", "v3"… when the same name was published again.
    var version: String? {
        let base = AnimationLibrary.slug(name)
        guard slug.hasPrefix(base + "-v") else { return nil }
        return String(slug.dropFirst(base.count + 1))
    }
}

/// A published, read-only animation loaded from <workspace>/animaciones/<slug>/.
struct AnimationArtifact: Identifiable {
    let meta: AnimationMeta
    let directory: URL
    let images: [CGImage]
    let intact: Bool        // every file still matches its sha256
    var id: String { meta.slug }
}

@MainActor
@Observable
final class AnimationLibrary {
    private(set) var items: [AnimationMeta] = []
    let root: URL

    init(workspace: URL) {
        root = workspace.appendingPathComponent("animaciones", isDirectory: true)
    }

    func refresh() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        items = dirs.compactMap { dir in
            try? JSONDecoder.iso.decode(AnimationMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
        }.sorted { $0.created > $1.created }
    }

    func load(_ meta: AnimationMeta) -> AnimationArtifact? {
        let dir = root.appendingPathComponent(meta.slug, isDirectory: true)
        var intact = true
        var images: [CGImage] = []
        for entry in meta.frames + [meta.sheet] {
            let url = dir.appendingPathComponent(entry.file)
            guard url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL,
                  let data = try? Data(contentsOf: url) else { intact = false; continue }
            if Self.sha256(data) != entry.sha256 { intact = false }
            if entry.file != meta.sheet.file,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                images.append(image)
            }
        }
        guard !images.isEmpty else { return nil }
        return AnimationArtifact(meta: meta, directory: dir, images: images, intact: intact)
    }

    /// Copies the step's frames into a new folder and locks it (0444 files,
    /// 0555 folder). Republishing the same name creates <slug>-v2, -v3…
    func publish(name: String, step: Step, sessionTitle: String?) throws -> AnimationMeta {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw RunError("Ponle un nombre a la animación.") }
        guard let first = step.frames.first else { throw RunError("No hay frames que publicar.") }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = Self.slug(clean)
        var slug = base, version = 1
        while fm.fileExists(atPath: root.appendingPathComponent(slug).path) {
            version += 1
            slug = "\(base)-v\(version)"
        }
        let staging = root.appendingPathComponent(".\(slug).tmp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let digits = max(2, String(step.frames.count).count)
        var entries: [AnimationMeta.FileEntry] = []
        for (i, frame) in step.frames.enumerated() {
            let file = String(format: "frame-%0\(digits)d.png", i + 1)
            let data = try Self.png(Self.image(frame))
            try data.write(to: staging.appendingPathComponent(file))
            entries.append(.init(file: file, sha256: Self.sha256(data), durationMs: max(16, frame.durationMs)))
        }
        let sheetData = try Self.png(Self.sheet(step.frames))
        try sheetData.write(to: staging.appendingPathComponent("sheet.png"))

        let meta = AnimationMeta(
            name: clean, slug: slug, created: .now, width: first.width, height: first.height,
            frames: entries, sheet: .init(file: "sheet.png", sha256: Self.sha256(sheetData)),
            files: entries.count + 2,
            source: .init(session: step.session, sessionTitle: sessionTitle, kind: step.kind,
                          sprite: step.sprite, seq: step.id, tool: step.tool, caption: step.caption,
                          editedAt: Date(timeIntervalSince1970: step.timestamp)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(meta).write(to: staging.appendingPathComponent("meta.json"))

        for file in try fm.contentsOfDirectory(atPath: staging.path) {
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: staging.appendingPathComponent(file).path)
        }
        let final = root.appendingPathComponent(slug, isDirectory: true)
        try fm.moveItem(at: staging, to: final)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: final.path)
        refresh()
        return meta
    }

    nonisolated static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "es"))
        let mapped = folded.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let slug = String(mapped).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "animacion" : String(slug.prefix(48))
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func image(_ frame: PixelFrame) throws -> CGImage {
        var pixels = frame.pixels
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: frame.width, height: frame.height, bitsPerComponent: 8,
                      bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image else { throw RunError("No pude codificar un frame.") }
        return image
    }

    static func sheet(_ frames: [PixelFrame]) throws -> CGImage {
        let w = frames.reduce(0) { $0 + $1.width }, h = frames.map(\.height).max() ?? 0
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RunError("No pude armar el sheet.")
        }
        ctx.interpolationQuality = .none
        var x = 0
        for frame in frames {
            ctx.draw(try image(frame), in: CGRect(x: x, y: h - frame.height, width: frame.width, height: frame.height))
            x += frame.width
        }
        guard let image = ctx.makeImage() else { throw RunError("No pude armar el sheet.") }
        return image
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RunError("No pude escribir PNG.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RunError("No pude escribir PNG.") }
        return data as Data
    }
}

/// Loops a published animation on the display link's clock (no timers).
@MainActor
@Observable
final class AnimationPlayer {
    private(set) var artifact: AnimationArtifact?
    var playing = true
    @ObservationIgnored private(set) var frame = 0
    @ObservationIgnored private var frameStart: CFTimeInterval = 0
    @ObservationIgnored private(set) var displayScale: CGFloat = 0
    @ObservationIgnored private var scaleClock: CFTimeInterval = 0
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored var renderTime: CFTimeInterval = 0

    func open(_ artifact: AnimationArtifact?) {
        self.artifact = artifact
        frame = 0
        frameStart = CACurrentMediaTime()
        displayScale = 0
    }

    func tick(now: CFTimeInterval) {
        renderTime = now
        guard playing, let artifact, artifact.images.count > 1 else { frameStart = now; return }
        let frames = artifact.meta.frames
        var guardCount = 0
        while guardCount < 512 {
            let duration = Double(max(16, frames[min(frame, frames.count - 1)].durationMs ?? 100)) / 1000
            guard now - frameStart >= duration else { break }
            frameStart += duration
            frame = (frame + 1) % artifact.images.count
            guardCount += 1
        }
        if guardCount == 512 { frameStart = now }
    }

    func step(_ delta: Int) {
        guard let count = artifact?.images.count, count > 0 else { return }
        playing = false
        frame = (frame + delta + count) % count
    }

    func togglePlay() {
        playing.toggle()
        frameStart = CACurrentMediaTime()
    }

    func approachScale(_ target: CGFloat, now: CFTimeInterval) -> CGFloat {
        defer { scaleClock = now }
        guard displayScale > 0, !reduceMotion else { displayScale = target; return target }
        let dt = min(0.1, max(0, now - scaleClock))
        displayScale += (target - displayScale) * CGFloat(1 - exp(-dt * 16))
        if abs(displayScale - target) < 0.004 { displayScale = target }
        return displayScale
    }
}
