import Foundation
import CoreGraphics
import ImageIO

/// One frame of a sprite as straight RGBA8 pixels (premultiplied, row-major).
struct PixelFrame {
    let width: Int
    let height: Int
    var pixels: [UInt32]
    let durationMs: Int
}

/// One MCP tool call that changed a sprite, with every frame rendered after it.
struct Step: Identifiable {
    let id: Int            // seq from events.jsonl
    let tool: String
    let caption: String
    let sprite: String
    let focusFrame: Int?   // 0-based frame the tool targeted, if any
    let timestamp: Double
    let frames: [PixelFrame]

    var spriteName: String { (sprite as NSString).lastPathComponent }
}

/// Tails <live dir>/events.jsonl and decodes each announced sprite sheet.
/// Read-only: it opens PNG and JSON files the MCP wrote, nothing else.
final class LiveFeed {
    private let directory: URL
    private let queue = DispatchQueue(label: "pixel-live.feed", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var offset: UInt64 = 0
    private var partial = Data()
    private let onSteps: @Sendable ([Step], Bool) -> Void
    private var primed = false

    /// History older than this many events is skipped on startup.
    private let startupBacklog = 300

    init(directory: URL, onSteps: @escaping @Sendable ([Step], Bool) -> Void) {
        self.directory = directory
        self.onSteps = onSteps
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(25), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        let events = directory.appendingPathComponent("events.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: events) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial.removeAll() }  // file was reset
        guard size > offset else {
            if !primed { primed = true; onSteps([], true) }
            return
        }
        try? handle.seek(toOffset: offset)
        let chunk = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(chunk.count)
        partial.append(chunk)

        var lines: [Data] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            lines.append(partial[partial.startIndex..<newline])
            partial.removeSubrange(partial.startIndex...newline)
        }
        let isBacklog = !primed
        if isBacklog { lines = Array(lines.suffix(startupBacklog)) }
        let steps = lines.compactMap(decodeStep)
        primed = true
        onSteps(steps, isBacklog)
    }

    private func decodeStep(_ line: Data) -> Step? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let seq = obj["seq"] as? Int,
              let sheetPath = obj["sheet"] as? String,
              let dataPath = obj["data"] as? String else { return nil }
        let sheetURL = directory.appendingPathComponent(sheetPath)
        let dataURL = directory.appendingPathComponent(dataPath)
        guard sheetURL.path.hasPrefix(directory.path), dataURL.path.hasPrefix(directory.path),
              let sheet = Self.decodePNG(sheetURL),
              let meta = try? JSONSerialization.jsonObject(with: Data(contentsOf: dataURL)) as? [String: Any],
              let rects = meta["frames"] as? [[String: Any]] else { return nil }

        var frames: [PixelFrame] = []
        for entry in rects {
            guard let r = entry["frame"] as? [String: Int],
                  let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"],
                  x >= 0, y >= 0, x + w <= sheet.width, y + h <= sheet.height else { continue }
            var px = [UInt32](repeating: 0, count: w * h)
            for row in 0..<h {
                let src = (y + row) * sheet.width + x
                px.replaceSubrange(row * w..<(row + 1) * w, with: sheet.pixels[src..<src + w])
            }
            frames.append(PixelFrame(width: w, height: h, pixels: px,
                                     durationMs: entry["duration"] as? Int ?? 100))
        }
        guard !frames.isEmpty else { return nil }
        let focus = (obj["frame"] as? Int).map { max(0, $0 - 1) }
        return Step(id: seq,
                    tool: obj["tool"] as? String ?? "",
                    caption: obj["caption"] as? String ?? "",
                    sprite: obj["sprite"] as? String ?? "",
                    focusFrame: focus,
                    timestamp: obj["ts"] as? Double ?? 0,
                    frames: frames)
    }

    static func decodePNG(_ url: URL) -> PixelFrame? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= 4096 * 4096 else { return nil }
        var pixels = [UInt32](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? PixelFrame(width: w, height: h, pixels: pixels, durationMs: 0) : nil
    }
}
