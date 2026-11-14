import Foundation
import CoreGraphics
import QuartzCore

/// Frame-paced playback state. Owned by the model and advanced from the
/// Canvas render closure, so it is a plain class (not observed): mutating it
/// every frame must not invalidate SwiftUI views.
final class Engine {
    struct Pop { let x: Int; let y: Int; let color: UInt32; let t: CFTimeInterval }

    private(set) var width = 0
    private(set) var height = 0
    private(set) var buffer: [UInt32] = []
    private(set) var pops: [Pop] = []
    private(set) var image: CGImage?
    private var dirty = true

    // Current reveal
    private var changes: [(index: Int, color: UInt32)] = []
    private var revealed = 0
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    var isAnimating: Bool { revealed < changes.count }

    static let popLife: CFTimeInterval = 0.28

    /// Show pixels immediately (no animation).
    func show(_ frame: PixelFrame) {
        width = frame.width
        height = frame.height
        buffer = frame.pixels
        changes = []
        revealed = 0
        pops = []
        dirty = true
    }

    /// Animate from what is on screen to `frame`. Returns false when the
    /// sizes differ (caller should `show` instead).
    @discardableResult
    func animate(to frame: PixelFrame, backlog: Int, now: CFTimeInterval) -> Bool {
        guard frame.width == width, frame.height == height, !buffer.isEmpty else { return false }
        finish()
        var diff: [(Int, UInt32)] = []
        diff.reserveCapacity(256)
        for i in 0..<buffer.count where buffer[i] != frame.pixels[i] {
            diff.append((i, frame.pixels[i]))
        }
        changes = Engine.order(diff, width: width)
        revealed = 0
        start = now
        // Small edits read as quick strokes, big ones as a sweep; a backlog speeds everything up.
        let base = min(1.6, max(0.22, 0.18 + Double(changes.count) * 0.0035))
        duration = backlog > 6 ? 0.06 : backlog > 2 ? base * 0.45 : base
        return true
    }

    /// Reveal order: strokes of nearby pixels, scanning top to bottom, so
    /// the image appears the way someone would draw it.
    private static func order(_ diff: [(Int, UInt32)], width: Int) -> [(index: Int, color: UInt32)] {
        // Group into 4-row bands, left to right inside a band, alternating
        // direction per band (boustrophedon) so the "brush" never jumps back.
        let band = 4
        return diff.sorted { a, b in
            let ya = a.0 / width, yb = b.0 / width
            let ba = ya / band, bb = yb / band
            if ba != bb { return ba < bb }
            let xa = a.0 % width, xb = b.0 % width
            let flip = ba % 2 == 1
            if xa != xb { return flip ? xa > xb : xa < xb }
            return ya < yb
        }.map { (index: $0.0, color: $0.1) }
    }

    /// Jump to the end of the current reveal.
    func finish() {
        while revealed < changes.count {
            let c = changes[revealed]
            buffer[c.index] = c.color
            revealed += 1
        }
        dirty = true
    }

    /// Advance to `now`; call once per display frame.
    func tick(now: CFTimeInterval) {
        if revealed < changes.count {
            let t = duration <= 0 ? 1 : min(1, (now - start) / duration)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let target = t >= 1 ? changes.count : Int(Double(changes.count) * eased)
            while revealed < target {
                let c = changes[revealed]
                buffer[c.index] = c.color
                pops.append(Pop(x: c.index % width, y: c.index / width, color: c.color, t: now))
                revealed += 1
            }
            dirty = true
        }
        if !pops.isEmpty {
            pops.removeAll { now - $0.t > Engine.popLife }
            // Keep the overlay cheap on huge sweeps.
            if pops.count > 900 { pops.removeFirst(pops.count - 900) }
        }
    }

    /// Current buffer as an image (rebuilt only when pixels changed).
    func currentImage() -> CGImage? {
        guard dirty || image == nil, width > 0 else { return image }
        dirty = false
        image = Engine.makeImage(buffer, width: width, height: height)
        return image
    }

    static func makeImage(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
