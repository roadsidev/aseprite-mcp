import Foundation
import Observation
import QuartzCore
import CoreGraphics

@MainActor
@Observable
final class LiveModel {
    // Observed UI state
    private(set) var steps: [Step] = []
    private(set) var shownIndex: Int? = nil     // step on screen (or being revealed)
    private(set) var shownFrame = 0             // 0-based frame of that step
    var following = true                        // auto-advance to new steps
    var playingFrames = false                   // loop the animation of the shown step
    var showGrid = false
    private(set) var connected = false
    private(set) var arrival = 0
    private(set) var replaying = false

    // Render state (not observed)
    @ObservationIgnored let engine = Engine()
    @ObservationIgnored private var pending: [Int] = []   // step indices waiting to be revealed
    @ObservationIgnored private var frameClock: CFTimeInterval = 0
    @ObservationIgnored private var feed: LiveFeed?
    @ObservationIgnored private var frameImages: [Int: CGImage] = [:]

    let directory: URL
    /// Which steps this model shows: design work and animation work never mix.
    let accepts: @Sendable (Step) -> Bool
    /// Animation work loops its frames whenever nothing is being revealed.
    let autoPlay: Bool
    /// Only show steps from this Claude session (nil = all accepted steps).
    var sessionFilter: String? = nil {
        didSet { if sessionFilter != oldValue { rebuild() } }
    }
    @ObservationIgnored private var all: [Step] = []

    init(directory: URL, accepts: @escaping @Sendable (Step) -> Bool = { _ in true }, autoPlay: Bool = false) {
        self.directory = directory
        self.accepts = accepts
        self.autoPlay = autoPlay
        self.playingFrames = autoPlay
    }

    private func visible(_ step: Step) -> Bool {
        accepts(step) && (sessionFilter == nil || step.session == sessionFilter)
    }

    private func rebuild() {
        pending.removeAll()
        replaying = false
        engine.finish()
        steps = all.filter(visible)
        shownIndex = nil
        frameImages.removeAll(keepingCapacity: true)
        if !steps.isEmpty { display(index: steps.count - 1, animated: false) }
        else { engine.clear() }
    }

    func start() {
        guard feed == nil else { return }
        let feed = LiveFeed(directory: directory) { [weak self] steps, backlog in
            Task { @MainActor in self?.receive(steps, backlog: backlog) }
        }
        self.feed = feed
        feed.start()
    }

    var currentStep: Step? { shownIndex.map { steps[$0] } }

    private func receive(_ incoming: [Step], backlog: Bool) {
        connected = true
        all.append(contentsOf: incoming)
        let new = incoming.filter(visible)
        guard !new.isEmpty else { return }
        arrival &+= 1
        let first = steps.count
        steps.append(contentsOf: new)
        if backlog {
            // History: show the last state, do not replay it.
            display(index: steps.count - 1, animated: false)
            return
        }
        if following {
            pending.append(contentsOf: first..<steps.count)
        }
    }

    /// Called every display refresh by DisplayDriver, before invalidating Canvas.
    func tick(now: CFTimeInterval) {
        if !engine.isAnimating, !pending.isEmpty {
            let next = pending.removeFirst()
            display(index: next, animated: true, now: now)
        }
        if engine.isAnimating == false, pending.isEmpty, replaying { replaying = false }
        let wasAnimating = engine.isAnimating
        engine.tick(now: now)
        if wasAnimating { frameClock = now }
        if playingFrames, let step = currentStep, step.frames.count > 1, !engine.isAnimating {
            var elapsed = max(0, now - frameClock)
            let duration = Double(max(16, step.frames[shownFrame].durationMs)) / 1000
            if elapsed >= duration {
                // Skip complete loops after a stall, then preserve the fractional
                // remainder. Resetting the clock to `now` causes cumulative drift.
                let cycle = step.frames.reduce(0.0) { $0 + Double(max(16, $1.durationMs)) / 1000 }
                let loops = floor(elapsed / cycle)
                frameClock += loops * cycle
                elapsed -= loops * cycle
                var next = shownFrame
                while elapsed >= Double(max(16, step.frames[next].durationMs)) / 1000 {
                    let interval = Double(max(16, step.frames[next].durationMs)) / 1000
                    elapsed -= interval
                    frameClock += interval
                    next = (next + 1) % step.frames.count
                }
                if next != shownFrame {
                    shownFrame = next
                    engine.show(step.frames[next], image: frameImages[next])
                    cacheFrameImage()
                }
            }
        }
    }

