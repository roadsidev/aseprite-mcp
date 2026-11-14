import SwiftUI
import AppKit

struct PixelCanvas: View {
    let model: LiveModel
    let clock: FrameClock

    var body: some View {
        // This dependency must live in body, not just in Canvas's renderer.
        // DisplayDriver advances the engine first, then bumps this value.
        let tick = clock.tick
        Canvas(rendersAsynchronously: false) { gc, size in
            _ = tick
            Self.draw(model: model, gc: &gc, size: size, now: model.engine.renderTime)
        }
        .accessibilityLabel("Lienzo de pixel art")
    }

    static func spriteRect(width: Int, height: Int, size: CGSize) -> CGRect {
        guard width > 0, height > 0 else { return .zero }
        let fit = min(max(1, size.width - 8) / CGFloat(width), max(1, size.height - 8) / CGFloat(height))
        // Whole-number magnification; when the sprite cannot fit at 1×, use
        // reciprocal integer reduction instead of clipping it outside the view.
        let scale = fit >= 1 ? max(1, floor(fit)) : 1 / ceil(1 / fit)
        let w = CGFloat(width) * scale, h = CGFloat(height) * scale
        return CGRect(x: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded(), width: w, height: h)
    }

    static func draw(model: LiveModel, gc: inout GraphicsContext, size: CGSize, now: CFTimeInterval) {
        let engine = model.engine
        guard let image = engine.currentImage(), engine.width > 0 else { return }
        let rect = spriteRect(width: engine.width, height: engine.height, size: size)
        let scale = rect.width / CGFloat(engine.width)
        let progress = engine.transitionProgress(now: now)
        let oldRect = spriteRect(width: engine.previousWidth, height: engine.previousHeight, size: size)
        let outline = engine.previousImage == nil ? rect : CGRect(
            x: oldRect.minX + (rect.minX - oldRect.minX) * progress,
            y: oldRect.minY + (rect.minY - oldRect.minY) * progress,
            width: oldRect.width + (rect.width - oldRect.width) * progress,
            height: oldRect.height + (rect.height - oldRect.height) * progress)

        var shadow = gc
        shadow.addFilter(.shadow(color: .black.opacity(0.3), radius: 14, x: 0, y: 7))
        shadow.fill(Path(roundedRect: outline.insetBy(dx: -3, dy: -3), cornerRadius: 5), with: .color(Color(white: 0.12)))

        if let old = engine.previousImage {
            var previous = gc
            previous.opacity = 1 - progress
            drawChecker(gc: &previous, rect: oldRect, scale: oldRect.width / CGFloat(engine.previousWidth))
            previous.draw(Image(decorative: old, scale: 1).interpolation(.none), in: oldRect)
        }
        var sprite = gc
        sprite.opacity = progress
        drawChecker(gc: &sprite, rect: rect, scale: scale)
        if let source = engine.sourceImage {
            let launched = engine.started > 0 ? settledPath(through: engine.changes[engine.started - 1].index,
                engine: engine, rect: rect, scale: scale) : Path()
            var pendingPath = Path(rect)
            pendingPath.addPath(launched)
            var pending = sprite
            pending.clip(to: pendingPath, style: FillStyle(eoFill: true, antialiased: false))
            pending.draw(Image(decorative: source, scale: 1).interpolation(.none), in: rect)
            var activePath = launched
            if let boundary = engine.settledBoundary {
                let settled = settledPath(through: boundary, engine: engine, rect: rect, scale: scale)
                activePath.addPath(settled)
                var completed = sprite
                completed.clip(to: settled, style: FillStyle(antialiased: false))
                completed.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
            }
            if let unchanged = engine.unchangedImage {
                var active = sprite
                active.clip(to: activePath, style: FillStyle(eoFill: true, antialiased: false))
                active.draw(Image(decorative: unchanged, scale: 1).interpolation(.none), in: rect)
            }
            // Native CGContext batches the frontier into one Canvas operation.
            // No texture creation, blur passes, or per-pixel SwiftUI views here.
            sprite.withCGContext { context in
                drawFrontier(engine: engine, context: context, rect: rect, scale: scale, now: now)
            }
        } else {
            sprite.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
        }

        if model.showGrid && scale >= 6 {
            var grid = Path()
            for i in 0...engine.width {
                let x = rect.minX + CGFloat(i) * scale
                grid.move(to: CGPoint(x: x, y: rect.minY)); grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for j in 0...engine.height {
                let y = rect.minY + CGFloat(j) * scale
                grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            sprite.stroke(grid, with: .color(.white.opacity(0.09)), lineWidth: 0.5)
        }
        gc.stroke(Path(roundedRect: outline.insetBy(dx: -3, dy: -3), cornerRadius: 5),
                  with: .color(.white.opacity(0.12)), lineWidth: 0.5)
    }

    /// At most three rectangles describe every settled pixel, even for a full
    /// 256×256 repaint. Source/destination images are each built only once.
    static func settledPath(through index: Int, engine: Engine, rect: CGRect, scale: CGFloat) -> Path {
        let x = index % engine.width, y = index / engine.width
        let bandY = y / 4 * 4, rows = min(4, engine.height - bandY)
        var path = Path()
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: CGFloat(bandY) * scale))
        let forward = (y / 4).isMultiple(of: 2)
        path.addRect(CGRect(x: rect.minX + CGFloat(forward ? 0 : x + 1) * scale,
                            y: rect.minY + CGFloat(bandY) * scale,
                            width: CGFloat(forward ? x : engine.width - x - 1) * scale, height: CGFloat(rows) * scale))
        path.addRect(CGRect(x: rect.minX + CGFloat(x) * scale, y: rect.minY + CGFloat(bandY) * scale,
                            width: scale, height: CGFloat(y - bandY + 1) * scale))
        return path
    }

