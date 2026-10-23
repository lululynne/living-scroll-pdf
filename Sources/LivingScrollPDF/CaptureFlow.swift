import Foundation

// Capture-loop decisions that do not need the screen: when a frame counts as settled, how
// auto-scroll paces itself, and when manual mode takes the next frame. CaptureSession and the
// self-test drive the same code.

/// Auto mode only stitches a frame once the picture has stopped moving: two captures in a row
/// that agree. A thin blinking caret is tolerated; anything else that keeps changing (an
/// animation, an image still loading) is not, and after 1.5 s the capture pauses instead.
/// Same rules as codex's FrameSettler (review/codex 49a9085), written against raw buffers.
struct FrameSettler {
    enum Result: Equatable { case waiting, ready, timedOut }
    var pixelScale = 1
    var deadline = 1.5
    private var previous: PixelFrame?
    private var beganAt: Double?

    mutating func reset() { previous = nil; beganAt = nil }

    mutating func observe(_ frame: PixelFrame, at time: Double) -> Result {
        if beganAt == nil { beganAt = time }
        let stable = previous.map { Self.stationary($0, frame, scale: pixelScale) } ?? false
        previous = frame
        if stable { return .ready }
        return time - beganAt! >= deadline ? .timedOut : .waiting
    }

    static func stationary(_ a: PixelFrame, _ b: PixelFrame, scale: Int) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        if a.bytes == b.bytes { return true }
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, changed = 0
        let w = a.width
        return a.bytes.withUnsafeBufferPointer { pa in
            b.bytes.withUnsafeBufferPointer { pb in
                for y in 0..<a.height {
                    var i = y * w * 4
                    for x in 0..<w {
                        if abs(Int(pa[i]) - Int(pb[i])) > 8 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 8 || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 8 {
                            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                            changed += 1
                            if changed > 128 * scale * scale || maxX - minX + 1 > 8 * scale { return false }
                        }
                        i += 4
                    }
                }
                return changed == 0 || maxY - minY + 1 <= 64 * scale
            }
        }
    }
}

/// Auto-scroll pacing. Step sizes are fractions of the base step (45% of the region height).
/// Wheel commands are requests, not measurements: the shift the next frame should have is the
/// average of what recent steps actually moved, per unit of command.
struct AutoPacer {
    enum Action: Equatable { case resample, scroll(Double), pause, finish }
    private(set) var scale = 1.0
    /// Frames lost since the last progress.
    private(set) var failures = 0
    private var lastForward = 1.0
    private var lastWasForward = false
    /// Commands sent since the last placed frame (fractions; backing up subtracts).
    private var sincePlaced = 0.0
    private var idle = 0
    /// Content pixels moved per unit of command, latest placements.
    private var perUnit: [Double] = []

    mutating func sent(_ fraction: Double) {
        sincePlaced += fraction
        lastWasForward = fraction > 0
        if fraction > 0 { lastForward = fraction }
    }

    /// Shift expected for the next frame, once at least one step has been measured.
    var expected: Int? {
        guard !perUnit.isEmpty else { return nil }
        return Int((perUnit.reduce(0, +) / Double(perUnit.count) * sincePlaced).rounded())
    }

    /// `movingShare`: the share of the view that actually scrolls (a pinned header or privacy panel
    /// can leave much less than a screen). Forward steps are capped at it, so a step never runs past
    /// the overlap of the part that moves. After codex (fix/realtest-codex-20261022 64e78ce, AutoPacer.next).
    mutating func next(after outcome: Stitcher.Outcome, movingShare: Double = 1) -> Action {
        let ceiling = min(1, max(0.05, movingShare))
        scale = min(scale, ceiling)
        switch outcome {
        case .lost:
            idle = 0
            failures += 1
            if failures >= 6 { return .pause }
            // First look again where we are: a picture still loading may line up a moment later.
            if failures == 1 { return .resample }
            // Then back up by half of the step that was actually sent, and go on with smaller steps.
            scale = max(min(0.25, ceiling), scale / 2)
            return .scroll(-lastForward / 2)
        case .shifted(let d) where d != 0:
            if sincePlaced > 0.05 {
                perUnit.append(Double(d) / sincePlaced)
                if perUnit.count > 4 { perUnit.removeFirst() }
            }
            sincePlaced = 0
            failures = 0
            idle = 0
            scale = min(ceiling, scale * 1.5)
            return .scroll(scale)
        case .first:
            return .scroll(scale)
        default: // unchanged
            sincePlaced = 0
            // Only a forward step that moved nothing says "the end"; a back-up that lands exactly
            // on the reference does not.
            if lastWasForward { idle += 1 }
            return idle >= 4 ? .finish : .scroll(scale)
        }
    }
}

/// Manual mode, as Meibao laid it out. The frame has fixed marks (its top edge, its bottom edge,
/// its height); a moving mark travels up with the content as the user scrolls. When the moving
/// mark reaches the seam line, that frame is taken and joined end to end with the last one.
///
/// The moving mark is driven by the user's own wheel and trackpad events, inertia included. The
/// seam line is not the very top edge: a frame is taken while it still shares `seamOverlap`
/// rows with the last one, enough to step over the fades and pinned buttons at both edges and
/// still have content left to check the join against. The wheel only says when to look and
/// roughly where; the pixels decide where the frame goes.
struct ManualTracker {
    enum Gauge: Equatable {
        /// No wheel movement since the last frame.
        case idle
        /// Content rows still to scroll before the next frame is taken.
        case approaching(Int)
        /// At the seam line: the next frame is being taken.
        case ready
        /// Past the point where the join can still be checked: scroll back.
        case over(Int)
    }

