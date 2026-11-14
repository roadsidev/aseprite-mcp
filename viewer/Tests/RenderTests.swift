import Foundation
import CoreGraphics
import ImageIO
import SwiftUI
import QuartzCore

/// Headless checks. No NSApplication, windows, or display links are started.
@main
struct RenderTests {
    @MainActor
    static func main() async throws {
        testReveal()
        testClipping()
        testTransparentPixels()
        benchmarkFrontier()
        try await testPlayback()
        testActivityStream()
        print("PASS: reveal timing, sparse clipping, transparency, image reuse, playback cadence, live queue and activity stream")
    }

    static func frame(_ width: Int, _ height: Int, _ pixels: [UInt32], duration: Int = 100) -> PixelFrame {
        PixelFrame(width: width, height: height, pixels: pixels, durationMs: duration)
    }

    static func testReveal() {
        let engine = Engine()
        engine.show(frame(8, 7, Array(repeating: 0, count: 56)))
        let target = frame(8, 7, Array(repeating: 0xff3355cc, count: 56))
        precondition(engine.animate(to: target, backlog: 0, now: 100))
        let image = engine.currentImage()!
        let changes = engine.changes
        precondition(changes.count == 56)
        precondition(zip(changes, changes.dropFirst()).allSatisfy { $0.time < $1.time })
        // Different simulated display rates produce identical launch/settle state.
        for time in stride(from: 100.0, through: 100.25, by: 1 / 120.0) { engine.tick(now: time) }
        engine.tick(now: 100.25)
        let slower = Engine()
        slower.show(frame(8, 7, Array(repeating: 0, count: 56)))
        slower.animate(to: target, backlog: 0, now: 100)
        for time in stride(from: 100.0, through: 100.25, by: 1 / 60.0) { slower.tick(now: time) }
        slower.tick(now: 100.25)
        precondition(slower.started == engine.started && slower.settled == engine.settled)
        let count = engine.started
        precondition(count > 0 && engine.settled < engine.started)
        precondition(engine.currentImage() === image, "A vsync must not rebuild the sprite texture")
        let lastTime = changes.last!.time
        engine.tick(now: lastTime + engine.pixelLife / 2)
        precondition(engine.isAnimating, "Keep the last pixel's animation tail alive")
        engine.tick(now: lastTime + engine.pixelLife + 0.001)
        precondition(!engine.isAnimating && engine.buffer == target.pixels)
        precondition(engine.currentImage() === image)
        let smaller = frame(2, 3, Array(repeating: 0xffaa3311, count: 6))
        precondition(!engine.animate(to: smaller, backlog: 0, now: 102))
        engine.show(smaller, transition: true, now: 102)
        precondition(engine.previousWidth == 8 && engine.previousHeight == 7)
        precondition(engine.transitionProgress(now: 102.14) > 0.49)
        engine.tick(now: 103)
        precondition(!engine.isAnimating)
        precondition(Engine.entrance(0) == 0 && abs(Engine.entrance(1) - 1) < 1e-12)
        precondition(Engine.entrance(0.401) > Engine.entrance(0.400))
    }

    @MainActor
    static func testClipping() {
        for height in [1, 3, 4, 5, 7, 8, 9] {
            let width = 9
            let engine = Engine()
            engine.show(frame(width, height, Array(repeating: 0, count: width * height)))
            let pixels = (0..<width * height).map { $0.isMultiple(of: 3) ? UInt32(0) : 0xff3355cc }
            engine.animate(to: frame(width, height, pixels), backlog: 0, now: 100)
            let changes = engine.changes
            for (rank, change) in changes.enumerated() {
                let path = PixelCanvas.settledPath(through: change.index, engine: engine,
                    rect: CGRect(x: 0, y: 0, width: width, height: height), scale: 1)
                for (otherRank, other) in changes.enumerated() {
                    let center = CGPoint(x: Double(other.index % width) + 0.5, y: Double(other.index / width) + 0.5)
                    precondition(path.contains(center) == (otherRank <= rank), "Sparse brush clipping crossed its frontier")
                }
            }
        }
        let rect = PixelCanvas.spriteRect(width: 256, height: 256, size: CGSize(width: 200, height: 180))
        precondition(rect.width == 128 && rect.height == 128 && rect.minX >= 0 && rect.minY >= 0)
    }

    @MainActor
    static func testTransparentPixels() {
        let engine = Engine()
        engine.show(frame(1, 1, [0xff3355cc]))
        engine.animate(to: frame(1, 1, [0]), backlog: 0, now: 100)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var samples: [UInt8] = []
        for age in [0.0, 0.5, 0.99] {
            engine.tick(now: 100 + age * engine.pixelLife)
            context.setFillColor(PixelCanvas.checkerLight)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            PixelCanvas.drawFrontier(engine: engine, context: context,
                rect: CGRect(x: 0, y: 0, width: 8, height: 8), scale: 8, now: engine.renderTime)
            samples.append(context.data!.load(as: UInt8.self))
        }
        precondition(samples[0] > samples[1] && samples[1] > samples[2], "Erased pixels should fade into the checker")
        precondition(Engine.color(0).alpha == 0)
    }

