import CoreGraphics
import Foundation

/// One captured frame, rendered to tightly packed RGBA8.
final class PixelFrame: @unchecked Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    convenience init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: Stitcher.colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, bytes: buffer)
    }

    /// The frame with its content moved `dx` columns to the left (right when negative); the columns
    /// uncovered at the edge repeat the last real one.
    func shiftedLeft(by dx: Int) -> PixelFrame {
        guard dx != 0 else { return self }
        var out = [UInt8](repeating: 0, count: bytes.count)
        let stride = width * 4
        for y in 0..<height {
            let row = y * stride
            for x in 0..<width {
                let sx = min(width - 1, max(0, x + dx))
                let i = row + x * 4, j = row + sx * 4
                out[i] = bytes[j]; out[i + 1] = bytes[j + 1]; out[i + 2] = bytes[j + 2]; out[i + 3] = bytes[j + 3]
            }
        }
        return PixelFrame(width: width, height: height, bytes: out)
    }

    /// True when a whole row or column is fully transparent: the capture reached outside the window
    /// (its capture area was not where the picked region is), so the picture is not the region.
    /// Rounded window corners are transparent too, but never along a whole edge.
    var reachesOutsideWindow: Bool {
        bytes.withUnsafeBufferPointer { b in
            func clear(_ x: Int, _ y: Int) -> Bool { b[(y * width + x) * 4 + 3] == 0 }
            for x in 0..<width where clear(x, 0) {
                if !(0..<height).contains(where: { !clear(x, $0) }) { return true }
            }
            for y in 0..<height where clear(0, y) {
                if !(0..<width).contains(where: { !clear($0, y) }) { return true }
            }
            return false
        }
    }
}

/// Stitches a stream of same-sized frames of a scrolling region into one tall image.
///
/// Every frame pair is analysed on its own: rows at the top and bottom that did not
/// change are treated as sticky chrome (title bars, chat input boxes), and only the
/// moving band in between is used to find the scroll distance. The canvas is written
/// in content coordinates, so each content row is written exactly once, whatever the
/// sticky-band estimate of a particular pair was.
final class Stitcher: @unchecked Sendable {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    enum Outcome: Equatable {
        case first
        case unchanged
        case shifted(Int)
        /// The frame could not be placed with confidence. Nothing was written and the
        /// reference frame is kept, so scrolling back into overlap picks up where it left off.
        case lost
    }

    /// Pixels whose channels differ by more than this count as changed.
    private let channelTolerance = 24
    /// Pixels differing by more than this are not the same picture (used to find faded rows).
    private let strictTolerance = 4
    /// Minimum rows two frames must share for a shift to be trusted.
    private let minimumOverlap = 16

    private(set) var width = 0
    private(set) var canvasRows = 0
    private(set) var acceptedFrames = 0
    /// Frames that could not be placed and were dropped instead of being pasted in.
    private(set) var lostFrames = 0
    /// True while the last frame could not be placed and nothing placed since. If the capture
    /// ends like this, content the user saw is missing from the result: it is partial.
    private(set) var needsRecovery = false
    /// Canvas row where row 0 of the last placed frame sits.
    var contentOrigin: Int { prevOrigin }
    /// Overlap of the last placed pair, as a fraction of the moving band (for the overlap meter).
    private(set) var lastOverlap: Double?
    /// Rows at the top of the new frame and the bottom of the old one that had to be trimmed
    /// as fixed-to-view (fades, pinned buttons) in the last placement; a running maximum.
    private(set) var edgeBands = (top: 0, bottom: 0)
    /// Consecutive frames in which the content did not move; auto-scroll uses it to detect the end.
    private(set) var staticRun = 0
    /// Display backing scale of the captured frames; noise thresholds are in points.
    var pixelScale = 1
    /// Whether the content may have been scrolled since the capture began. A live session starts
    /// with false and sets it at the first wheel, key or drag event (or auto-scroll step); a verified
    /// non-zero shift sets it too. Until then nothing on screen has been moved by the user, so a
    /// change is the page settling (an ad filling its slot): the newest picture becomes the first
    /// frame and nothing is written. Once input may have scrolled, a frame that does not line up is
    /// dropped as before, however still the rest of it looks. True by default (replay without input log).
    var scrollStarted = true
    /// Rows the last real scroll moved, as a share of the frame (auto-scroll caps its step by it).
    var movingShare: Double { movedBody.map { Double($0.count) / Double(max(1, prev?.height ?? 1)) } ?? 1 }

    private var canvas: [UInt8] = []
    private var prev: PixelFrame?
    /// Canvas row where row 0 of `prev` sits.
    private var prevOrigin = 0
    private var prevTop = 0
    /// The frame reaching furthest down the content. After scrolling back up, the rows it
    /// holds back in its late-written margin would otherwise be lost at the end.
    private var far: (frame: PixelFrame, origin: Int, top: Int)?
    private var started = false

    /// A verified shift and the part of the overlap that is clean in both frames, in rows of the
    /// new frame: what lies above `cleanTop` or from `cleanBottom` on was trimmed as an overlay.
    private struct Placement {
        let d: Int
        let cleanTop: Int
        let cleanBottom: Int
        /// Placed although a block of the overlap changed (an ad filling, emptying or collapsing while
        /// the page scrolled): from this row of the new frame on, the image is cut back and goes on with
        /// the new frame, so the changed part is in its new version only, never half old, half new.
        var cut: Int?
    }

    /// A scrollbar knob at the right edge of a frame: columns `x0..<x1` show the track colour
    /// `track[x - x0]` on every row except `rows` (and the end caps), where the knob is drawn.
    private struct Knob {
        let x0: Int
        let x1: Int
        let rows: Range<Int>
        let track: [UInt32]
    }
    /// The knob seen moving against the content once; later frames are recognised by it.
    private var knobTemplate: (x0: Int, x1: Int, length: Int, track: [UInt32])?
    private var knobs: [ObjectIdentifier: Knob] = [:]
    /// Columns by which the page's layout has moved to the right since the start; frames are shifted back.
    private(set) var xOffset = 0
    /// Rows of the reference frame that the last non-zero placement saw move with the content.
    private var movedBody: Range<Int>?

    private struct PairAnalysis {
        let top: Int
        let footer: Int
        let x0: Int
        let x1: Int
    }