    static let checkerLight = CGColor(gray: 0.172, alpha: 1)
    static let checkerDark = CGColor(gray: 0.151, alpha: 1)

    static func drawFrontier(engine: Engine, context: CGContext, rect: CGRect, scale: CGFloat, now: CFTimeInterval) {
        guard engine.started > engine.settled else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.setShouldAntialias(true)
        for i in engine.settled..<engine.started {
            let change = engine.changes[i]
            let age = max(0, min(1, (now - change.time) / engine.pixelLife))
            let opacity = Engine.smooth(age / 0.85)
            let growth = engine.reduceMotion ? 1 : 0.52 + 0.48 * Engine.entrance(age)
            let x = change.index % engine.width, y = change.index / engine.width
            let cell = CGRect(x: rect.minX + CGFloat(x) * scale, y: rect.minY + CGFloat(y) * scale, width: scale, height: scale)
            if change.before >> 24 != 0, opacity < 1, let color = engine.colors[change.before] {
                context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha * (1 - opacity))
                context.fill(cell)
            }
            if change.after >> 24 != 0, let color = engine.colors[change.after] {
                let inset = scale * (1 - growth) / 2
                let entering = cell.insetBy(dx: inset, dy: inset)
                // Fold the highlight into the premultiplied color algebraically:
                // one fill instead of a separate white overlay per pixel.
                let flash = engine.reduceMotion ? 0 : sin(.pi * age) * (1 - age) * (1 - age) * 0.45 * color.alpha
                let alpha = flash + color.alpha * opacity * (1 - flash)
                let light = alpha > 0 ? flash / alpha : 0
                context.setFillColor(red: color.red + (1 - color.red) * light,
                                     green: color.green + (1 - color.green) * light,
                                     blue: color.blue + (1 - color.blue) * light, alpha: alpha)
                context.fill(entering)
            }
        }
        context.restoreGState()
    }

    private static func drawChecker(gc: inout GraphicsContext, rect: CGRect, scale: CGFloat) {
        gc.fill(Path(rect), with: .color(Color(cgColor: checkerDark)))
        let tile = CGFloat(max(2, Int(ceil(8 / scale)))) * scale
        var path = Path()
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : tile)
            while x < rect.maxX {
                path.addRect(CGRect(x: x, y: y, width: min(tile, rect.maxX - x), height: min(tile, rect.maxY - y)))
                x += tile * 2
            }
            y += tile; row += 1
        }
        gc.fill(path, with: .color(Color(cgColor: checkerLight)))
    }
}
