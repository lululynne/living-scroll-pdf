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
    private(set) var lastWheel = -Double.infinity
    /// `raw` when the picture last actually changed. Empty wheel at the top or bottom rewinds here.
    private var restRaw = 0.0
    /// A page that has not moved, after the wheel has been still this long, absorbed those events.
    static let absorbStill = 0.25
    private var windowMisses = 0
    /// Last frame taken while past `maxShift`.
    private var lastLook = -Double.infinity
    private var edges = (top: 0, bottom: 0)
    /// Keyboard or scrollbar movement since the last placed frame: the wheel total no longer
    /// matches the page, so a recovery number would be invented.
    private(set) var wheelCredible = true

    init(body: Int, pixelScale: Int) {
        self.body = body
        self.pixelScale = pixelScale
    }

    /// Calibrated once the measured shifts add up to half a frame.
    var calibrated: Bool { samples.reduce(0) { $0 + abs($1.d) } >= Double(body) / 2 }
    var ratio: Double {
        guard !samples.isEmpty else { return 1 }
        let r = samples.reduce(0) { $0 + $1.raw }
        guard abs(r) >= 1 else { return 1 }
        return min(4, max(0.25, samples.reduce(0) { $0 + $1.d } / r))
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

    /// A wheel event has been counted. Going quiet does not clear it; keys never set it.
    var wheelSeen: Bool { lastWheel.isFinite }

    mutating func wheel(deltaY: Double, precise: Bool, at t: Double, pointDelta: Double = 0) {
        // Negative deltaY / pointDelta scrolls towards later content, which moves the content up (d > 0).
        // A mouse's scrollingDeltaY × 40 is about four times the real move; pointDelta is that move.
        let points: Double
        if precise {
            points = deltaY
        } else if pointDelta != 0 {
            points = pointDelta
        } else {
            points = deltaY * Self.lineHeight
        }
        raw -= points * Double(pixelScale)
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
        if d != 0, capture.raw != 0 {
            let r = Double(d) / capture.raw
            if r >= 0.25 && r <= 4 {
                samples.append((Double(d), capture.raw))
                while samples.count > 8 || (samples.count > 2 && samples.dropFirst().reduce(0, { $0 + abs($1.d) }) >= Double(body) * 2) { samples.removeFirst() }
            } else {
                // The wheel total does not describe this move (empty notches at the top or bottom,
                // reversed quickly). The frame just placed is the proof of where the page is.
                raw = 0
                restRaw = 0
                windowMisses = 0
                wheelCredible = true
                edges = (min(body / 5, newEdges.top), min(body / 5, newEdges.bottom))
                return
            }
        }
        // What the wheel moved after the frame was taken carries over to the next one.
        // ratio is clamped to 0.25...4, so this cannot amplify a poisoned residual.
        raw -= Double(d) / ratio
        windowMisses = 0
        wheelCredible = true
        edges = (min(body / 5, newEdges.top), min(body / 5, newEdges.bottom))
    }

    mutating func lost(_ capture: Capture) {
        if capture.expected != nil { windowMisses += 1 }
        // `raw` keeps running: the last placed frame is still the origin, and later wheel
        // events (inertia included) stay on the same total. Recovery copy reads that total;
        // it is never fed back into capture() or the stitcher.
    }

    /// Keys or dragging a scroll bar moved the page without a wheel event.
    mutating func invalidateWheel() { wheelCredible = false }

    /// A frame was placed outside wheel control (keyboard, scroll bar): start counting afresh.
    mutating func resync() {
        raw = 0
        restRaw = 0
        wheelCredible = true
    }

    /// After a judged frame. Identical pixels plus a still wheel mean the page absorbed the
    /// events (top or bottom); rewind `raw` so empty notches do not pile up. The stitcher
    /// has already seen this frame.
    mutating func noteJudgedFrame(identical: Bool, at t: Double) {
        if identical {
            if t - lastWheel > Self.absorbStill, raw != restRaw {
                raw = restRaw
            }
        } else {
            restRaw = raw
        }
    }

    /// Signed distance from the last placed frame, in screens of `body`. Positive is later
    /// content (still need to go up); negative is earlier. A negative estimate is not proof
    /// the page went past the break — the wheel can under-count — so the bar does not say
    /// "go down" from this number alone.
    enum RecoveryDistance: Equatable {
        case unknown
        case arrived
        case offset(screens: Double)
    }

    /// Closer than this, the distance is `.arrived`. The bar prints no number either way.
    static let arrivedScreens = 0.05

    static func recoveryDistance(estimate: Int, body: Int, wheelActive: Bool, wheelCredible: Bool) -> RecoveryDistance {
        guard wheelActive, wheelCredible else { return .unknown }
        let screens = Double(estimate) / Double(max(1, body))
        if abs(screens) < arrivedScreens { return .arrived }
        return .offset(screens: screens)
    }

    func recovery(at t: Double) -> RecoveryDistance {
        Self.recoveryDistance(estimate: estimate, body: body, wheelActive: active(at: t), wheelCredible: wheelCredible)
    }

    /// Unconfirmed wheel copy. `.unknown` is nil so a quiet wheel keeps the last sentence.
    /// Above 0.3 screens and still positive: an approximate "keep going up". At or below 0.3,
    /// including a negative estimate, there is no number and no "到了".
    static func recoveryStatusText(_ d: RecoveryDistance) -> String? {
        switch d {
        case .unknown:
            return nil
        case .arrived:
            return unconfirmedNearText()
        case .offset(let screens):
            guard screens > 0.3 else { return unconfirmedNearText() }
            let n = String(format: "%+.1f", screens)
            return L("还没接上 · 约 ↑ \(n) 屏，继续往上", "not joined yet · about ↑ \(n) screens, keep going up")
        }
    }

    /// Wheel estimate is at the break, past it, or too close to print. The page has not joined.
    static func unconfirmedNearText() -> String {
        L("还没接上 · 继续往上，接上会提示", "not joined yet · keep going up, it'll say when it joins")
    }

    /// The lost frame was found above the last placed frame. `screens` is negative.
    static func locatedDownText(_ screens: Double) -> String {
        let n = String(format: "%.1f", abs(screens))
        return L("滚过头了 · 往下约 \(n) 屏", "too far · about \(n) screens down")
    }

    /// Picture says down, but the live distance is inside 0.1 screen. No digit, so it cannot say 0.0.
    static func numberlessDownText() -> String {
        L("滚过头了 · 往下，接上会提示", "too far · scroll down, it'll say when it joins")
    }

    /// The down proof was reversed, contradicted, or unmatched for too long.
    static func pictureNeutralText() -> String {
        L("还没接上 · 慢慢上下滚，接上会提示", "not joined yet · roll slowly up and down, it'll say when it joins")
    }

    /// Closer than this, a picture distance prints no number.
    static let pictureNumberFloor = 0.1
    /// Wheel movement back toward earlier content, in screens of `body`, that drops a down proof.
    static let pictureReverseScreens = 0.15
    /// How long a miss may keep the down sentence before the bar asks for a slow roll.
    static let pictureMissLimit = 2.0

    /// Display-only offset from one canvas match. `raw` of the tracker is not this.
    struct PictureHold: Equatable {
        /// Signed pixels from the last placed frame to the matched frame. Negative is earlier content.
        var pixels: Int
        /// `Capture.raw` at the moment the frame was requested, before later wheel events.
        var rawAtTake: Double
        var provedAt: Double
        /// First `.none` after the proof. Nil while the last search still agreed, or was skipped.
        var missSince: Double?
        /// Latched: reverse, a positive match, or a miss that outlasted `pictureMissLimit`.
        var neutral: Bool
    }

    /// How long `.over` stays up once it appears, so a stats write cannot flicker it off.
    static let overDwell = 0.8
    /// How long the one-shot rejoin line stays up.
    static let joinedDwell = 1.5

    /// What the bar is allowed to remember between calls. The session keeps one of these;
    /// it does not choose the sentence itself.
    struct HUDHold: Equatable {
        var overUntil = -Double.infinity
        var overLatched = false
        var joinedUntil = -Double.infinity
        /// Stays set through `joinedUntil`, and clears on the call that ends the line.
        /// A pure `now < joinedUntil` check would skip that call, so a quiet wheel would
        /// leave "接上了" on the bar.
        var joinedLatched = false
        var wasRecovering = false
        /// Last unconfirmed distance sentence while recovering. A quiet wheel keeps it.
        /// A picture proof clears it, so a quiet wheel cannot bring back an "约 ↑" the picture already denied.
        var lastDistanceText: String? = nil
        /// Canvas match used only for the sentence. Nil when nothing is lost, or auto-scroll is on.
        var picture: PictureHold? = nil

        func dwells(at _: Double) -> Bool { overLatched || joinedLatched }
    }

    /// Fold one locate result into the picture hold. Does not read or write the wheel total.
    /// A negative `found` is the only proof of "往下". A positive one, while a proof is up, contradicts it.
    static func integrateLocate(_ verdict: Stitcher.LocateVerdict, rawAtTake: Double, now: Double, hold: inout HUDHold) {
        switch verdict {
        case .skipped:
            break
        case .found(let px) where px < 0:
            hold.picture = PictureHold(pixels: px, rawAtTake: rawAtTake, provedAt: now, missSince: nil, neutral: false)
            hold.lastDistanceText = nil
        case .found:
            if hold.picture != nil {
                hold.picture?.neutral = true
                hold.lastDistanceText = nil
            }
        case .none:
            if hold.picture != nil, hold.picture?.neutral != true, hold.picture?.missSince == nil {
                hold.picture?.missSince = now
            }
        }
    }

    static func dropPicture(_ hold: inout HUDHold) {
        hold.picture = nil
    }

    struct HUDInput: Equatable {
        var now: Double
        var recovering: Bool
        var autoScroll: Bool = false
        var lost: Bool = false
        /// Measured shift was nonzero. Manual copy does not prefix on this; both kinds of
        /// frame stay on the same line.
        var nonzeroShift: Bool = false
        var wheelCredible: Bool = true
        var wheelSeen: Bool = false
        var distance: RecoveryDistance = .unknown
        /// Wheel total and scale, so a picture distance can follow the wheel between frames.
        /// `body` is the scrolling band in pixels. Defaults keep older call sites on the wheel sentence.
        var wheelRaw: Double = 0
        var wheelRatio: Double = 1
        var body: Int = 1
        var gauge: Gauge = .idle
        var frames: Int
        var shownPx: Int
        /// Capture, geometry and auto-pause errors. Shown as-is; holds do not move under them.
        var urgent: String? = nil
        /// Last wheel event time; recovery "arrived" is verified against how long it has been still.
        var lastWheelAt: Double = -.infinity
    }

    static func captureStats(frames: Int, shownPx: Int) -> String {
        L("已收 \(frames) 张 · 长 \(shownPx) px", "\(frames) taken · \(shownPx) px tall")
    }

    static func recoveringFallback(frames: Int, shownPx: Int) -> String {
        let text = captureStats(frames: frames, shownPx: shownPx)
        return L("滚过头了，往回滚到和上一帧重叠的地方才会接上 · 现在点完成会标成未完成 · ", "Scrolled too far. It joins only after you scroll back over the last frame · finishing now marks this capture incomplete · ") + text
    }

    /// Manual (and auto) status line.
    ///
    /// Approaching / ready used to be rewritten every tick, and every moved frame added
    /// "刚接上", so the bar flickered. Those are gone. `.over` stays at least `overDwell`
    /// seconds. "接上了" is only the falling edge of `recovering`, held `joinedDwell`
    /// seconds. While recovering, a positive wheel estimate above 0.3 screens is an
    /// approximation; at or below that, and for every negative estimate, there is no number.
    /// A picture proof of earlier content says "往下" and follows the wheel from the raw
    /// at the shot. It is not replaced by an older "约 ↑". Inside 0.1 screen the digits drop.
    /// A reverse of 0.15 screen, a positive match, or a miss held for 2 s asks for a slow roll.
    /// A wheel that goes quiet keeps the last unconfirmed sentence only when no picture is up.
    /// A non-credible wheel — or no wheel at all — uses the long sentence, picture included.
    static func hudLine(_ input: HUDInput, hold: inout HUDHold) -> String {
        if let urgent = input.urgent { return urgent }
        let stats = captureStats(frames: input.frames, shownPx: input.shownPx)
        if input.autoScroll {
            if input.lost {
                return L("这一下没对上，往回退一点重来 · ", "Lost the place, backing up to retry · ") + stats
            }
            return stats
        }
        let showJoined = noteJoined(input, hold: &hold)
        if input.recovering { return recoveryLine(input, stats: stats, hold: &hold) }
        let showOver = noteOver(input, hold: &hold)
        if showJoined { return L("接上了 · ", "Joined · ") + stats }
        if showOver {
            return L("滚过头了，往回滚到还重叠的位置", "Too far, scroll back until the screens overlap")
        }
        return stats
    }

    /// Falling edge of recovery: one "接上了", then the clock. Later frames do not restart it.
    private static func noteJoined(_ input: HUDInput, hold: inout HUDHold) -> Bool {
        if hold.wasRecovering && !input.recovering {
            hold.joinedUntil = input.now + joinedDwell
            hold.joinedLatched = true
            hold.lastDistanceText = nil
            hold.picture = nil
        }
        hold.wasRecovering = input.recovering
        if hold.joinedLatched && input.now >= hold.joinedUntil {
            hold.joinedLatched = false
        }
        return !input.recovering && hold.joinedLatched
    }

    /// `.over` is level-triggered, plus a minimum dwell after it first appears.
    private static func noteOver(_ input: HUDInput, hold: inout HUDHold) -> Bool {
        let gaugeOver: Bool
        if case .over = input.gauge { gaugeOver = true } else { gaugeOver = false }
        if gaugeOver {
            if !hold.overLatched {
                hold.overLatched = true
                hold.overUntil = input.now + overDwell
            }
        } else if input.now >= hold.overUntil {
            hold.overLatched = false
        }
        return hold.overLatched && (gaugeOver || input.now < hold.overUntil)
    }

    private static func recoveryLine(_ input: HUDInput, stats: String, hold: inout HUDHold) -> String {
        let fallback = recoveringFallback(frames: input.frames, shownPx: input.shownPx)
        // Keys and the scroll bar move the page off the wheel total. A number there would be invented.
        // No wheel at all is the same sentence: there is no distance to keep.
        if !input.wheelCredible {
            hold.lastDistanceText = nil
            return fallback
        }
        if !input.wheelSeen { return fallback }
        if var pic = hold.picture {
            let body = max(1, input.body)
            let moved = (input.wheelRaw - pic.rawAtTake) * input.wheelRatio
            let reversed = moved <= -Double(body) * pictureReverseScreens
            let stale = pic.missSince.map { input.now - $0 >= pictureMissLimit } ?? false
            if reversed || stale || pic.neutral {
                pic.neutral = true
                hold.picture = pic
                hold.lastDistanceText = nil
                return pictureNeutralText()
            }
            hold.picture = pic
            let screens = (Double(pic.pixels) + moved) / Double(body)
            // Well past the break again: the picture no longer says which way.
            if screens > 0.3 {
                pic.neutral = true
                hold.picture = pic
                hold.lastDistanceText = nil
                return pictureNeutralText()
            }
            if screens < -pictureNumberFloor { return locatedDownText(screens) }
            return numberlessDownText()
        }
        if let text = recoveryStatusText(input.distance) {
            hold.lastDistanceText = text
            return text
        }
        // Wheel went quiet (`active` is false, so the distance is `.unknown`). Keep the last figure.
        if let last = hold.lastDistanceText { return last }
        return fallback
    }
}