    /// Adds a frame. `expected`, when known (from the wheel events or the auto-scroll history),
    /// is the shift the frame should have; alignment is then only searched within `tolerance`
    /// of it, and what the pixels say always wins over the estimate. Without it, every shift
    /// is searched.
    func add(_ raw: PixelFrame, expected: Int? = nil, tolerance: Int = 0) -> Outcome {
        // After the page's layout moved sideways (see `sideways`), every frame is moved back by as much.
        let frame = xOffset == 0 || raw.width != width ? raw : raw.shiftedLeft(by: xOffset)
        guard let p = prev else {
            prev = frame
            width = frame.width
            acceptedFrames = 1
            return .first
        }
        // A frame of another size cannot be placed; it is not "nothing moved" either.
        guard frame.width == p.width, frame.height == p.height else { return reject() }
        guard let a = analyze(p, frame) else {
            // Identical to the reference: the user is back exactly where the last frame was.
            staticRun += 1
            needsRecovery = false
            return .unchanged
        }

        if !scrollStarted && !started {
            var unsure = false
            if let m = findShift(p, frame, a, ambiguous: &unsure) ?? (unsure ? nil : findShiftWithChanges(p, frame, a, seam: frame.height - a.footer - max(minimumOverlap, (frame.height - a.footer - a.top) * 22 / 100), window: nil)), m.d != 0 {
                scrollStarted = true // it moved, by itself or by a key: stitch from here on as usual
            } else if unsure {
                return reject() // it may have moved, to one of several places: neither stitch nor adopt it
            } else {
                prev = frame
                needsRecovery = false
                staticRun += 1
                return .unchanged
            }
        }

        // Rows near the bottom edge are written late, from a later frame once they have
        // scrolled up: things that float over the bottom of the content (rounded window
        // corners, "jump to latest" buttons) then appear once at the end, not at every seam.
        let bottom = frame.height - a.footer
        let margin = max(minimumOverlap, (bottom - a.top) * 22 / 100)
        let window = expected.map { ($0 - tolerance)...($0 + tolerance) }
        // First canvas row not yet written, and where it falls in the reference frame.
        let written = started ? canvasRows : bottom - margin
        let seam = written - prevOrigin

        // The estimate can be off (the page stops at its end, rubber-bands, or the wheel was read
        // wrong): if nothing lines up inside the window, the full search decides. If two places
        // inside the window line up, the frame is ambiguous and nothing is tried further.
        var ambiguous = false
        var found = findShift(p, frame, a, window: window, ambiguous: &ambiguous)
        if found == nil, window != nil, !ambiguous { found = findShift(p, frame, a, ambiguous: &ambiguous) }
        // A part of the page that moves on its own (an ad drawn a frame late) can line up at its own
        // shift, with the rest of the overlap trimmed away as edges (live-opus 392 -> 393: ad 236, page
        // 260). If another shift has clearly more of the overlap identical to the pixel, the page moved
        // by that one: place the frame there if it holds up as a scroll with a changed block, else drop it.
        if let m = found, let rival = strongerRival(p, frame, a, than: m.d) {
            found = verifyWithChanges(p, frame, body: a.top..<(p.height - a.footer), d: rival,
                                      strips: movingStrips(p, frame, body: a.top..<(p.height - a.footer), x0: a.x0, x1: a.x1).map(\.strip), seam: seam)
            if found == nil { ambiguous = true }
        }
        // Content that already went into the image can change afterwards (an ad loads into its slot,
        // collapses, a carousel turns, the page reflows at its end). Such a frame still lines up below
        // that change, where the next rows are written: place it from there and keep what is written.
        if found == nil, !ambiguous { found = findShiftWithChanges(p, frame, a, seam: seam, window: window) }
        if found == nil, !ambiguous { found = findShiftBesidePinned(p, frame, a, window: window) }
        let inPlace = found == nil && !ambiguous && changedInPlace(p, frame, a, seam: seam) && (window.map { $0.contains(0) } ?? true)
        if found == nil, inPlace {
            // Nothing scrolled; a block of the picture changed where it stands. Rows of it that are
            // already in the image are replaced by the new version (the alignment is proven by the
            // unchanged rows around it), so a block across the seam is never half old, half new; the new
            // picture becomes the reference so that the change is not met again.
            let band = a.top..<(frame.height - a.footer)
            // A block reaching the bottom edge may be a panel pinned over the content: never pasted in.
            let reachesBottom = band.upperBound >= frame.height - 8 * pixelScale
            let rewrite = reachesBottom ? 0..<0 : band.lowerBound..<max(band.lowerBound, min(band.upperBound, canvasRows - prevOrigin))
            if !rewrite.isEmpty {
                let stride = frame.width * 4
                canvas.replaceSubrange(((prevOrigin + rewrite.lowerBound) * stride)..<((prevOrigin + rewrite.upperBound) * stride),
                                       with: frame.bytes[(rewrite.lowerBound * stride)..<(rewrite.upperBound * stride)])
                paintKnob(frame, rows: rewrite, origin: prevOrigin)
            }
            prev = frame
            if let f = far, f.origin == prevOrigin { far = (frame, f.origin, f.top) }
            knobs = knobs.filter { $0.key == ObjectIdentifier(frame) || $0.key == ObjectIdentifier(far!.frame) }
            needsRecovery = false
            staticRun += 1
            return .shifted(0)
        }
        if found == nil, !ambiguous, a.footer + a.top < frame.height / 3, let dx = sideways(p, frame) {
            // The page was laid out again a few pixels to the side (Chrome adds or drops its scroll bar
            // and recentres the page) and nothing scrolled. What is written stays; this frame and all
            // later ones are moved back by as much, so the page goes on lining up with what is written.
            xOffset += dx
            prev = raw.shiftedLeft(by: xOffset)
            if let f = far, f.origin == prevOrigin { far = (prev!, f.origin, f.top) }
            needsRecovery = false
            staticRun += 1
            return .shifted(0)
        }
        guard let m = found else { return reject() }
        let d = m.d
        let origin = prevOrigin + d
        // Rows of the new frame above `cleanTop` showed the content faded or covered. If the seam
        // would start up there, bridge to the clean part with rows of the previous frame instead;
        // those rows were verified clean in the overlap, and must not hold a fixed button either.
        let cleanTop = max(a.top, m.cleanTop)
        let bridgeEnd = origin + cleanTop
        if written < bridgeEnd {
            // Above the clean band the two frames disagree: there is nothing trustworthy to bridge with.
            guard m.cut == nil, cleanTop + d <= bottom,
                  // Four rows of context either side: the detector looks at 5x5 blocks, and a button
                  // just touching the bridge must still be seen.
                  !hasStationaryDetail(p, frame, rows: max(0, written - prevOrigin - 4)..<min(p.height, cleanTop + d + 4), x0: a.x0, x1: a.x1)
            else { return reject() }
        }
        if d != 0 { learnKnob(p, frame, d: d) }
        // Nothing is written before the first frame pair has lined up.
        if !started {
            write(p, rows: 0..<max(0, min(bottom - margin, m.cut.map { $0 + d } ?? Int.max)), origin: 0)
            prevOrigin = 0
            prevTop = 0
            far = (p, 0, 0)
            started = true
        } else if let cut = m.cut, canvasRows > origin + cut {
            // What was written from the cut on shows the old version of the changed part: drop it. Only
            // when the new frame reaches as far as the image does, so that nothing is lost by it.
            guard canvasRows <= origin + bottom - margin else { return reject() }
            let keep = origin + cut
            canvas.removeLast((canvasRows - keep) * frame.width * 4)
            canvasRows = keep
            far = nil
        }
        if canvasRows < bridgeEnd {
            extend(p, origin: prevOrigin, top: prevTop, until: cleanTop + d)
        }
        // The late-write margin keeps short things pinned over the bottom (fades, pills) out of the image.
        // A taller one (a donation or cookie panel that just appeared) shows as a run of disagreeing rows at
        // the bottom of the overlap longer than the fades seen so far: nothing from where it starts is
        // written from this frame. The
        // content behind it comes in later frames, above the panel, and the panel itself once at the end.
        let overlapEnd = min(bottom, frame.height - a.footer - d)
        let trimmed = overlapEnd - m.cleanBottom
        let tall = trimmed > margin || (acceptedFrames >= 2 && trimmed > edgeBands.bottom + (bottom - a.top) / 10 && m.cleanBottom < bottom - margin)
        var hold = m.cleanBottom
        // The clean band was measured only within the edge allowance: find where the panel really starts.
        while tall, hold > cleanTop, m.cleanBottom - hold < 16 * pixelScale,
              !rowsMatch(p, py: hold - 1 + d, frame, fy: hold - 1, x0: a.x0, x1: a.x1, tolerance: strictTolerance) { hold -= 1 }
        // Holding back must leave enough written for the next step of the same size to join; otherwise the
        // capture could never go on, and the rows are written as before (the late-write margin).
        let until = tall && hold - d >= cleanTop ? min(bottom - margin, hold) : bottom - margin
        let writtenFrom = canvasRows
        guard extend(frame, origin: origin, top: cleanTop, until: until) else { return reject() }
        // A window pinned over part of the view (a sign-in prompt in a corner) sits still while the
        // content moves under it; written as is, a piece of it would land in every stretch of the image.
        // Where the previous frame showed the content now under it, uncovered, that is used instead.
        if d > 0, let pin = pinnedRect(p, frame, body: a.top..<bottom, d: d) {
            let stride = frame.width * 4
            for fy in max(writtenFrom - origin, pin.rows.lowerBound)..<max(max(writtenFrom - origin, pin.rows.lowerBound), min(canvasRows - origin, pin.rows.upperBound)) {
                let py = fy + d
                guard py < bottom, !pin.rows.contains(py) else { continue }
                let dst = (origin + fy) * stride + pin.cols.lowerBound * 4, src = py * stride + pin.cols.lowerBound * 4
                canvas.replaceSubrange(dst..<(dst + pin.cols.count * 4), with: p.bytes[src..<(src + pin.cols.count * 4)])
            }
        }
        prevOrigin = origin
        prevTop = a.top
        prev = frame
        if let f = far, f.origin > origin {} else { far = (frame, origin, a.top) }
        knobs = knobs.filter { $0.key == ObjectIdentifier(frame) || $0.key == ObjectIdentifier(far!.frame) }
        needsRecovery = false
        let band = bottom - a.top
        lastOverlap = Double(band - abs(d)) / Double(max(1, band))
        if d > 0, m.cut == nil {
            edgeBands = (max(edgeBands.top, m.cleanTop - a.top), max(edgeBands.bottom, bottom - (m.cleanBottom + d)))
        }
        if d != 0 { acceptedFrames += 1; staticRun = 0; movedBody = a.top..<bottom } else { staticRun += 1 }
        return .shifted(d)
    }