    @MainActor
    static func benchmarkFrontier() {
        let pixels = (0..<256 * 256).map { UInt32(0xff000000) | UInt32(($0 % 32) * 0x070503) }
        for (label, source, backlog) in [("new", UInt32(0), 0), ("replace + backlog", UInt32(0xffd4c2a0), 8)] {
            let engine = Engine()
            engine.show(frame(256, 256, Array(repeating: source, count: pixels.count)))
            let start = CACurrentMediaTime()
            engine.animate(to: frame(256, 256, pixels), backlog: backlog, now: 100)
            let setup = (CACurrentMediaTime() - start) * 1000
            let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            var times: [Double] = []
            var peak = 0
            for tick in 0..<310 {
                let now = 100 + Double(tick) / 120
                let began = CACurrentMediaTime()
                engine.tick(now: now)
                peak = max(peak, engine.started - engine.settled)
                PixelCanvas.drawFrontier(engine: engine, context: context,
                    rect: CGRect(x: 0, y: 0, width: 512, height: 512), scale: 2, now: now)
                times.append((CACurrentMediaTime() - began) * 1000)
            }
            precondition(peak <= 8_000, "A backlog must not flood the renderer with active pixels")
            times.sort()
            print(String(format: "Headless 256×256 frontier at 2× (%@): setup=%.2fms p50=%.2fms p99=%.2fms peak=%d active pixels (not window frametime)",
                         label, setup, times[times.count / 2], times[Int(Double(times.count) * 0.99)], peak))
        }
    }

    /// Replays a multi-message turn. Summing tokens at message_stop once
    /// aborted the app with an exclusivity violation on the observed dictionary.
    @MainActor
    static func testActivityStream() {
        let support = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp/test-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = SessionStore(workspace: support, support: support)
        let id = UUID()
        store.beginActivity(id)
        func e(_ event: [String: Any]) -> [String: Any] { ["type": "stream_event", "event": event] }
        let turn: [[String: Any]] = [
            e(["type": "message_start"]),
            e(["type": "content_block_start", "content_block": ["type": "thinking"]]),
            e(["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "plan"]]),
            e(["type": "content_block_stop"]),
            e(["type": "content_block_start", "content_block": ["type": "tool_use", "name": "mcp__aseprite__draw_rows"]]),
            e(["type": "content_block_delta", "delta": ["type": "input_json_delta", "partial_json": "{\"rows\":"]]),
            e(["type": "content_block_stop"]),
            e(["type": "message_delta", "usage": ["output_tokens": 50]]),
            e(["type": "message_stop"]),
        ]
        store.handle(turn, for: id)
        precondition(store.activity[id]?.phase == "Ejecutando draw_rows en Aseprite…")
        precondition(store.activity[id]?.inputChars == 8)
        store.handle([
            e(["type": "message_start"]),
            e(["type": "content_block_start", "content_block": ["type": "text"]]),
            e(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "listo"]]),
            e(["type": "message_delta", "usage": ["output_tokens": 20]]),
            e(["type": "message_stop"]),
        ], for: id)
        precondition(store.activity[id]?.outputTokens == 70)
        precondition(store.activity[id]?.phase == "Escribiendo la respuesta…")
        precondition(store.streaming[id] == "listo")

        // total_cost_usd is cumulative across --resume turns.
        let record = store.create(kind: .animacion)
        store.handle([["type": "result", "total_cost_usd": 0.92]], for: record.id)
        store.handle([["type": "result", "total_cost_usd": 0.96]], for: record.id)
        let costs = store.session(record.id)!
        precondition(costs.turns == 2 && abs(costs.totalCostUSD - 0.96) < 1e-9 && abs(costs.lastCostUSD - 0.04) < 1e-9)
    }

    @MainActor
    static func testPlayback() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp/test-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sheet = Engine.makeImage([0xff0000ff, 0xff00ff00, 0xffff0000], width: 3, height: 1)!
        let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("sheet.png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, sheet, nil)
        precondition(CGImageDestinationFinalize(destination))
        let durations = [37, 83, 91]
        let frames = durations.enumerated().map { index, duration -> [String: Any] in
            ["frame": ["x": index, "y": 0, "w": 1, "h": 1], "duration": duration]
        }
        try JSONSerialization.data(withJSONObject: ["frames": frames]).write(to: directory.appendingPathComponent("meta.json"))
        func event(_ sequence: Int) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["seq": sequence, "sheet": "sheet.png", "data": "meta.json", "sprite": "test.aseprite"])
            data.append(10)
            return data
        }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        try event(1).write(to: eventsURL)
        let model = LiveModel(directory: directory)
        model.start()
        for _ in 0..<200 where model.steps.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        precondition(model.steps.count == 1, "Fixture feed did not arrive")
        model.togglePlay()
        let began = CACurrentMediaTime()
        for tick in 1...2400 {
            let elapsed = Double(tick) / 120
            model.tick(now: began + elapsed)
            let position = elapsed.truncatingRemainder(dividingBy: 0.211)
            // Ignore samples immediately on a boundary (togglePlay owns its epoch).
            if [0.0, 0.037, 0.120, 0.211].allSatisfy({ abs(position - $0) > 0.001 }) {
                let expected = position < 0.037 ? 0 : position < 0.120 ? 1 : 2
                precondition(model.shownFrame == expected, "Playback accumulated frame-clock drift")
            }
        }
        model.tick(now: began + 200.045) // resume after a long stall
        let position = 200.045.truncatingRemainder(dividingBy: 0.211)
        precondition(model.shownFrame == (position < 0.037 ? 0 : position < 0.120 ? 1 : 2))
        model.togglePlay()
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: event(2))
        try handle.close()
        for _ in 0..<200 where model.steps.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        precondition(model.steps.count == 2)
        model.toggleLive() // stop before the queued step is displayed
        model.tick(now: CACurrentMediaTime())
        precondition(model.shownIndex == 0, "Leaving LIVE must clear the queued steps")
        model.goLive()
        precondition(model.shownIndex == 1 && model.following)
        model.replayAll()
        precondition(model.shownIndex == 0 && model.shownFrame == 0 && model.replaying)
    }
}
