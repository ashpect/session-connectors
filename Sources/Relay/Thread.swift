import AppKit
import QuartzCore

/// The colored string you see while picking. It comes out of Relay's Pick button and follows your
/// cursor; when you click a pane its loose end latches onto that pane, takes the session's color,
/// and gets pulled back into Relay. It's a small verlet rope, so it sags and swings as you move.
final class ThreadOverlay {
    private let window: OverlayWindow
    private let line = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let pin = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let endPin = CAShapeLayer()
    private var timer: Timer?

    private enum Reel: Equatable {
        case none                 // loose end follows the cursor
        case pinned               // loose end latched onto a point, waiting
        case holding(Int)         // latched, pulled in after this many frames
        case backToAnchor         // loose end flies back into the pinned end
    }

    private var anchor = NSPoint.zero
    private var tail: NSPoint?
    private var endTarget: NSPoint?
    private var reel = Reel.none
    private var completion: (() -> Void)?
    private var points: [CGPoint] = []
    private var previous: [CGPoint] = []
    var mouse: () -> NSPoint = { NSEvent.mouseLocation }  // swapped out by the --thread-snapshot debug path
    private static let count = 20

    init() {
        let frame = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        window = OverlayWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        window.contentView = view
        let root = view.layer!

        for l in [glow, line] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            root.addSublayer(l)
        }
        glow.lineWidth = 7
        line.lineWidth = 2.2
        line.shadowColor = NSColor.black.cgColor
        line.shadowOpacity = 0.35
        line.shadowRadius = 2
        line.shadowOffset = CGSize(width: 0, height: -1)

        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
        for p in [pin, endPin] {
            p.path = CGPath(ellipseIn: CGRect(x: -4.5, y: -4.5, width: 9, height: 9), transform: nil)
            p.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
            p.lineWidth = 1.5
        }
        root.addSublayer(ring)
        root.addSublayer(pin)
        root.addSublayer(endPin)
    }

    /// Start a fresh thread pinned at `anchor` (screen coordinates), loose end on the cursor.
    func attach(at anchor: NSPoint, color: NSColor) {
        flushCompletion()
        reel = .none
        tail = nil
        endTarget = nil
        self.anchor = anchor
        let a = local(anchor)
        points = Array(repeating: a, count: Self.count)
        previous = points

        setColor(color, animated: false)
        withoutAnimation {
            pin.position = a
            ring.position = a
            endPin.isHidden = true
        }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.6
        pulse.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [pulse, fade]
        group.duration = 1.2
        group.repeatCount = .infinity
        ring.add(group, forKey: "pulse")

        window.alphaValue = 1
        window.orderFrontRegardless()
        if timer == nil {
            timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    func setColor(_ color: NSColor, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        line.strokeColor = color.cgColor
        glow.strokeColor = color.withAlphaComponent(0.22).cgColor
        pin.fillColor = color.cgColor
        endPin.fillColor = color.cgColor
        ring.strokeColor = color.withAlphaComponent(0.6).cgColor
        CATransaction.commit()
    }

    /// Latch the loose end onto `point` right away, before we know what was clicked.
    func pin(at point: NSPoint) {
        guard timer != nil, reel == .none else { return }
        tail = mouse()
        endTarget = point
        reel = .pinned
    }

    /// Clicked something that wasn't a pane: let go and follow the cursor again.
    func release() {
        guard reel == .pinned else { return }
        reel = .none
    }

    /// Latch onto `point` in `color`, hold a moment, then pull the thread back into Relay.
    /// `completion` runs once the thread is in (or if it's interrupted).
    func connect(to point: NSPoint, color: NSColor, fromAnchor: Bool = false, completion: @escaping () -> Void) {
        guard timer != nil else { return completion() }
        flushCompletion()
        self.completion = completion
        if reel == .none { tail = fromAnchor ? anchor : mouse() }
        endTarget = point
        reel = .holding(fromAnchor ? 55 : 36)
        setColor(color, animated: true)
    }

    /// Cancelled: the loose end flies back to where the thread is pinned.
    func reelBack() {
        guard timer != nil, reel == .none || reel == .pinned else { return }
        tail = tail ?? mouse()
        reel = .backToAnchor
    }

    func hide(animated: Bool = true) {
        reel = .none
        timer?.invalidate()
        timer = nil
        ring.removeAllAnimations()
        flushCompletion()
        guard animated else { return window.orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; window.animator().alphaValue = 0 },
                                             completionHandler: { [window] in window.orderOut(nil) })
    }

    // MARK: -

    /// Debug: advance the rope `frames` ticks with the cursor held at `cursor`.
    func debugRun(frames: Int, cursor: NSPoint) {
        timer?.invalidate()  // stays non-nil, so the thread still counts as active; hide() clears it
        mouse = { cursor }
        for _ in 0..<frames where timer != nil { tick() }
    }

    /// Debug: render the overlay into a bitmap over a dark background.
    func debugImage() -> NSBitmapImageRep? {
        let size = window.frame.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        window.contentView!.layer!.render(in: ctx)
        return rep
    }

    private func tick() {
        var end = mouse()
        switch reel {
        case .none:
            tail = nil
        case .pinned, .holding:
            end = Self.lerp(tail ?? end, endTarget ?? end, 0.3)
            tail = end
            if case .holding(let n) = reel { reel = n <= 0 ? .backToAnchor : .holding(n - 1) }
        case .backToAnchor:
            end = Self.lerp(tail ?? end, anchor, 0.16)
            tail = end
            if hypot(end.x - anchor.x, end.y - anchor.y) < 4 { return hide(animated: false) }
        }

        let a = local(anchor), e = local(end)
        step(anchor: a, end: e)
        withoutAnimation {
            let path = Self.smoothPath(points)
            line.path = path
            glow.path = path
            pin.position = a
            ring.position = a
            endPin.position = e
            endPin.isHidden = reel == .none || reel == .backToAnchor
        }
    }

    private func flushCompletion() {
        let c = completion
        completion = nil
        c?()
    }

    private func step(anchor a: CGPoint, end: CGPoint) {
        let dt: CGFloat = 1.0 / 120, gravity: CGFloat = -2400, damping: CGFloat = 0.965
        let n = points.count
        for i in 1..<(n - 1) {
            let p = points[i]
            let v = CGPoint(x: (p.x - previous[i].x) * damping, y: (p.y - previous[i].y) * damping)
            previous[i] = p
            points[i] = CGPoint(x: p.x + v.x, y: p.y + v.y + gravity * dt * dt)
        }
        points[0] = a
        points[n - 1] = end
        previous[0] = a
        previous[n - 1] = end

        // Always ~12% slack, so the thread hangs a little however far you drag it.
        let segment = max(hypot(end.x - a.x, end.y - a.y) * 1.12, 30) / CGFloat(n - 1)
        for _ in 0..<14 {
            for i in 0..<(n - 1) {
                let p = points[i], q = points[i + 1]
                let dx = q.x - p.x, dy = q.y - p.y
                let d = max(hypot(dx, dy), 0.0001)
                let k = (d - segment) / d
                let pinnedP = i == 0, pinnedQ = i + 1 == n - 1
                if !pinnedP && !pinnedQ {
                    points[i] = CGPoint(x: p.x + dx * k * 0.5, y: p.y + dy * k * 0.5)
                    points[i + 1] = CGPoint(x: q.x - dx * k * 0.5, y: q.y - dy * k * 0.5)
                } else if pinnedP && !pinnedQ {
                    points[i + 1] = CGPoint(x: q.x - dx * k, y: q.y - dy * k)
                } else if !pinnedP && pinnedQ {
                    points[i] = CGPoint(x: p.x + dx * k, y: p.y + dy * k)
                }
            }
        }
    }

    /// Catmull-Rom through the rope points.
    private static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private static func lerp(_ p: NSPoint, _ q: NSPoint, _ t: CGFloat) -> NSPoint {
        NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
    }

    private func local(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - window.frame.origin.x, y: p.y - window.frame.origin.y)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

/// Borderless windows get clamped to one screen by default; this one spans all of them.
private final class OverlayWindow: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