    /// Lost track (scrolled too far, or the match was ambiguous). Pasting the frame in would
    /// repeat whatever it shares with the canvas, so it is dropped: canvas, reference and
    /// coordinates stay as they were, and scrolling back into overlap picks up from there.
    private func reject() -> Outcome {
        lostFrames += 1
        needsRecovery = true
        staticRun = 0
        return .lost
    }

    /// Whether `rows` of `p` hold detail that sits still on screen in `f`: a button fixed to the
    /// view, which must not be bridged into the middle of the image. Flat background proves nothing.
    /// After codex's review (review/codex 49a9085, Stitcher.hasStationaryDetail).
    private func hasStationaryDetail(_ p: PixelFrame, _ f: PixelFrame, rows: Range<Int>, x0: Int, x1: Int) -> Bool {
        guard rows.count >= 5, x1 - x0 >= 5, rows.lowerBound >= 0, rows.upperBound <= p.height else { return false }
        let rowBytes = p.width * 4
        let tol = channelTolerance
        return p.bytes.withUnsafeBufferPointer { pb in
            f.bytes.withUnsafeBufferPointer { fb in
                func differs(_ i: Int, _ j: Int) -> Bool {
                    abs(Int(pb[i]) - Int(pb[j])) > tol || abs(Int(pb[i + 1]) - Int(pb[j + 1])) > tol || abs(Int(pb[i + 2]) - Int(pb[j + 2])) > tol
                }
                func still(_ i: Int) -> Bool {
                    abs(Int(pb[i]) - Int(fb[i])) <= 8 && abs(Int(pb[i + 1]) - Int(fb[i + 1])) <= 8 && abs(Int(pb[i + 2]) - Int(fb[i + 2])) <= 8
                }
                for y in rows.lowerBound..<(rows.upperBound - 4) {
                    for x in stride(from: x0, to: x1 - 4, by: 2) {
                        let tl = y * rowBytes + x * 4, tr = tl + 16, bl = tl + rowBytes * 4, br = bl + 16
                        guard (differs(tl, tr) || differs(bl, br)) && (differs(tl, bl) || differs(tr, br)) else { continue }
                        var same = true, detail = 0
                        for dy in 0..<5 where same {
                            for dx in 0..<5 {
                                let i = tl + dy * rowBytes + dx * 4
                                if !still(i) { same = false; break }
                                if differs(tl, i) { detail += 1 }
                            }
                        }
                        if same && detail >= 5 { return true }
                    }
                }
                return false
            }
        }
    }

    func finish() -> CGImage? {
        guard let p = prev else { return nil }
        if !started {
            write(p, rows: 0..<p.height, origin: 0)
        } else {
            let tail = furthest()
            extend(tail.frame, origin: tail.origin, top: tail.top, until: tail.frame.height)
        }
        let image = makeImage()
        canvas = [] // the image holds its own copy; long captures are large
        return image
    }

    private func furthest() -> (frame: PixelFrame, origin: Int, top: Int) {
        if let f = far, f.origin > prevOrigin { return f }
        return (prev!, prevOrigin, prevTop)
    }

    /// Writes rows of `f` (whose row 0 sits at canvas row `origin`) from the first unwritten
    /// canvas row up to row `until`. False when that first unwritten row is above `top`,
    /// i.e. no longer visible in `f`.
    @discardableResult
    private func extend(_ f: PixelFrame, origin: Int, top: Int, until: Int) -> Bool {
        let from = canvasRows - origin
        guard from >= top else { return false }
        if from < until { write(f, rows: from..<until, origin: origin) }
        return true
    }