    private func display(index: Int, animated: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        let step = steps[index]
        let previousIndex = shownIndex
        let previous = shownIndex.map { steps[$0] }
        var frame = step.focusFrame ?? shownFrame
        frame = min(max(0, frame), step.frames.count - 1)

        // If the targeted frame did not change but another did, look at that one.
        if let prev = previous, prev.sprite == step.sprite, prev.frames.count == step.frames.count,
           frame < prev.frames.count, prev.frames[frame].pixels == step.frames[frame].pixels,
           let changed = step.frames.indices.first(where: { prev.frames[$0].pixels != step.frames[$0].pixels }) {
            frame = changed
        }

        shownIndex = index
        shownFrame = frame
        frameClock = now
        if previousIndex != index { frameImages.removeAll(keepingCapacity: true) }
        let target = step.frames[frame]
        let sameSprite = previous?.sprite == step.sprite
        if animated, sameSprite, engine.animate(to: target, backlog: pending.count, now: now) {
            cacheFrameImage()
            return
        }
        engine.show(target, image: frameImages[frame], transition: previous != nil, now: now)
        cacheFrameImage()
    }

    private func cacheFrameImage() {
        // Bound memory for unusually long animations; normal loops reuse textures.
        if frameImages.count >= 24 { frameImages.removeAll(keepingCapacity: true) }
        frameImages[shownFrame] = engine.currentImage()
    }

    // MARK: - User actions

    func scrub(to index: Int) {
        guard steps.indices.contains(index) else { return }
        following = false
        pending.removeAll()
        replaying = false
        engine.finish()
        display(index: index, animated: false)
    }

    func stepBy(_ delta: Int) {
        guard let current = shownIndex else { return }
        let target = current + delta
        guard steps.indices.contains(target) else { return }
        following = false
        pending.removeAll()
        replaying = false
        engine.finish()
        // Stepping forward replays that step's reveal; backward jumps.
        display(index: target, animated: delta == 1)
    }

    func goLive() {
        following = true
        pending.removeAll()
        replaying = false
        engine.finish()
        if !steps.isEmpty { display(index: steps.count - 1, animated: false) }
    }

    func toggleLive() {
        if following {
            following = false
            pending.removeAll()
            replaying = false
        } else {
            goLive()
        }
    }

    /// Replay the whole session from the first step of the shown sprite.
    func replayAll() {
        guard let sprite = currentStep?.sprite,
              let first = steps.firstIndex(where: { $0.sprite == sprite }) else { return }
        following = true
        replaying = true
        playingFrames = false
        frameImages.removeAll(keepingCapacity: true)
        engine.finish()
        let blank = steps[first].frames[0]
        engine.show(PixelFrame(width: blank.width, height: blank.height,
                               pixels: [UInt32](repeating: 0, count: blank.pixels.count), durationMs: 0))
        shownIndex = first
        shownFrame = 0
        pending = Array(first..<steps.count).filter { steps[$0].sprite == sprite }
    }

    func togglePlay() {
        guard let step = currentStep, step.frames.count > 1 else { return }
        playingFrames.toggle()
        frameClock = CACurrentMediaTime()
        if !playingFrames, let step = currentStep {
            shownFrame = min(shownFrame, step.frames.count - 1)
        }
    }
}
