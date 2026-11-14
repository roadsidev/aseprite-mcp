import Foundation
import CoreGraphics
import QuartzCore

/// Advanced by DisplayDriver before FrameClock invalidates the canvas.
/// Source, destination and unchanged textures stay fixed during a reveal: only
/// the narrow, moving frontier needs individual pixel drawing at each vsync.
final class Engine {
    struct Change {
        let index: Int
        let before: UInt32
        let after: UInt32
        let time: CFTimeInterval
    }

    struct Components {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        init(_ value: UInt32) {
            alpha = CGFloat((value >> 24) & 255) / 255
            let divisor = max(alpha, 1 / 255) * 255
            red = min(1, CGFloat(value & 255) / divisor)
            green = min(1, CGFloat((value >> 8) & 255) / divisor)
            blue = min(1, CGFloat((value >> 16) & 255) / divisor)
        }
    }

    private(set) var width = 0
    private(set) var height = 0
    private(set) var buffer: [UInt32] = []
    private(set) var image: CGImage?
    private(set) var sourceImage: CGImage?
    private(set) var unchangedImage: CGImage?
    private(set) var changes: [Change] = []
    private(set) var started = 0
    private(set) var settled = 0
    private(set) var colors: [UInt32: Components] = [:]

    // A separate, short dissolve handles navigation and changes of canvas size.
    private(set) var previousImage: CGImage?
    private(set) var previousWidth = 0
    private(set) var previousHeight = 0
    private var transitionStart: CFTimeInterval = 0
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private(set) var pixelLife: CFTimeInterval = 0.24
    private(set) var renderTime: CFTimeInterval = 0
    var reduceMotion = false

    var isRevealing: Bool { !changes.isEmpty }
    var isAnimating: Bool { isRevealing || previousImage != nil }
    var settledBoundary: Int? { settled > 0 ? changes[settled - 1].index : nil }

    func transitionProgress(now: CFTimeInterval) -> Double {
        guard previousImage != nil else { return 1 }
        return Self.smooth((now - transitionStart) / (reduceMotion ? 0.12 : 0.28))
    }

    func revealProgress(now: CFTimeInterval) -> Double {
        guard isRevealing else { return 1 }
        return min(1, max(0, (now - start) / (duration + pixelLife)))
    }

    /// Forget everything on screen (e.g. a session filter with no steps yet).
    func clear() {
        finish()
        width = 0
        height = 0
        buffer = []
        image = nil
        previousImage = nil
        displayScale = 0
    }

    // MARK: - Animated display scale

    /// Points per sprite pixel actually drawn. It follows the layout target
    /// with a critically damped approach, so resizing the window or switching
    /// sprites glides instead of jumping between whole-number scales.
    private(set) var displayScale: CGFloat = 0
    private var scaleClock: CFTimeInterval = 0

    func approachScale(_ target: CGFloat, now: CFTimeInterval, immediate: Bool = false) -> CGFloat {
        defer { scaleClock = now }
        guard displayScale > 0, !immediate, !reduceMotion else { displayScale = target; return target }
        let dt = min(0.1, max(0, now - scaleClock))
        displayScale += (target - displayScale) * CGFloat(1 - exp(-dt * 16))
        if abs(displayScale - target) < 0.004 { displayScale = target }
        return displayScale
    }

    var isScaling: Bool { displayScale > 0 && scaleTarget != displayScale }
    var scaleTarget: CGFloat = 0

    /// Reuse a decoded texture when looping animation frames. Playback itself
    /// intentionally has no dissolve: frame durations and pixel edges stay exact.
    func show(_ frame: PixelFrame, image cached: CGImage? = nil,
              transition: Bool = false, now: CFTimeInterval = CACurrentMediaTime()) {
        let old = image
        let oldWidth = width, oldHeight = height
        finish()
        if transition, let old {
            previousImage = old
            previousWidth = oldWidth
            previousHeight = oldHeight
            transitionStart = now
        }
        width = frame.width
        height = frame.height
        buffer = frame.pixels
        image = cached ?? Self.makeImage(buffer, width: width, height: height)
    }

