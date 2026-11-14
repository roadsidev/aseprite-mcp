import Foundation
import Observation
import QuartzCore

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

    // Render state (not observed)
    @ObservationIgnored let engine = Engine()
    @ObservationIgnored private var pending: [Int] = []   // step indices waiting to be revealed
    @ObservationIgnored private var frameClock: CFTimeInterval = 0
    @ObservationIgnored private var feed: LiveFeed?
    @ObservationIgnored private var replaying = false

    let directory: URL

    init(directory: URL) {
        self.directory = directory
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

    private func receive(_ new: [Step], backlog: Bool) {
        connected = true
        guard !new.isEmpty else { return }
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

    /// Called every display frame by the canvas.
    func tick(now: CFTimeInterval) {
        if !engine.isAnimating, !pending.isEmpty {
            let next = pending.removeFirst()
            display(index: next, animated: true, now: now)
        }
        if engine.isAnimating == false, pending.isEmpty, replaying { replaying = false }
        engine.tick(now: now)
        if playingFrames, let step = currentStep, step.frames.count > 1, !engine.isAnimating {
            let duration = Double(max(16, step.frames[shownFrame].durationMs)) / 1000
            if now - frameClock >= duration {
                frameClock = now
                shownFrame = (shownFrame + 1) % step.frames.count
                engine.show(step.frames[shownFrame])
            }
        }
    }

    private func display(index: Int, animated: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        let step = steps[index]
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
        let target = step.frames[frame]
        let sameSprite = previous?.sprite == step.sprite
        if animated, sameSprite, engine.animate(to: target, backlog: pending.count, now: now) {
            return
        }
        engine.show(target)
    }

    // MARK: - User actions

    func scrub(to index: Int) {
        guard steps.indices.contains(index) else { return }
        following = false
        pending.removeAll()
        engine.finish()
        display(index: index, animated: false)
    }

    func stepBy(_ delta: Int) {
        guard let current = shownIndex else { return }
        let target = current + delta
        guard steps.indices.contains(target) else { return }
        following = false
        pending.removeAll()
        engine.finish()
        // Stepping forward replays that step's reveal; backward jumps.
        display(index: target, animated: delta == 1)
    }

    func goLive() {
        following = true
        pending.removeAll()
        engine.finish()
        if !steps.isEmpty { display(index: steps.count - 1, animated: false) }
    }

    /// Replay the whole session from the first step of the shown sprite.
    func replayAll() {
        guard let sprite = currentStep?.sprite,
              let first = steps.firstIndex(where: { $0.sprite == sprite }) else { return }
        following = true
        replaying = true
        playingFrames = false
        engine.finish()
        let blank = steps[first].frames[0]
        engine.show(PixelFrame(width: blank.width, height: blank.height,
                               pixels: [UInt32](repeating: 0, count: blank.pixels.count), durationMs: 0))
        shownIndex = first
        pending = Array(first..<steps.count).filter { steps[$0].sprite == sprite }
    }

    func togglePlay() {
        playingFrames.toggle()
        frameClock = CACurrentMediaTime()
        if !playingFrames, let step = currentStep {
            shownFrame = min(shownFrame, step.frames.count - 1)
        }
    }
}