    func makeImage() -> CGImage? {
        guard width > 0, canvasRows > 0 else { return nil }
        let data = Data(canvas) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: canvasRows, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: Stitcher.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - Canvas

    private func write(_ f: PixelFrame, rows: Range<Int>, origin: Int) {
        precondition(origin + rows.lowerBound == canvasRows, "canvas must grow contiguously")
        let stride = f.width * 4
        canvas.append(contentsOf: f.bytes[(rows.lowerBound * stride)..<(rows.upperBound * stride)])
        canvasRows += rows.count
        // The scrollbar knob sits somewhere else in every frame; written as is, a piece of it would
        // land in every stretch of the image. Its rows get the plain track instead.
        paintKnob(f, rows: rows, origin: origin)
    }

    private func paintKnob(_ f: PixelFrame, rows: Range<Int>, origin: Int) {
        if let k = knob(of: f) {
            let lo = max(rows.lowerBound, k.rows.lowerBound), hi = min(rows.upperBound, k.rows.upperBound)
            for r in lo..<max(lo, hi) {
                for x in k.x0..<k.x1 {
                    let i = ((origin + r) * f.width + x) * 4, c = k.track[x - k.x0]
                    canvas[i] = UInt8(c >> 24); canvas[i + 1] = UInt8((c >> 16) & 0xff); canvas[i + 2] = UInt8((c >> 8) & 0xff); canvas[i + 3] = UInt8(c & 0xff)
                }
            }
        }
    }

    // MARK: - Scrollbar

    /// Track-plus-knob pattern at the right edge: every column of the band is one colour except
    /// for its end caps (arrow buttons of a classic scrollbar, touching the top and bottom edge) and,
    /// in some columns, one run of rows shared by all of them. Nil when the edge looks like anything else.
    private func edgeKnob(_ f: PixelFrame) -> Knob? {
        let w = f.width, h = f.height
        let maxBand = 16 * pixelScale, maxCap = 40 * pixelScale, gap = 2 * pixelScale
        guard w > maxBand * 4, h >= 64 else { return nil }
        func px(_ x: Int, _ y: Int) -> UInt32 {
            let i = (y * w + x) * 4
            return UInt32(f.bytes[i]) << 24 | UInt32(f.bytes[i + 1]) << 16 | UInt32(f.bytes[i + 2]) << 8 | UInt32(f.bytes[i + 3])
        }
        func near(_ a: UInt32, _ b: UInt32) -> Bool {
            for s in [24, 16, 8] where abs(Int((a >> UInt32(s)) & 0xff) - Int((b >> UInt32(s)) & 0xff)) > 3 { return false }
            return true
        }
        var track: [Int: UInt32] = [:]
        var knob: Range<Int>?
        var knobColumns: [Int] = []
        columns: for x in stride(from: w - 1, through: w - maxBand, by: -1) {
            var counts: [UInt32: Int] = [:]
            for y in 0..<h { counts[px(x, y), default: 0] += 1 }
            guard let mode = counts.max(by: { $0.value < $1.value })?.key else { break }
            // Runs of rows off the track colour, small gaps closed.
            var runs: [Range<Int>] = []
            for y in 0..<h where !near(px(x, y), mode) {
                if let r = runs.last, y - r.upperBound <= gap { runs[runs.count - 1] = r.lowerBound..<(y + 1) } else { runs.append(y..<(y + 1)) }
            }
            if let r = runs.first, r.lowerBound == 0, r.count <= maxCap { runs.removeFirst() }
            if let r = runs.last, r.upperBound == h, r.count <= maxCap { runs.removeLast() }
            if runs.count > 1 { break columns }
            if let r = runs.first {
                guard r.count >= 8 * pixelScale, r.count <= h * 6 / 10 else { break columns }
                if let k = knob {
                    guard abs(k.lowerBound - r.lowerBound) <= gap, abs(k.upperBound - r.upperBound) <= gap else { break columns }
                    knob = min(k.lowerBound, r.lowerBound)..<max(k.upperBound, r.upperBound)
                } else { knob = r }
                knobColumns.append(x)
                track[x] = mode
            }
        }
        // Only the knob's own columns are painted, with their track colour: never the caps, never the page.
        guard let rows = knob, let lo = knobColumns.min(), let hi = knobColumns.max(), knobColumns.count == hi - lo + 1 else { return nil }
        return Knob(x0: lo, x1: hi + 1, rows: rows, track: (lo...hi).map { track[$0]! })
    }

    /// A knob is only trusted after it was seen to move against the content: content follows the
    /// shift, a knob creeps the other way. A full-width band of content never passes this test.
    private func learnKnob(_ p: PixelFrame, _ f: PixelFrame, d: Int) {
        guard let kp = edgeKnob(p), let kf = edgeKnob(f), kp.x0 == kf.x0, kp.x1 == kf.x1, kp.track == kf.track,
              abs(kp.rows.count - kf.rows.count) <= 2 * pixelScale else { learnOverlayKnob(p, f, d: d); return }
        let followsContent = abs(kf.rows.lowerBound - (kp.rows.lowerBound - d)) <= 2 * pixelScale
        // It moves, a little: a pinned element at the edge (a banner, a button) does not move at all.
        let creep = kf.rows.lowerBound - kp.rows.lowerBound
        let creeps = creep != 0 && (creep > 0) == (d > 0) && abs(creep) < max(4 * pixelScale, abs(d) / 2)
        guard !followsContent, creeps else { return }
        knobTemplate = (kf.x0, kf.x1, kf.rows.count, kf.track)
        knobs[ObjectIdentifier(p)] = kp
        knobs[ObjectIdentifier(f)] = kf
    }

    private func knob(of f: PixelFrame) -> Knob? {
        if let k = knobs[ObjectIdentifier(f)] { return k }
        guard let t = knobTemplate else { return nil }
        if let k = edgeKnob(f), k.x0 == t.x0, k.x1 == t.x1, k.track == t.track, abs(k.rows.count - t.length) <= 2 * pixelScale {
            knobs[ObjectIdentifier(f)] = k
            return k
        }
        // An overlay knob (macOS) floats over the page, so its columns also hold page content: look for
        // the one run of the knob's length that all of its columns share.
        var shared: [Range<Int>]?
        for x in t.x0..<t.x1 {
            let (mode, runs) = columnRuns(f, x: x)
            guard mode == t.track[x - t.x0] else { return nil }
            let fit = runs.filter { abs($0.count - t.length) <= 2 * pixelScale && $0.lowerBound > 0 && $0.upperBound < f.height }
            shared = shared.map { s in s.filter { r in fit.contains { abs($0.lowerBound - r.lowerBound) <= 2 * pixelScale } } } ?? fit
        }
        guard let rows = shared, rows.count == 1 else { return nil }
        let k = Knob(x0: t.x0, x1: t.x1, rows: rows[0], track: t.track)
        knobs[ObjectIdentifier(f)] = k
        return k
    }

    /// Runs of rows in column x that differ from the column's commonest colour (gaps of 2 closed).
    private func columnRuns(_ f: PixelFrame, x: Int) -> (mode: UInt32, runs: [Range<Int>]) {
        let w = f.width, h = f.height
        func px(_ y: Int) -> UInt32 {
            let i = (y * w + x) * 4
            return UInt32(f.bytes[i]) << 24 | UInt32(f.bytes[i + 1]) << 16 | UInt32(f.bytes[i + 2]) << 8 | UInt32(f.bytes[i + 3])
        }
        var counts: [UInt32: Int] = [:]
        for y in 0..<h { counts[px(y), default: 0] += 1 }
        let mode = counts.max { $0.value < $1.value }!.key
        func near(_ a: UInt32) -> Bool {
            for s in [24, 16, 8] where abs(Int((a >> UInt32(s)) & 0xff) - Int((mode >> UInt32(s)) & 0xff)) > 3 { return false }
            return true
        }
        var runs: [Range<Int>] = []
        for y in 0..<h where !near(px(y)) {
            if let r = runs.last, y - r.upperBound <= 2 * pixelScale { runs[runs.count - 1] = r.lowerBound..<(y + 1) } else { runs.append(y..<(y + 1)) }
        }
        return (mode, runs)
    }

    /// The macOS overlay knob: in a few adjacent columns at the right edge, a run that moved a little the
    /// way the content went but not with it, the same in all of them. Content runs in those columns
    /// (moved by exactly d) and pinned things (not moved) are left alone.
    private func learnOverlayKnob(_ p: PixelFrame, _ f: PixelFrame, d: Int) {
        let w = f.width, band = 16 * pixelScale
        guard w > band * 4 else { return }
        var cand: [(x: Int, rows: Range<Int>, mode: UInt32)] = []
        for x in (w - band)..<w {
            let (mp, rp) = columnRuns(p, x: x), (mf, rf) = columnRuns(f, x: x)
            guard mp == mf else { continue }
            for r in rf where r.count >= 8 * pixelScale && r.count <= f.height * 6 / 10 && r.lowerBound > 0 && r.upperBound < f.height {
                let content = rp.contains { abs($0.lowerBound - (r.lowerBound + d)) <= pixelScale && abs($0.count - r.count) <= 2 * pixelScale }
                guard !content, let q = rp.first(where: { abs($0.count - r.count) <= 2 * pixelScale && $0.lowerBound != r.lowerBound
                    && ($0.lowerBound < r.lowerBound) == (d > 0) && abs(r.lowerBound - $0.lowerBound) < max(4 * pixelScale, abs(d) / 2) }) else { continue }
                _ = q
                cand.append((x, r, mf))
            }
        }
        // The columns that share one such run, side by side.
        guard let seed = cand.first else { return }
        let group = cand.filter { abs($0.rows.lowerBound - seed.rows.lowerBound) <= 2 * pixelScale && abs($0.rows.count - seed.rows.count) <= 2 * pixelScale }
        let xs = group.map(\.x).sorted()
        guard xs.count >= 3 * pixelScale, xs.count <= 12 * pixelScale, xs.last! - xs.first! + 1 == xs.count,
              cand.count == group.count else { return }
        let rows = group.map(\.rows.lowerBound).min()!..<group.map(\.rows.upperBound).max()!
        let k = Knob(x0: xs.first!, x1: xs.last! + 1, rows: rows, track: group.sorted { $0.x < $1.x }.map(\.mode))
        knobTemplate = (k.x0, k.x1, rows.count, k.track)
        knobs[ObjectIdentifier(f)] = k
    }

    // MARK: - Analysis

    /// Finds the band that changed between two frames. Nil when nothing changed.
    private func analyze(_ p: PixelFrame, _ f: PixelFrame) -> PairAnalysis? {
        let w = p.width, h = p.height
        let rowThreshold = max(3 * pixelScale, w / 300)
        var rowChanged = [Bool](repeating: false, count: h)
        var colChanged = [Bool](repeating: false, count: w)
        let tol = channelTolerance

        p.bytes.withUnsafeBufferPointer { pb in
            f.bytes.withUnsafeBufferPointer { fb in
                for y in 0..<h {
                    var count = 0
                    var i = y * w * 4
                    for x in 0..<w {
                        if abs(Int(pb[i]) - Int(fb[i])) > tol
                            || abs(Int(pb[i + 1]) - Int(fb[i + 1])) > tol
                            || abs(Int(pb[i + 2]) - Int(fb[i + 2])) > tol {
                            count += 1
                            colChanged[x] = true
                        }
                        i += 4
                    }
                    rowChanged[y] = count > rowThreshold
                }
            }
        }

        guard let first = rowChanged.firstIndex(of: true),
              let last = rowChanged.lastIndex(of: true),
              let x0 = colChanged.firstIndex(of: true),
              let x1 = colChanged.lastIndex(of: true) else { return nil }
        // A sliver of change (a scrollbar knob fading, a blinking dot) is not scrolling.
        if x1 + 1 - x0 < max(24 * pixelScale, w / 20) { return nil }
        return PairAnalysis(top: first, footer: h - 1 - last, x0: x0, x1: x1 + 1)
    }

    /// Scroll distance d such that row y of `f` equals row y + d of `p`.
    ///
    /// The moving band is cut into vertical strips that vote and verify independently,
    /// so a narrow column that changes on its own (an overlay scrollbar knob, a blinking
    /// avatar in a sidebar) spoils one strip instead of every row.
    ///
    /// With a `window` (the expected shift ± tolerance), only shifts inside it are considered,
    /// every one of them is tried if the hash vote finds none, and the result must still be the
    /// only place inside the window where the frames line up.
    private func findShift(_ p: PixelFrame, _ f: PixelFrame, _ a: PairAnalysis, window: ClosedRange<Int>? = nil, ambiguous: inout Bool) -> Placement? {
        let body = a.top..<(p.height - a.footer)
        guard body.count >= minimumOverlap * 2 else { return nil }

        let textured = texturedStrips(p, f, body: body, x0: a.x0, x1: a.x1)
        guard !textured.isEmpty else { return nil }

        // A strip whose detailed rows still line up unmoved is static (a sidebar, a side
        // panel): it says nothing about the scroll and must not outvote the column that moved.
        let moving = textured.filter { !isStatic(p, f, body: body, ph: $0.ph, fh: $0.fh, x0: $0.strip.lowerBound, x1: $0.strip.upperBound) }
        if moving.isEmpty {
            return window.map { $0.contains(0) } ?? true ? Placement(d: 0, cleanTop: body.lowerBound, cleanBottom: body.upperBound) : nil
        }
        let strips = moving.map(\.strip)
        let votes = hashVotes(moving)

        let ranked = votes.sorted { $0.value > $1.value }
        if let window {
            // Local alignment around the expected shift. Hash candidates first; if none of them
            // holds up, every shift in the window. Two separate places that both line up mean
            // the estimate cannot tell look-alike bubbles apart: reject.
            let lo = max(window.lowerBound, -(body.count - 1)), hi = min(window.upperBound, body.count - 1)
            guard lo <= hi else { return nil }
            var found = ranked.filter { $0.value >= 3 && (lo...hi).contains($0.key) }
                .compactMap { verify(p, f, body: body, d: $0.key, strips: strips) }
            if found.isEmpty { found = (lo...hi).compactMap { verify(p, f, body: body, d: $0, strips: strips) } }
            guard let best = found.max(by: { (votes[$0.d] ?? 0) < (votes[$1.d] ?? 0) }) else { return nil }
            if found.contains(where: { abs($0.d - best.d) > 2 }) { ambiguous = true; return nil }
            return best
        }
        // Chat bubbles look alike: if two distant shifts both verify, either could be wrong.
        let verified = ranked.prefix(4).filter { $0.value >= 3 }.compactMap { verify(p, f, body: body, d: $0.key, strips: strips) }
        if let m = verified.first {
            if verified.contains(where: { abs($0.d - m.d) > 3 }) { ambiguous = true; return nil }
            return m
        }
        // Fallback for near-identical rows (antialiasing, subpixel scroll): coarse profile search.
        // Its runners-up must not line up as well: repeating content fits several shifts, and the
        // fades can make one of them look cheaper than the others.
        let profile = profileSearch(p, f, body: body, a: a)
        if let d = profile.best, let m = verify(p, f, body: body, d: d, strips: strips) {
            if profile.rivals.contains(where: { verify(p, f, body: body, d: $0, strips: strips) != nil }) { ambiguous = true; return nil }
            return m
        }
        return nil
    }

    /// Second try for a frame nothing else could place: the page scrolled by d, and at the same time a
    /// block of it changed (an ad filled its slot or emptied, a carousel turned). Row by row, the overlap
    /// must agree at d except in such blocks; the agreeing rows must be many and mostly the same picture
    /// to the pixel (in rows that occur once), and d the only candidate that does so. The image is cut
    /// back to where the first changed block starts and goes on with the new frame from there.
    private func findShiftWithChanges(_ p: PixelFrame, _ f: PixelFrame, _ a: PairAnalysis, seam: Int, window: ClosedRange<Int>?) -> Placement? {
        let body = a.top..<(p.height - a.footer)
        guard body.count >= minimumOverlap * 2 else { return nil }
        let moving = movingStrips(p, f, body: body, x0: a.x0, x1: a.x1)
        guard !moving.isEmpty else { return nil }
        let strips = moving.map(\.strip)
        let ranked = hashVotes(moving).filter { $0.value >= 3 && $0.key != 0 }.sorted { $0.value > $1.value }.map(\.key)
        var candidates = ranked
        if let window, ranked.contains(where: { window.contains($0) }) { candidates = ranked.filter { window.contains($0) } }
        let found = candidates.prefix(6).compactMap { verifyWithChanges(p, f, body: body, d: $0, strips: strips, seam: seam) }
        guard let best = found.first, !found.contains(where: { abs($0.d - best.d) > 3 }) else { return nil }
        return best
    }

    private func verifyWithChanges(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, d: Int, strips: [Range<Int>], seam: Int) -> Placement? {
        guard body.count - abs(d) >= requiredOverlap(body) else { return nil }
        let lo = max(body.lowerBound, body.lowerBound - d), hi = min(body.upperBound, body.upperBound - d)
        let allowance = min(body.count / 5, (hi - lo) / 3)
        // Per row: does it agree at d in most of the strips that have something in it?
        // A disagreeing row that is the same picture where it stands in both frames is something pinned to
        // the view (a sticky header or ad bar, a panel): not a change of the content, never cut back to.
        var agree: [Int] = [], changed: [Int] = [], pinned: [Int] = []
        for fy in lo..<hi {
            var voting = 0, ok = 0, still = 0
            for s in strips {
                if isFlat(f, row: fy, x0: s.lowerBound, x1: s.upperBound) && isFlat(p, row: fy + d, x0: s.lowerBound, x1: s.upperBound) { continue }
                voting += 1
                if rowsMatch(p, py: fy + d, f, fy: fy, x0: s.lowerBound, x1: s.upperBound) { ok += 1 }
                else if stillRow(p, f, row: fy, x0: s.lowerBound, x1: s.upperBound) { still += 1 }
            }
            guard voting > 0 else { continue }
            if Double(ok) >= Double(voting) * 0.6 { agree.append(fy) }
            else if Double(ok + still) >= Double(voting) * 0.6 && still > 0 { pinned.append(fy) }
            else { changed.append(fy) }
        }
        let edge = (changed + pinned).sorted()
        // Disagreement running from either edge of the overlap (within the allowance) is the usual fades
        // and pinned buttons; anything else is a change. Clean rows of the new frame start after the top
        // fade, found strictly as elsewhere. The run of disagreeing rows from the top edge (gaps of 2):
        var top = lo
        for fy in edge where fy >= top { if fy - top <= 2 { top = fy + 1 } else { break } }
        // A sticky bar pinned to the top of the view (an ad bar, a header): a run of rows that are the same
        // picture where they stand in both frames, starting at most a few rows below the top. It is not a
        // change to cut back to (that would paste the bar into the image); clean rows start below it.
        // Rows flat in both frames say nothing and do not end the bar; agreeing rows do.
        let agreeSet = Set(agree), pinnedSet = Set(pinned)
        var barEnd = lo, barPinned = 0, barChanged = 0, agreeRun = 0
        for fy in lo..<hi {
            if agreeSet.contains(fy) {
                agreeRun += 1
                if agreeRun > (barPinned + barChanged == 0 ? 8 * pixelScale : 2) { break }
                continue
            }
            agreeRun = 0
            if pinnedSet.contains(fy) { barPinned += 1; barEnd = fy + 1 }
            else if edge.contains(fy) { barChanged += 1; barEnd = fy + 1 }
        }
        let stickyTop = barPinned >= 8 && barPinned >= 4 * barChanged && barEnd > top
        if stickyTop { top = barEnd }
        let changes = edge
        if top > lo + allowance && !stickyTop {
            // The change itself reaches the top edge (no fade is that tall). The new frame cannot say what
            // lies above it, so it must end well above the seam and stay as written; clean rows follow it.
            guard top <= seam - d - 2 * minimumOverlap else { return nil }
        }
        var floor = hi
        for fy in edge.reversed() where floor - fy <= 3 { if fy >= hi - allowance || floor < hi - allowance { floor = fy } else { break } }
        // A run of disagreement from the bottom edge taller than the allowance: something now covers the
        // bottom of the view (a panel that just appeared). It is not a change to cut back to; writing from
        // this frame stops where it starts (cleanBottom).
        let firstChange = changes.first(where: { $0 >= top && $0 < floor })
        guard firstChange != nil || top > lo + allowance || floor < hi - allowance else { return nil } // nothing changed: not this case
        guard top < (firstChange ?? floor) else { return nil }
        if top <= lo + allowance || stickyTop { for fy in top..<min(firstChange ?? floor, top + allowance) where !strips.allSatisfy({ rowsMatch(p, py: fy + d, f, fy: fy, x0: $0.lowerBound, x1: $0.upperBound, tolerance: strictTolerance) }) { top = fy + 1 } }
        // A fade that runs straight into the change is fine: writing starts at the change then.
        guard top <= (firstChange ?? floor - 1) else { return nil }
        let agreeing = agree.filter { $0 >= top }
        guard agreeing.count >= requiredOverlap(body) / 2,
              exactSupport(p, f, body: body, rows: agreeing, d: d, strips: strips) else { return nil }
        var m = Placement(d: d, cleanTop: top, cleanBottom: floor)
        m.cut = firstChange
        return m
    }

    /// Third try: a window pinned over part of the view (a sign-in prompt in a corner) spoils the strips
    /// under it for the whole overlap. For each candidate shift, find that window (still, detailed,
    /// bounded) and verify with the strips clear of it only; at least three of them, pixel-identical
    /// support as for the other fallbacks, and one candidate only.
    private func findShiftBesidePinned(_ p: PixelFrame, _ f: PixelFrame, _ a: PairAnalysis, window: ClosedRange<Int>?) -> Placement? {
        let body = a.top..<(p.height - a.footer)
        guard body.count >= minimumOverlap * 2 else { return nil }
        let moving = movingStrips(p, f, body: body, x0: a.x0, x1: a.x1)
        guard !moving.isEmpty else { return nil }
        let ranked = hashVotes(moving).filter { $0.value >= 3 && $0.key != 0 }.sorted { $0.value > $1.value }.map(\.key)
        var candidates = ranked
        if let window, ranked.contains(where: { window.contains($0) }) { candidates = ranked.filter { window.contains($0) } }
        var found: [Placement] = []
        for d in candidates.prefix(6) {
            guard let pin = pinnedRect(p, f, body: body, d: d) else { continue }
            let clear = moving.map(\.strip).filter { s in max(0, min(s.upperBound, pin.cols.upperBound) - max(s.lowerBound, pin.cols.lowerBound)) * 2 < s.count }
            guard clear.count >= 3, let m = verify(p, f, body: body, d: d, strips: clear) else { continue }
            let hi = min(body.upperBound, body.upperBound - d)
            guard exactSupport(p, f, body: body, rows: Array(m.cleanTop..<max(m.cleanTop, min(hi, m.cleanBottom))), d: d, strips: clear) else { continue }
            found.append(m)
        }
        guard let best = found.first, !found.contains(where: { abs($0.d - best.d) > 3 }) else { return nil }
        return best
    }

    /// The box of a window pinned over part of the view: blocks with detail that are the same picture
    /// where they stand in both frames, although the content moved by d. Only a bounded box counts (less
    /// than 60% of the width and 70% of the moving rows): a sidebar that runs the full height is content.
    private func pinnedRect(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, d: Int) -> (rows: Range<Int>, cols: Range<Int>)? {
        let w = f.width, bs = 8 * pixelScale
        guard body.count > 4 * bs else { return nil }
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, hits = 0
        f.bytes.withUnsafeBufferPointer { fb in
            p.bytes.withUnsafeBufferPointer { pb in
                for by in stride(from: body.lowerBound, to: body.upperBound - bs, by: bs) {
                    for bx in stride(from: 0, to: w - bs, by: bs) {
                        var lo = 255, hi = 0, still = true, moved = false
                        // Only where the old frame shows where the content went can "still" be told from "content".
                        guard by + d >= 0, by + d + bs <= body.upperBound else { continue }
                        for y in by..<(by + bs) where still {
                            for x in bx..<(bx + bs) {
                                let i = (y * w + x) * 4
                                let g = Int(fb[i + 1])
                                lo = min(lo, g); hi = max(hi, g)
                                if abs(Int(fb[i]) - Int(pb[i])) > 4 || abs(g - Int(pb[i + 1])) > 4 || abs(Int(fb[i + 2]) - Int(pb[i + 2])) > 4 { still = false; break }
                                if !moved {
                                    let j = ((y + d) * w + x) * 4
                                    if abs(Int(fb[i]) - Int(pb[j])) > 24 || abs(g - Int(pb[j + 1])) > 24 || abs(Int(fb[i + 2]) - Int(pb[j + 2])) > 24 { moved = true }
                                }
                            }
                        }
                        guard still, hi - lo > 40, moved else { continue }
                        hits += 1
                        minX = min(minX, bx); maxX = max(maxX, bx + bs); minY = min(minY, by); maxY = max(maxY, by + bs)
                    }
                }
            }
        }
        guard hits >= 6 else { return nil }
        let cols = max(0, minX - bs)..<min(w, maxX + bs)
        // Below the checkable part the window goes on as long as its rows stay the same picture.
        var bottomRow = min(body.upperBound, maxY + bs)
        while bottomRow < body.upperBound, rowsMatch(p, py: bottomRow, f, fy: bottomRow, x0: cols.lowerBound, x1: cols.upperBound, tolerance: strictTolerance) { bottomRow += 1 }
        let rows = max(body.lowerBound, minY - bs)..<bottomRow
        guard cols.count * 10 < w * 6, rows.count * 10 < body.count * 7 else { return nil }
        return (rows, cols)
    }

    /// A shift other than `d` (more than 3 rows away) with clearly more rows identical to the pixel in the
    /// overlap, among the hash vote's candidates.
    private func strongerRival(_ p: PixelFrame, _ f: PixelFrame, _ a: PairAnalysis, than d: Int) -> Int? {
        let body = a.top..<(p.height - a.footer)
        let moving = movingStrips(p, f, body: body, x0: a.x0, x1: a.x1)
        guard !moving.isEmpty else { return nil }
        let rivals = hashVotes(moving).filter { $0.value >= 3 && abs($0.key - d) > 3 }.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        guard !rivals.isEmpty else { return nil }
        func exactRows(_ s: Int) -> Int {
            var rows = Set<Int>()
            for t in moving {
                var pc: [UInt64: Int] = [:], fc: [UInt64: Int] = [:]
                for h in t.ph { if let h { pc[h, default: 0] += 1 } }
                for h in t.fh { if let h { fc[h, default: 0] += 1 } }
                for (i, h) in t.fh.enumerated() {
                    let j = i + s
                    guard let h, fc[h] == 1, j >= 0, j < t.ph.count, let g = t.ph[j], g == h, pc[g] == 1 else { continue }
                    rows.insert(i)
                }
            }
            return rows.count
        }
        let own = exactRows(d)
        let best = rivals.map { ($0, exactRows($0)) }.max { $0.1 < $1.1 }!
        return best.1 >= max(2 * minimumOverlap, requiredOverlap(body) / 4) && Double(best.1) > Double(own) * 1.3 + 8 ? best.0 : nil
    }

    /// The row is the same picture where it stands in both frames, give or take a scroll bar knob's width
    /// (an overlay knob is drawn over pinned bars too and moves on its own).
    private func stillRow(_ p: PixelFrame, _ f: PixelFrame, row y: Int, x0: Int, x1: Int) -> Bool {
        var off = 0
        let w = f.width, allowed = 12 * pixelScale
        for x in x0..<x1 {
            let i = (y * w + x) * 4
            if abs(Int(f.bytes[i]) - Int(p.bytes[i])) > 4 || abs(Int(f.bytes[i + 1]) - Int(p.bytes[i + 1])) > 4 || abs(Int(f.bytes[i + 2]) - Int(p.bytes[i + 2])) > 4 {
                off += 1
                if off > allowed { return false }
            }
        }
        return true
    }

    /// At least half of the detailed rows of `rows` that occur once in their strip are the same picture
    /// to the pixel at shift `d`, and there are plenty of them, on many different rows: a real scroll moves pixels exactly, while
    /// tolerant matching lets smooth areas (a photo, a gradient) line up at shifts near the true one.
    private func exactSupport(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, rows band: [Int], d: Int, strips: [Range<Int>]) -> Bool {
        var exact = 0, detailed = 0
        var exactRows = Set<Int>()
        for s in strips where !band.isEmpty {
            let ph = rowHashes(p, rows: body, x0: s.lowerBound, x1: s.upperBound)
            let fh = rowHashes(f, rows: body, x0: s.lowerBound, x1: s.upperBound)
            var pc: [UInt64: Int] = [:], fc: [UInt64: Int] = [:]
            for h in ph { if let h { pc[h, default: 0] += 1 } }
            for h in fh { if let h { fc[h, default: 0] += 1 } }
            for fy in band where body.contains(fy) && body.contains(fy + d) {
                guard let a = fh[fy - body.lowerBound], fc[a] == 1 else { continue }
                detailed += 1
                if let b = ph[fy + d - body.lowerBound], a == b, pc[b] == 1 { exact += 1; exactRows.insert(fy) }
            }
        }
        // And spread over many rows: one element that moved on its own (an ad drawn a frame late) can
        // be pixel-identical at a wrong shift in all its strips, but only over its own few rows.
        return exact >= 2 * minimumOverlap && exact * 2 >= detailed && exactRows.count >= max(2 * minimumOverlap, requiredOverlap(body) / 4)
    }

    /// Nothing scrolled, a picture changed in place (an image or an ad loading). The caller rewrites the
    /// rows of it already in the image. Accepted only when:
    /// - the changed rows lie inside the rows the last real scroll saw move, so a banner pinned over the
    ///   bottom (unchanged while everything above it scrolls away) cannot pass for still content;
    /// - those moving rows outside the change hold plenty of unchanged detail, which a scroll would move;
    /// - the changed rows do not show up anywhere else in the old picture at another shift.
    /// Before the first placement nothing is known to scroll, so nothing passes.
    private func changedInPlace(_ p: PixelFrame, _ f: PixelFrame, _ a: PairAnalysis, seam: Int) -> Bool {
        let band = a.top..<(p.height - a.footer)
        guard started, let moved = movedBody, band.count >= 1,
              // A few rows of slack: the moving band's edge rows can sit still in the scroll that measured it.
              band.lowerBound >= moved.lowerBound - 8 * pixelScale, band.upperBound <= moved.upperBound + 8 * pixelScale else { return false }
        var detail = 0
        for y in moved where !band.contains(y) && !isFlat(p, row: y, x0: 0, x1: p.width) { detail += 1 }
        guard detail >= max(2 * minimumOverlap, moved.count / 5) else { return false }
        let whole = 0..<p.height
        let strips = texturedStrips(p, f, body: whole, x0: a.x0, x1: a.x1)
        return !regionMoved(p, f, body: whole, rows: band, strips: strips)
    }

    /// Whether `rows` of `f` show content of `p` at some other shift than 0.
    private func regionMoved(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, rows: Range<Int>, strips: [(strip: Range<Int>, ph: [UInt64?], fh: [UInt64?])]) -> Bool {
        guard rows.count > 0 else { return false }
        var votes: [Int: Int] = [:]
        for t in strips {
            var lookup: [UInt64: Int] = [:]
            for (i, h) in t.ph.enumerated() { guard let h else { continue }; lookup[h] = lookup[h] == nil ? i : -1 }
            for y in rows {
                guard let h = t.fh[y - body.lowerBound], let j = lookup[h], j >= 0 else { continue }
                let d = j - (y - body.lowerBound)
                if d != 0 { votes[d, default: 0] += 1 }
            }
        }
        for (d, _) in votes.filter({ $0.value >= 3 }).sorted(by: { $0.value > $1.value }).prefix(4) {
            var compared = 0, matched = 0
            for y in rows where body.contains(y + d) {
                for t in strips {
                    let x0 = t.strip.lowerBound, x1 = t.strip.upperBound
                    if isFlat(f, row: y, x0: x0, x1: x1) && isFlat(p, row: y + d, x0: x0, x1: x1) { continue }
                    compared += 1
                    if rowsMatch(p, py: y + d, f, fy: y, x0: x0, x1: x1) { matched += 1 }
                }
            }
            if compared >= 8 && Double(matched) >= Double(compared) * 0.6 { return true }
        }
        return false
    }

    /// The new frame shows the old one moved sideways by dx columns (a few, at most 16 points) and not at
    /// all up or down: the error at (0, dx) must be small, and clearly below that of no move, of a one-row
    /// move either way and of the neighbouring dx. Recentring can land between pixels, so this is a
    /// luminance error, not a pixel match; it only re-anchors, nothing of this frame is written.
    private func sideways(_ p: PixelFrame, _ f: PixelFrame) -> Int? {
        let w = p.width, h = p.height, maxDx = 16 * pixelScale, margin = 24 * pixelScale
        guard w > 2 * (margin + maxDx) + 64, h >= 64 else { return nil }
        func lum(_ fr: PixelFrame) -> [Float] {
            var out = [Float](repeating: 0, count: w * h)
            fr.bytes.withUnsafeBufferPointer { b in
                for i in 0..<(w * h) { out[i] = Float(b[i * 4]) * 0.3 + Float(b[i * 4 + 1]) * 0.59 + Float(b[i * 4 + 2]) * 0.11 }
            }
            return out
        }
        let lp = lum(p), lf = lum(f)
        func err(_ dy: Int, _ dx: Int) -> Float {
            var sum: Float = 0, n = 0
            for y in stride(from: 4 + 2, to: h - 4 - 2, by: 2) {
                let fy = y * w, py = (y + dy) * w
                for x in stride(from: margin + maxDx, to: w - margin - maxDx, by: 2) {
                    sum += abs(lf[fy + x] - lp[py + x - dx]); n += 1
                }
            }
            return sum / Float(max(1, n))
        }
        var best: (e: Float, dx: Int)?
        for dx in -maxDx...maxDx where dx != 0 {
            let e = err(0, dx)
            if best == nil || e < best!.e { best = (e, dx) }
        }
        guard let b = best, b.e < 4 else { return nil }
        let still = err(0, 0), up = err(-1, b.dx), down = err(1, b.dx)
        let side = min(err(0, b.dx - 1 == 0 ? b.dx - 2 : b.dx - 1), err(0, b.dx + 1 == 0 ? b.dx + 2 : b.dx + 1))
        guard still > 4 * b.e, up > 2 * b.e, down > 2 * b.e, side > 1.5 * b.e else { return nil }
        return b.dx
    }

    /// Strips with detail that did not stay put, with their row hashes over `body`.
    private func movingStrips(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, x0: Int, x1: Int) -> [(strip: Range<Int>, ph: [UInt64?], fh: [UInt64?])] {
        texturedStrips(p, f, body: body, x0: x0, x1: x1).filter { !isStatic(p, f, body: body, ph: $0.ph, fh: $0.fh, x0: $0.strip.lowerBound, x1: $0.strip.upperBound) }
    }

    /// Strips with some detail in either frame, with their row hashes over `body`.
    private func texturedStrips(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, x0: Int, x1: Int) -> [(strip: Range<Int>, ph: [UInt64?], fh: [UInt64?])] {
        var textured: [(strip: Range<Int>, ph: [UInt64?], fh: [UInt64?])] = []
        for strip in makeStrips(x0, x1) {
            let ph = rowHashes(p, rows: body, x0: strip.lowerBound, x1: strip.upperBound)
            let fh = rowHashes(f, rows: body, x0: strip.lowerBound, x1: strip.upperBound)
            if ph.compactMap({ $0 }).count >= 3 || fh.compactMap({ $0 }).count >= 3 { textured.append((strip, ph, fh)) }
        }
        return textured
    }

    private func hashVotes(_ moving: [(strip: Range<Int>, ph: [UInt64?], fh: [UInt64?])]) -> [Int: Int] {
        var votes: [Int: Int] = [:]
        for t in moving {
            var lookup: [UInt64: Int] = [:]
            for (i, h) in t.ph.enumerated() {
                guard let h else { continue }
                lookup[h] = lookup[h] == nil ? i : -1
            }
            for (i, h) in t.fh.enumerated() {
                guard let h, let j = lookup[h], j >= 0 else { continue }
                votes[j - i, default: 0] += 1
            }
        }
        return votes
    }

    /// Every shift the verifier would accept for this pair, ignoring the hash vote. Diagnostics
    /// for `replay --scan`: on real frames only the true shift (and its 1-px neighbours) may pass.
    func verifiedShifts(_ p: PixelFrame, _ f: PixelFrame) -> [Int] {
        guard let a = analyze(p, f) else { return [] }
        let body = a.top..<(p.height - a.footer)
        let strips = makeStrips(a.x0, a.x1)
        return (-(body.count - 1)..<body.count).filter { verify(p, f, body: body, d: $0, strips: strips) != nil }
    }

    /// Same for the check that allows a changed block in the overlap.
    func verifiedShiftsWithChanges(_ p: PixelFrame, _ f: PixelFrame) -> [Int] {
        guard let a = analyze(p, f) else { return [] }
        let body = a.top..<(p.height - a.footer)
        let strips = movingStrips(p, f, body: body, x0: a.x0, x1: a.x1).map(\.strip)
        guard !strips.isEmpty else { return [] }
        let seam = body.upperBound - max(minimumOverlap, body.count * 22 / 100)
        return (-(body.count - 1)..<body.count).filter { $0 != 0 && verifyWithChanges(p, f, body: body, d: $0, strips: strips, seam: seam) != nil }
    }

    private func makeStrips(_ x0: Int, _ x1: Int) -> [Range<Int>] {
        let span = x1 - x0
        let count = max(1, min(8, span / 48))
        return (0..<count).map { k in (x0 + span * k / count)..<(x0 + span * (k + 1) / count) }
    }

    private enum StripVerdict { case pass(cleanTop: Int, cleanBottom: Int), fail, abstain }

    /// Accepts d when at least 60% of the strips that have something to compare line up row for
    /// row. Strips without text in the overlap abstain instead of failing. The clean band is
    /// what every passing strip agrees is free of trimmed overlays.
    private func verify(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, d: Int, strips: [Range<Int>]) -> Placement? {
        guard body.count - abs(d) >= requiredOverlap(body) else { return nil }
        var pass = 0, voting = 0
        var top = body.lowerBound, bottom = body.upperBound
        for s in strips {
            switch verifyStrip(p, f, body: body, d: d, x0: s.lowerBound, x1: s.upperBound) {
            case .pass(let t, let b): pass += 1; voting += 1; top = max(top, t); bottom = min(bottom, b)
            case .fail: voting += 1
            case .abstain: break
            }
        }
        guard voting > 0 && Double(pass) >= Double(voting) * 0.6 else { return nil }
        return Placement(d: d, cleanTop: top, cleanBottom: max(top, bottom))
    }

    /// FNV-1a per row over [x0, x1); nil for flat rows, which say nothing about position.
    private func rowHashes(_ f: PixelFrame, rows: Range<Int>, x0: Int, x1: Int) -> [UInt64?] {
        let w = f.width
        return f.bytes.withUnsafeBufferPointer { b in
            rows.map { y -> UInt64? in
                var h: UInt64 = 0xcbf29ce484222325
                let start = (y * w + x0) * 4, end = (y * w + x1) * 4
                let r0 = b[start], g0 = b[start + 1], b0 = b[start + 2]
                var flat = true
                var i = start
                while i < end {
                    if flat && (b[i] != r0 || b[i + 1] != g0 || b[i + 2] != b0) { flat = false }
                    h = (h ^ UInt64(b[i])) &* 0x100000001b3
                    h = (h ^ UInt64(b[i + 1])) &* 0x100000001b3
                    h = (h ^ UInt64(b[i + 2])) &* 0x100000001b3
                    i += 4
                }
                return flat ? nil : h
            }
        }
    }

    /// True when at most a quarter of the rows with detail differ at zero shift.
    private func isStatic(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, ph: [UInt64?], fh: [UInt64?], x0: Int, x1: Int) -> Bool {
        var detailed = 0, differing = 0
        for (r, y) in body.enumerated() where ph[r] != nil || fh[r] != nil {
            detailed += 1
            if ph[r] != fh[r] && !rowsMatch(p, py: y, f, fy: y, x0: x0, x1: x1) { differing += 1 }
        }
        return differing * 4 <= detailed
    }

    private func rowsMatch(_ p: PixelFrame, py: Int, _ f: PixelFrame, fy: Int, x0: Int, x1: Int, tolerance: Int? = nil) -> Bool {
        let w = p.width
        let rowThreshold = max(2 * pixelScale, (x1 - x0) / 100)
        let tol = tolerance ?? channelTolerance
        var count = 0
        return p.bytes.withUnsafeBufferPointer { pb in
            f.bytes.withUnsafeBufferPointer { fb in
                var i = (fy * w + x0) * 4, j = (py * w + x0) * 4
                for _ in x0..<x1 {
                    if abs(Int(fb[i]) - Int(pb[j])) > tol
                        || abs(Int(fb[i + 1]) - Int(pb[j + 1])) > tol
                        || abs(Int(fb[i + 2]) - Int(pb[j + 2])) > tol {
                        count += 1
                        if count > rowThreshold { return false }
                    }
                    i += 4; j += 4
                }
                return true
            }
        }
    }

    private func verifyStrip(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, d: Int, x0: Int, x1: Int) -> StripVerdict {
        // Overlap in `f` rows: from the top of the new frame down to where the old one ends.
        let lo = max(body.lowerBound, body.lowerBound - d), hi = min(body.upperBound, body.upperBound - d)
        guard hi - lo >= requiredOverlap(body) else { return .fail }
        var rows: [(fy: Int, ok: Bool)] = []
        for fy in lo..<hi {
            let py = fy + d
            // Blank rows match anything; counting them lets a wrong shift pass on gaps alone.
            if isFlat(f, row: fy, x0: x0, x1: x1) && isFlat(p, row: py, x0: x0, x1: x1) { continue }
            rows.append((fy, rowsMatch(p, py: py, f, fy: fy, x0: x0, x1: x1)))
        }
        // Things fixed to the view rather than the content (a fade at the top or bottom edge, a pinned
        // button, an "N new messages" pill) sit at the view's edges. The overlap runs from the top
        // edge of the new frame to the bottom edge of the old one, so they show up as a block of
        // mismatches at either end of it. Trim each end back past its last mismatch, within an
        // allowance that leaves at least a third of the overlap; the rest must agree. A wrong shift
        // mismatches all the way through and still fails.
        let allowance = min(body.count / 5, (hi - lo) / 3)
        var start = 0, end = rows.count
        if let k = rows.lastIndex(where: { !$0.ok && $0.fy < lo + allowance }) { start = k + 1 }
        if let k = rows.firstIndex(where: { !$0.ok && $0.fy >= hi - allowance }) { end = k }
        guard end - start >= 8 else { return .abstain }
        let matched = rows[start..<end].filter(\.ok).count
        guard Double(matched) >= Double(end - start) * 0.95 else { return .fail }
        // The clean band, for writing: near either end a fade can be faint enough to pass the
        // tolerant comparison above, so the bands are found again with a strict one.
        var top = lo, bottom = hi
        // Every row counts here, flat ones too: a faded bubble background is flat but not clean.
        for fy in lo..<min(hi, lo + allowance) where !rowsMatch(p, py: fy + d, f, fy: fy, x0: x0, x1: x1, tolerance: strictTolerance) { top = fy + 1 }
        for fy in stride(from: hi - 1, through: max(lo, hi - allowance), by: -1) where !rowsMatch(p, py: fy + d, f, fy: fy, x0: x0, x1: x1, tolerance: strictTolerance) { bottom = fy }
        if top > bottom { // noisy rather than faded: fall back to the tolerant bands
            top = start > 0 ? rows[start].fy : lo
            bottom = end < rows.count ? rows[end].fy : hi
        }
        return .pass(cleanTop: top, cleanBottom: bottom)
    }

    /// Overlap a shift must leave between the two frames before it is trusted.
    private func requiredOverlap(_ body: Range<Int>) -> Int {
        // A step of most of a screen leaves only the edge bands overlapping, exactly where fades
        // and floating buttons live; such a frame is dropped and the user scrolls back instead.
        max(minimumOverlap, body.count / 4)
    }

    private func isFlat(_ f: PixelFrame, row y: Int, x0: Int, x1: Int) -> Bool {
        f.bytes.withUnsafeBufferPointer { b in
            let start = (y * f.width + x0) * 4, end = (y * f.width + x1) * 4
            var i = start + 4
            while i < end {
                if abs(Int(b[i]) - Int(b[start])) > channelTolerance
                    || abs(Int(b[i + 1]) - Int(b[start + 1])) > channelTolerance
                    || abs(Int(b[i + 2]) - Int(b[start + 2])) > channelTolerance { return false }
                i += 4
            }
            return true
        }
    }

    /// Per-row luminance profile in four column bins, matched by mean absolute difference.
    private func profileSearch(_ p: PixelFrame, _ f: PixelFrame, body: Range<Int>, a: PairAnalysis) -> (best: Int?, rivals: [Int]) {
        let bins = 4
        func profile(_ fr: PixelFrame) -> [Float] {
            let w = fr.width, span = a.x1 - a.x0
            var out = [Float](repeating: 0, count: body.count * bins)
            fr.bytes.withUnsafeBufferPointer { b in
                for (r, y) in body.enumerated() {
                    for x in a.x0..<a.x1 {
                        let i = (y * w + x) * 4
                        let lum = Float(b[i]) * 0.3 + Float(b[i + 1]) * 0.59 + Float(b[i + 2]) * 0.11
                        out[r * bins + min(bins - 1, (x - a.x0) * bins / span)] += lum
                    }
                }
            }
            return out
        }
        let pp = profile(p), fp = profile(f)
        let n = body.count
        var costs: [(d: Int, cost: Float)] = []
        for d in -(n - minimumOverlap)...(n - minimumOverlap) {
            var cost: Float = 0
            var rows = 0
            for r in max(0, -d)..<min(n, n - d) {
                let q = r + d
                for k in 0..<bins { cost += abs(fp[r * bins + k] - pp[q * bins + k]) }
                rows += 1
            }
            guard rows >= minimumOverlap else { continue }
            costs.append((d, cost / Float(rows)))
        }
        guard let best = costs.min(by: { $0.cost < $1.cost }) else { return (nil, []) }
        // Repeating content (identical rows, ruled lines) fits several distant shifts about
        // equally well; picking one would silently stitch the wrong rows.
        let others = costs.filter { abs($0.d - best.d) > 3 }
        let rival = others.map(\.cost).min() ?? .infinity
        if rival <= best.cost * 1.05 + 0.5 { return (nil, []) }
        // Local minima of the cost, cheapest first: where a repeat of the content would sit.
        let minima = others.indices.filter { i in
            (i == 0 || others[i - 1].cost >= others[i].cost) && (i == others.count - 1 || others[i + 1].cost >= others[i].cost)
        }.map { others[$0] }.sorted { $0.cost < $1.cost }.prefix(4).map(\.d)
        return (best.d, Array(minima))
    }
}

private extension Array {
    func repeated(_ times: Int) -> [Element] {
        var out: [Element] = []
        out.reserveCapacity(count * times)
        for _ in 0..<times { out.append(contentsOf: self) }
        return out
    }
}