    /// Each pixel receives an absolute launch time, independent of refresh rate.
    /// The cosine distribution eases the brush in and out without integer steps.
    @discardableResult
    func animate(to frame: PixelFrame, backlog: Int, now: CFTimeInterval) -> Bool {
        guard frame.width == width, frame.height == height, !buffer.isEmpty else { return false }
        finish()
        var diff: [Int] = []
        // Walk in brush order directly: O(pixel count), with no large sort on
        // the main thread when the MCP replaces an entire sprite.
        for bandY in stride(from: 0, to: height, by: 4) {
            let rows = min(4, height - bandY)
            for column in 0..<width {
                let x = (bandY / 4).isMultiple(of: 2) ? column : width - column - 1
                for row in 0..<rows {
                    let index = (bandY + row) * width + x
                    if buffer[index] != frame.pixels[index] { diff.append(index) }
                }
            }
        }
        guard !diff.isEmpty else { return true }
        if reduceMotion {
            show(frame, transition: true, now: now)
            return true
        }
        let base = min(1.6, max(0.20, 0.16 + Double(diff.count) * 0.0025))
        // Retain an actual entrance even when catching up to a busy MCP feed.
        pixelLife = backlog > 6 ? 0.16 : diff.count > 16_384 ? 0.18 : 0.24
        let requested = backlog > 6 ? 0.18 : backlog > 2 ? base * 0.55 : base
        // The cosine sweep's peak rate is π/2 times its average. Bound the
        // active frontier even during a backlog, without dropping any pixels.
        let densityFloor = Double(diff.count) * pixelLife * .pi / 16_000
        duration = diff.count == 1 ? 0 : max(requested, densityFloor)
        start = now
        sourceImage = image
        var unchanged = buffer
        colors.removeAll(keepingCapacity: true)
        changes = diff.enumerated().map { rank, index in
            let position = diff.count == 1 ? 0 : Double(rank) / Double(diff.count - 1)
            let delay = acos(1 - 2 * position) / .pi * duration
            for color in [buffer[index], frame.pixels[index]] where colors[color] == nil {
                colors[color] = Components(color)
            }
            unchanged[index] = 0
            return Change(index: index, before: buffer[index], after: frame.pixels[index], time: now + delay)
        }
        buffer = frame.pixels
        unchangedImage = Self.makeImage(unchanged, width: width, height: height)
        image = Self.makeImage(buffer, width: width, height: height)
        return true
    }

    func finish() {
        changes.removeAll(keepingCapacity: true)
        started = 0
        settled = 0
        sourceImage = nil
        unchangedImage = nil
        previousImage = nil
    }

    func tick(now: CFTimeInterval) {
        renderTime = now
        if previousImage != nil, transitionProgress(now: now) >= 1 { previousImage = nil }
        guard isRevealing else { return }
        while started < changes.count, now >= changes[started].time { started += 1 }
        while settled < started, now >= changes[settled].time + pixelLife { settled += 1 }
        if settled == changes.count { finish() }
    }

    func currentImage() -> CGImage? { image }

    static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    /// Critically damped spring, normalized so the final handoff is exact.
    static func entrance(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return (1 - (1 + 9 * t) * exp(-9 * t)) / (1 - 10 * exp(-9))
    }

    static func color(_ value: UInt32) -> CGColor {
        let alpha = CGFloat((value >> 24) & 255) / 255
        guard alpha > 0 else { return CGColor(gray: 0, alpha: 0) }
        return CGColor(srgbRed: min(1, CGFloat(value & 255) / 255 / alpha),
                       green: min(1, CGFloat((value >> 8) & 255) / 255 / alpha),
                       blue: min(1, CGFloat((value >> 16) & 255) / 255 / alpha), alpha: alpha)
    }

    static func makeImage(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