    struct Capture: Equatable {
        /// Shift the frame should have; nil while the wheel has not been calibrated yet.
        let expected: Int?
        let tolerance: Int
        let raw: Double
    }

    /// Wheel lines are converted at this many points per line until calibration takes over.
    static let lineHeight = 40.0
    /// Rows that scroll: the frame height until a placement shows less of it moving (a pinned header
    /// or panel). The seam line and the overlap limits are taken from it, so steps fit the moving part.
    var body: Int
    let pixelScale: Int
    /// Wheel movement since the last placed frame, in content pixels, uncalibrated.
    private(set) var raw = 0.0
    /// Recent (measured shift, wheel distance) pairs; the ratio is their sums' quotient.
    private var samples: [(d: Double, raw: Double)] = []
    private var lastWheel = -Double.infinity
    private var windowMisses = 0
    /// Last frame taken while past `maxShift`.
    private var lastLook = -Double.infinity
    private var edges = (top: 0, bottom: 0)

    init(body: Int, pixelScale: Int) {
        self.body = body
        self.pixelScale = pixelScale
    }

    /// Calibrated once the measured shifts add up to half a frame.
    var calibrated: Bool { samples.reduce(0) { $0 + abs($1.d) } >= Double(body) / 2 }
    var ratio: Double {
        let r = samples.reduce(0) { $0 + $1.raw }
        return abs(r) < 1 ? 1 : samples.reduce(0) { $0 + $1.d } / r
    }
    var estimate: Int { Int((raw * ratio).rounded()) }

    /// Overlap the join needs: both edge bands plus room to check, never less than a quarter.
    var minOverlap: Int { max(body / 4, edges.top + edges.bottom + max(48 * pixelScale, body * 15 / 100)) }
    /// Overlap kept when the frame is taken: the minimum plus a fifth of the frame, so that a frame
    /// or two of normal scrolling past the seam line still lines up.
    var seamOverlap: Int { min(body * 7 / 10, max(body * 3 / 10, minOverlap + body / 5)) }
    var seamLine: Int { body - seamOverlap }
    var maxShift: Int { body - minOverlap }

    /// The wheel was used within the last two seconds: manual mode is wheel-driven right now.
    func active(at t: Double) -> Bool { t - lastWheel < 2 }

    mutating func wheel(deltaY: Double, precise: Bool, at t: Double) {
        // Negative deltaY scrolls towards later content, which moves the content up (d > 0).
        raw -= deltaY * (precise ? 1 : Self.lineHeight) * Double(pixelScale)
        lastWheel = t
    }

    var gauge: Gauge {
        let e = estimate
        if e > maxShift { return .over(e - maxShift) }
        if e >= seamLine { return .ready }
        if abs(e) < 2 { return .idle }
        return .approaching(seamLine - e)
    }

    /// Whether to take a frame now. At the seam line, at once; when the user stops short of it
    /// (or has scrolled back up), after a third of a second. Past `maxShift` (scrolled too far, or a
    /// frame was dropped and the wheel kept going) still every 0.3 s, matched over every shift: the
    /// estimate can be off, the user may already be scrolling back, and a capture that stops looking
    /// while the wheel turns can never reconnect (live2-opus: 75 s without a single frame).
    ///
    /// Until the wheel has been calibrated against measured shifts, every tick that moved is taken:
    /// an uncalibrated reading could be far enough off to put the seam line past the point of no
    /// return. Those frames are still searched around the raw reading first, with a wider window.
    mutating func capture(at t: Double) -> Capture? {
        let base = max(16 * pixelScale, body * 12 / 100)
        let stopped = t - lastWheel > 0.35
        let e = estimate
        guard calibrated else {
            guard abs(raw) >= Double(4 * pixelScale) || (stopped && abs(raw) >= 0.5) else { return nil }
            return Capture(expected: e, tolerance: max(base, abs(e) * 3 / 10), raw: raw)
        }
        if e > maxShift {
            guard t - lastLook >= 0.3 else { return nil }
            lastLook = t
            return Capture(expected: nil, tolerance: 0, raw: raw)
        }
        guard e >= seamLine || (stopped && abs(raw) >= 0.5) else { return nil }
        // After two misses in a row inside the window, search every shift.
        return Capture(expected: windowMisses < 2 ? e : nil, tolerance: base, raw: raw)
    }

    mutating func placed(d: Int, capture: Capture, edges newEdges: (top: Int, bottom: Int)) {
        if abs(capture.raw) >= Double(4 * pixelScale) && d != 0 {
            samples.append((Double(d), capture.raw))
            while samples.count > 8 || (samples.count > 2 && samples.dropFirst().reduce(0, { $0 + abs($1.d) }) >= Double(body) * 2) { samples.removeFirst() }
        }
        // What the wheel moved after the frame was taken carries over to the next one.
        raw -= Double(d) / ratio
        windowMisses = 0
        edges = (min(body / 5, newEdges.top), min(body / 5, newEdges.bottom))
    }

    mutating func lost(_ capture: Capture) {
        if capture.expected != nil { windowMisses += 1 }
    }

    /// A frame was placed outside wheel control (keyboard, scroll bar): start counting afresh.
    mutating func resync() { raw = 0 }
}
