import CoreGraphics
import Foundation
import PDFKit

/// `LivingScrollPDF selftest`: feeds synthetic chat-like frames (sticky header, sticky input box
/// with a blinking cursor, blank gaps between messages, uneven and backwards scrolling)
/// through the stitcher and checks the result pixel for pixel.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
            if !ok { failures += 1 }
        }

        let w = 320, header = 40, footer = 60, bodyH = 400, contentH = 3200
        let content = makeContent(width: w, height: contentH)
        let headerRows = solid(width: w, height: header, rgb: (40, 80, 160), seed: 7)
        let footerRows = solid(width: w, height: footer, rgb: (235, 235, 240), seed: 9)

        func frame(offset: Int, cursor: Bool, knobDelta: Int = 0, cursorWidth: Int = 2, source: [UInt8]? = nil) -> PixelFrame {
            var bytes = headerRows
            let pixels = source ?? content
            var body = Array(pixels[(offset * w * 4)..<((offset + bodyH) * w * 4)])
            // Overlay scrollbar knob that moves on its own, like macOS draws it.
            let knob = offset * (bodyH - 60) / (contentH - bodyH) + knobDelta
            for y in knob..<(knob + 60) { for x in (w - 8)..<(w - 2) { let i = (y * w + x) * 4; body[i] = 120; body[i + 1] = 120; body[i + 2] = 120 } }
            // Floating "jump to latest" button over the content, plus transparent rounded corners.
            for y in (bodyH - 50)..<(bodyH - 26) { for x in 250..<290 { let i = (y * w + x) * 4; body[i] = 30; body[i + 1] = 160; body[i + 2] = 90 } }
            for y in (bodyH - 6)..<bodyH { for x in 0..<(6 - (bodyH - y)) { let i = (y * w + x) * 4; body[i] = 0; body[i + 1] = 0; body[i + 2] = 0; body[i + 3] = 0 } }
            bytes += body
            var foot = footerRows
            if cursor { // cursor in the input box
                for y in 20..<40 { for x in 30..<(30 + cursorWidth) { let i = (y * w + x) * 4; foot[i] = 0; foot[i + 1] = 0; foot[i + 2] = 0 } }
            }
            bytes += foot
            return PixelFrame(width: w, height: header + bodyH + footer, bytes: bytes)
        }

        // 1. Normal session: uneven steps, a pause, a step back up, then to the end.
        // Steps keep at least a quarter of the view overlapping; bigger jumps are dropped on purpose (case 2).
        let offsets = [0, 0, 37, 120, 120, 260, 230, 400, 555, 556, 700, 1000, 1300, 1301, 1590, 1820, 2000, 2280, 2560, 2800]
        let s = Stitcher()
        for (k, o) in offsets.enumerated() { let r = s.add(frame(offset: o, cursor: k % 3 == 0)); if ProcessInfo.processInfo.environment["JZ_DEBUG"] != nil { print("  offset \(o): \(r)") } }
        let cursorLast = (offsets.count - 1) % 3 == 0
        let last = offsets.last!
        guard let img = s.finish(), let out = PixelFrame(cgImage: img) else {
            check("stitch produced an image", false); return 1
        }
        let expectedRows = header + last + bodyH + footer
        check("height", out.height == expectedRows, "got \(out.height), want \(expectedRows)")
        check("nothing dropped", s.lostFrames == 0, "lost=\(s.lostFrames)")
        if out.height == expectedRows {
            // Content once, then the last frame as it looked (button, corners and footer once).
            var expected = headerRows
            expected += content[0..<(last * w * 4)]
            expected += frame(offset: last, cursor: cursorLast).bytes.suffix((bodyH + footer) * w * 4)
            // The scrollbar column legitimately differs; everything left of it must match exactly.
            let firstBad = zip(out.bytes, expected).enumerated().first {
                ($0.offset / 4) % w < w - 12 && $0.element.0 != $0.element.1
            }?.offset
            check("pixels identical (excluding scrollbar)", firstBad == nil, firstBad.map { "first diff at row \($0 / (w * 4))" } ?? "")
        }

        // 2. A jump bigger than the visible body is dropped, never pasted in: the image stops at
        // the last placed frame and nothing repeats.
        let s2 = Stitcher()
        for o in [0, 100, 900, 1000] { _ = s2.add(frame(offset: o, cursor: false)) }
        let jumped = s2.finish()
        check("too-fast jump dropped, not pasted", s2.lostFrames == 2 && jumped?.height == header + 100 + bodyH + footer,
              "lost=\(s2.lostFrames) height=\(jumped?.height ?? 0)")

        // 2b. After scrolling too far, scrolling back into overlap reconnects seamlessly.
        let s2b = Stitcher()
        let back2 = [0, 100, 900, 950, 200, 300, 450]
        for o in back2 { _ = s2b.add(frame(offset: o, cursor: false)) }
        if let img = s2b.finish(), let out = PixelFrame(cgImage: img) {
            var expected = headerRows
            expected += content[0..<(450 * w * 4)]
            expected += frame(offset: 450, cursor: false).bytes.suffix((bodyH + footer) * w * 4)
            let bad = out.height != header + 450 + bodyH + footer || zip(out.bytes, expected).enumerated().contains {
                ($0.offset / 4) % w < w - 12 && $0.element.0 != $0.element.1
            }
            check("scroll back after overshoot reconnects, no repeats", !bad && s2b.lostFrames == 2, "lost=\(s2b.lostFrames) height=\(out.height)")
        } else { check("scroll back after overshoot reconnects, no repeats", false) }

        // 3. Nothing scrolled: single frame back unchanged.
        let s3 = Stitcher()
        _ = s3.add(frame(offset: 50, cursor: false))
        _ = s3.add(frame(offset: 50, cursor: false))
        let knobOnly = s3.add(frame(offset: 50, cursor: false, knobDelta: 25))
        check("scrollbar-only change ignored", knobOnly == .unchanged, "\(knobOnly)")
        let one = s3.finish()
        check("static capture = one frame", one?.height == header + bodyH + footer)

        // 4. Scrolling back up and stopping there keeps everything that was seen further down.
        let s4 = Stitcher()
        for o in [0, 100, 200, 100] { _ = s4.add(frame(offset: o, cursor: false)) }
        let back = s4.finish()
        check("scroll back then finish keeps the tail", back?.height == header + 200 + bodyH + footer, "got \(back?.height ?? 0)")

        // 5. Retina: a 4-px blinking cursor is still noise, not motion.
        let s5 = Stitcher()
        s5.pixelScale = 2
        for (k, o) in offsets.enumerated() { _ = s5.add(frame(offset: o, cursor: k % 2 == 0, cursorWidth: 4)) }
        let retina = s5.finish()
        check("2x cursor: nothing dropped", s5.lostFrames == 0 && retina?.height == expectedRows, "lost=\(s5.lostFrames) height=\(retina?.height ?? 0)")

        // 6. Wide static sidebar with an animated avatar; only the right column scrolls.
        let sw = 800, col = 200, colContent = makeContent(width: col, height: 2000)
        let sidebar = makeContent(width: sw - col, height: bodyH)
        func split(offset: Int, tick: Int) -> PixelFrame {
            var bytes = [UInt8](repeating: 0, count: sw * bodyH * 4)
            for y in 0..<bodyH {
                for x in 0..<sw {
                    let i = (y * sw + x) * 4
                    let src = x < sw - col ? sidebar[(y * (sw - col) + x) * 4..<(y * (sw - col) + x) * 4 + 4]
                                           : colContent[((y + offset) * col + x - (sw - col)) * 4..<((y + offset) * col + x - (sw - col)) * 4 + 4]
                    bytes.replaceSubrange(i..<(i + 4), with: src)
                }
            }
            for y in 20..<50 { for x in 20..<50 { let i = (y * sw + x) * 4; bytes[i] = UInt8((tick * 70 + x) % 256); bytes[i + 1] = 90; bytes[i + 2] = 40 } }
            return PixelFrame(width: sw, height: bodyH, bytes: bytes)
        }
        let s6 = Stitcher()
        let colOffsets = [0, 30, 60, 90, 150, 210, 300]
        for (k, o) in colOffsets.enumerated() { _ = s6.add(split(offset: o, tick: k)) }
        let side = s6.finish()
        check("static sidebar does not swallow scrolling", s6.lostFrames == 0 && side?.height == bodyH + colOffsets.last!, "lost=\(s6.lostFrames) height=\(side?.height ?? 0)")

        // 7. Repeating content must not be matched to a wrong, distant shift.
        var periodic = [UInt8](repeating: 255, count: w * 1200 * 4)
        var rng = SplitMix(seed: 5)
        let tile = (0..<(w * 20 * 4)).map { _ in UInt8(rng.next() % 200) }
        for y in 0..<1200 { for b in 0..<(w * 4) { periodic[y * w * 4 + b] = tile[(y % 20) * w * 4 + b] } }
        func rep(_ o: Int) -> PixelFrame { PixelFrame(width: w, height: bodyH, bytes: Array(periodic[(o * w * 4)..<((o + bodyH) * w * 4)])) }
        let s7 = Stitcher()
        for o in [0, 15] { _ = s7.add(rep(o)) }
        let per = s7.finish()
        check("repeating content: correct or dropped, never wrong", per?.height == bodyH || per?.height == bodyH + 15, "lost=\(s7.lostFrames) height=\(per?.height ?? 0)")

        // 7b. Web chats fade the top of the scroll view: the same text is lighter near the top
        // edge. That band must not stop frames from lining up.
        func faded(_ o: Int) -> PixelFrame {
            let f = frame(offset: o, cursor: false)
            var b = f.bytes
            for y in header..<(header + 36) {
                let keep = Double(y - header) / 36
                for x in 0..<w { let i = (y * w + x) * 4; for c in 0..<3 { b[i + c] = UInt8(Double(b[i + c]) * keep + 255 * (1 - keep)) } }
            }
            return PixelFrame(width: w, height: f.height, bytes: b)
        }
        let s8 = Stitcher()
        let fadeOffsets = [0, 90, 200, 330, 470, 600, 760, 900]
        for o in fadeOffsets { _ = s8.add(faded(o)) }
        let fadeImg = s8.finish()
        check("top fade band: nothing dropped", s8.lostFrames == 0 && fadeImg?.height == header + fadeOffsets.last! + bodyH + footer,
              "lost=\(s8.lostFrames) height=\(fadeImg?.height ?? 0)")

        // 9. The sample that broke (Chrome, Elias chat, 2026-10-21): a top fade about a tenth of the
        // view tall, a bottom fade, a floating "N 則訊息" pill whose label changes while scrolling,
        // a pinned button top right, look-alike bubbles, and smooth-scroll in-between frames.
        let web = WebChat(width: 360, height: 480, contentHeight: 3400)
        do {
            var offsets: [Int] = [0, 0]
            var pos = 0
            // Wheel notches animated over a few captured frames, with pauses and one step back.
            for (k, target) in [120, 240, 330, 330, 470, 600, 560, 700, 840, 1000, 1150, 1300, 1460, 1600, 1760, 1900, 2050, 2200, 2350, 2500, 2650, 2800, 2920].enumerated() {
                for f in [0.18, 0.5, 0.8, 0.95, 1.0] { offsets.append(pos + Int(Double(target - pos) * f)) }
                if k % 4 == 0 { offsets.append(target) } // paused
                pos = target
            }
            let sw = Stitcher()
            for o in offsets { let r = sw.add(web.frame(offset: o)); if ProcessInfo.processInfo.environment["JZ_DEBUG"] != nil { print("  web \(o): \(r)") } }
            let last = offsets.last!
            if let img = sw.finish(), let out = PixelFrame(cgImage: img) {
                let want = last + web.height
                let clean = web.cleanRowsMatch(out, from: web.topFade, to: want - web.bottomOverlay)
                check("web chat: fades, pill, smooth scroll — nothing dropped", sw.lostFrames == 0, "lost=\(sw.lostFrames)")
                check("web chat: no repeats (exact height)", out.height == want, "got \(out.height), want \(want)")
                check("web chat: every content row once, unfaded", clean == nil, clean.map { "first bad canvas row \($0)" } ?? "")
            } else { check("web chat: image", false) }

            // Steps of half the view, as auto-scroll takes them.
            let sa = Stitcher()
            let autoOffsets = Array(stride(from: 0, through: 2900, by: 230))
            for o in autoOffsets { _ = sa.add(web.frame(offset: o)) }
            if let img = sa.finish(), let out = PixelFrame(cgImage: img) {
                let want = autoOffsets.last! + web.height
                let bad = web.cleanRowsMatch(out, from: web.topFade, to: want - web.bottomOverlay)
                check("web chat: half-view steps", sa.lostFrames == 0 && out.height == want && bad == nil,
                      "lost=\(sa.lostFrames) height=\(out.height) want=\(want) bad=\(bad.map(String.init) ?? "-")")
            } else { check("web chat: half-view steps", false) }

            // A step leaving too little overlap is dropped, then scrolling back reconnects.
            let sb = Stitcher()
            for o in [0, 200, 620, 560, 380, 520] { _ = sb.add(web.frame(offset: o)) }
            if let img = sb.finish(), let out = PixelFrame(cgImage: img) {
                let want = 520 + web.height
                let bad = web.cleanRowsMatch(out, from: web.topFade, to: want - web.bottomOverlay)
                check("web chat: overshoot dropped, scroll back reconnects", sb.lostFrames == 2 && out.height == want && bad == nil,
                      "lost=\(sb.lostFrames) height=\(out.height) want=\(want)")
            } else { check("web chat: overshoot dropped, scroll back reconnects", false) }
        }

        // 9b. The verifier on its own, over every possible shift: only the true one may pass. Text is
        // nearly two-tone, so "skip pixels that did not move on screen" would wave wrong shifts through.
        for (o, d) in [(114, 6), (300, 120), (900, 230)] {
            let got = Stitcher().verifiedShifts(web.frame(offset: o), web.frame(offset: o + d))
            check("web chat: only the true shift verifies (\(d) px)", !got.isEmpty && got.allSatisfy { abs($0 - d) <= 1 }, "\(got.prefix(12))")
        }

        // 10. Overlap holding text in one narrow bubble only: strips with nothing to compare must
        // abstain, not count as failures.
        let sparse = WebChat(width: 600, height: 400, contentHeight: 2400, sparse: true)
        do {
            let sp = Stitcher()
            let offs = [0, 150, 300, 450, 600, 750, 900, 1050, 1200]
            for o in offs { _ = sp.add(sparse.frame(offset: o)) }
            if let img = sp.finish(), let out = PixelFrame(cgImage: img) {
                let want = offs.last! + sparse.height
                let bad = sparse.cleanRowsMatch(out, from: sparse.topFade, to: want - sparse.bottomOverlay)
                check("sparse text: placed by the strips that have text", sp.lostFrames == 0 && out.height == want && bad == nil,
                      "lost=\(sp.lostFrames) height=\(out.height) want=\(want)")
            } else { check("sparse text", false) }
        }

        // 11. Look-alike bubbles one bubble-height apart must never be matched to the wrong one.
        let twins = WebChat(width: 360, height: 480, contentHeight: 3400, twins: true)
        do {
            let st = Stitcher()
            let offs = [0, 60, 150, 260, 380, 500, 640, 760, 900, 1040]
            for o in offs { _ = st.add(twins.frame(offset: o)) }
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                let want = offs.last! + twins.height
                let bad = twins.cleanRowsMatch(out, from: twins.topFade, to: out.height - twins.bottomOverlay)
                // Dropping is allowed; a wrong placement (rows that are not the content) is not.
                check("look-alike bubbles: correct or dropped, never wrong", bad == nil && out.height <= want,
                      "lost=\(st.lostFrames) height=\(out.height) bad=\(bad.map(String.init) ?? "-")")
                check("look-alike bubbles: nothing dropped", st.lostFrames == 0 && out.height == want, "lost=\(st.lostFrames) height=\(out.height)")
            } else { check("look-alike bubbles", false) }
        }

        // 12. Auto pacing: a lost frame is first looked at again, then the view backs up by half of
        // the step actually sent; it pauses after six failures instead of claiming the end.
        var pacer = AutoPacer()
        pacer.sent(1)
        let retry = pacer.next(after: .lost)
        let reverse = pacer.next(after: .lost)
        check("auto pacing: resample, then back up half the sent step", retry == .resample && reverse == .scroll(-0.5), "\(retry), \(reverse)")
        var lastAction = reverse
        for _ in 0..<4 { lastAction = pacer.next(after: .lost) }
        check("auto pacing: unrecoverable capture pauses instead of finishing", lastAction == .pause, "\(lastAction)")

        // 13. From codex's review (review/codex 49a9085), adapted to this kernel.
        check("unrecovered capture is partial", s2.needsRecovery)
        let noWrite = Stitcher()
        _ = noWrite.add(frame(offset: 0, cursor: false))
        let missed = noWrite.add(frame(offset: 900, cursor: false))
        check("failed first placement changes no canvas or reference", missed == .lost && noWrite.canvasRows == 0 && noWrite.contentOrigin == 0)
        _ = noWrite.add(frame(offset: 100, cursor: false))
        check("a valid retry clears partial state", !noWrite.needsRecovery && noWrite.contentOrigin == 100)

        func exact(_ stitcher: Stitcher, _ expected: [UInt8]) -> Bool {
            guard let image = stitcher.finish(), let output = PixelFrame(cgImage: image) else { return false }
            let bad = zip(output.bytes, expected).enumerated().first { ($0.offset / 4) % w < w - 12 && $0.element.0 != $0.element.1 }?.offset
            if ProcessInfo.processInfo.environment["JZ_DEBUG"] != nil, bad != nil || output.bytes.count != expected.count {
                print("  exact: height \(output.height) want \(expected.count / (w * 4)), first bad row \(bad.map { $0 / (w * 4) } ?? -1)")
            }
            return output.bytes.count == expected.count && bad == nil
        }
        func expectedFade(_ last: Int, _ make: (Int) -> PixelFrame = faded) -> [UInt8] {
            Array(make(0).bytes.prefix((header + 36) * w * 4))
                + Array(content[(36 * w * 4)..<((last + 36) * w * 4)])
                + Array(make(last).bytes.suffix((bodyH + footer - 36) * w * 4))
        }
        // 27.5% overlap: the seam must step over the new frame's fade, using the old frame's rows.
        let s9 = Stitcher()
        for o in [0, 290, 580, 870] { _ = s9.add(faded(o)) }
        check("large step: clean seam, no repeated fade", exact(s9, expectedFade(870)), "lost=\(s9.lostFrames)")

        func raisedButton(_ offset: Int) -> PixelFrame {
            let f = faded(offset)
            var bytes = f.bytes
            for y in (header + 325)..<(header + 345) { for x in 250..<290 { let i = (y * w + x) * 4; bytes[i] = 30; bytes[i + 1] = 160; bytes[i + 2] = 90 } }
            return PixelFrame(width: w, height: f.height, bytes: bytes)
        }
        let blocked = Stitcher()
        _ = blocked.add(raisedButton(0))
        let blockedOutcome = blocked.add(raisedButton(290))
        check("seam bridge refuses a pinned button in held-back rows", blockedOutcome == .lost && blocked.canvasRows == 0, "\(blockedOutcome)")
        for o in [145, 290, 435, 580, 725, 870] { _ = blocked.add(raisedButton(o)) }
        check("smaller steps: no button fragment anywhere in between", exact(blocked, expectedFade(870, raisedButton)) && !blocked.needsRecovery)

        // Three copied rows propose a false shift; shared white background must not prove it.
        func sparseNoise(seed: UInt64) -> [UInt8] {
            var rng = SplitMix(seed: seed)
            var bytes = [UInt8](repeating: 255, count: w * bodyH * 4)
            for y in 0..<bodyH { for strip in 0..<8 {
                let x = strip * 40 + Int(rng.next() % 36) + 2
                let i = (y * w + x) * 4, v = UInt8(rng.next() % 100)
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            } }
            return bytes
        }
        let sparsePrevious = sparseNoise(seed: 99)
        var unrelated = sparseNoise(seed: 888)
        for y in [100, 150, 200] {
            unrelated.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: sparsePrevious[((y + 40) * w * 4)..<((y + 41) * w * 4)])
        }
        let s10 = Stitcher()
        _ = s10.add(PixelFrame(width: w, height: bodyH, bytes: sparsePrevious))
        let unrelatedOutcome = s10.add(PixelFrame(width: w, height: bodyH, bytes: unrelated))
        check("shared white background cannot prove a false shift", unrelatedOutcome == .lost, "\(unrelatedOutcome)")

        // Smooth-scroll frames blended between two positions are dropped; the content still arrives once.
        func intermediate(_ offset: Int) -> PixelFrame {
            let a = faded(offset), b = faded(offset + 1)
            return PixelFrame(width: w, height: a.height, bytes: zip(a.bytes, b.bytes).map { UInt8((Int($0.0) + Int($0.1)) / 2) })
        }
        let manual = Stitcher()
        for f in [faded(0), intermediate(33), intermediate(78), faded(120), intermediate(198), faded(260)] { _ = manual.add(f) }
        check("blended in-between frames: exact continuous pixels", exact(manual, expectedFade(260)) && !manual.needsRecovery,
              "accepted=\(manual.acceptedFrames) rejected=\(manual.lostFrames)")

        var gate = FrameSettler()
        let settled = Stitcher()
        var time = 0.0, ready = 0
        for f in [faded(0), faded(0), intermediate(33), intermediate(78), faded(120), faded(120), intermediate(198), faded(260), faded(260)] {
            if gate.observe(f, at: time) == .ready { _ = settled.add(f); ready += 1; gate.reset() }
            time += 0.12
        }
        check("settle gate admits only still frames", ready == 3 && settled.acceptedFrames == 3 && exact(settled, expectedFade(260)), "ready=\(ready)")
        gate.reset()
        var timedOut = false, acceptedMotion = false
        for k in 0..<16 {
            let r = gate.observe(faded(k * 15), at: Double(k) * 0.12)
            timedOut = timedOut || r == .timedOut
            acceptedMotion = acceptedMotion || r == .ready
        }
        check("settle gate times out at 1.5 s and never admits a moving frame", timedOut && !acceptedMotion)
        gate.reset()
        _ = gate.observe(frame(offset: 0, cursor: false), at: 0)
        check("blinking caret does not stall the settle gate", gate.observe(frame(offset: 0, cursor: true), at: 0.12) == .ready)

        // Repeated glyph shapes with small unique IDs.
        let chat = makeChatContent(width: w, height: contentH)
        let similar = Stitcher()
        for offset in stride(from: 0, through: 1400, by: 35) { _ = similar.add(frame(offset: offset, cursor: false, source: chat)) }
        let chatExpected = headerRows + Array(chat[0..<(1400 * w * 4)]) + Array(frame(offset: 1400, cursor: false, source: chat).bytes.suffix((bodyH + footer) * w * 4))
        check("similar chat bubbles: every message exactly once", exact(similar, chatExpected) && similar.lostFrames == 0, "rejected=\(similar.lostFrames)")

        // Auto-scroll end to end with a virtual wheel that moves 1.2x what it is told; once, the
        // first step overshoots far. Same pacer and settle gate as CaptureSession.
        for overshoot in [false, true] {
            var p = AutoPacer(), settle = FrameSettler()
            var clock = 0.0, offset = 0, commands = 0, reversed = false, finished = false
            let automatic = Stitcher()
            let baseStep = Double(header + bodyH + footer) * 0.45
            loop: for _ in 0..<200 {
                let f = faded(offset)
                let status = settle.observe(f, at: clock)
                clock += 0.12
                guard status == .ready else { continue }
                settle.reset()
                let tol = max(16, f.height * 12 / 100)
                let result = automatic.add(f, expected: p.expected, tolerance: tol)
                let action = p.next(after: result)
                if ProcessInfo.processInfo.environment["JZ_DEBUG"] != nil { print("  auto offset \(offset) expected \(p.expected.map(String.init) ?? "-"): \(result) -> \(action)") }
                switch action {
                case .resample: continue
                case .pause: break loop
                case .finish: finished = true; break loop
                case .scroll(let fraction):
                    commands += 1
                    p.sent(fraction)
                    reversed = reversed || fraction < 0
                    let amount = overshoot && commands == 1 ? 420 : Int((fraction * baseStep * 1.2).rounded())
                    offset = min(2800, max(0, offset + amount))
                }
            }
            check(overshoot ? "auto overshoot: resample, back up, reconnect, exact pixels" : "auto, wheel moves 1.2x the command: exact pixels",
                  finished && (!overshoot || reversed) && !automatic.needsRecovery && exact(automatic, expectedFade(2800)),
                  "finished=\(finished) reversed=\(reversed) rejected=\(automatic.lostFrames)")
        }
        let resized = Stitcher()
        _ = resized.add(frame(offset: 0, cursor: false))
        let sizeChange = resized.add(PixelFrame(width: w, height: 1, bytes: [UInt8](repeating: 255, count: w * 4)))
        check("resized frame is lost, never mistaken for the bottom", sizeChange == .lost && resized.needsRecovery)

        // 14. Manual mode, wheel-driven (Meibao's fixed and moving marks), with a simulated trackpad:
        // swipes with inertia tails, the wheel reading 20% high or low, and a swipe back up midway.
        func manualRun(_ chat: WebChat, readingFactor: Double, backAt: Int?, end: Int) -> (Stitcher, Int, Int) {
            let st = Stitcher()
            var tracker = ManualTracker(body: chat.height, pixelScale: 1)
            var offset = 0.0, t = 0.0, nextTick = 0.0, captures = 0
            _ = st.add(chat.frame(offset: 0))
            var swipes: [Double] = []
            var pos = 0.0
            while pos < Double(end) { swipes.append(70); pos += 70 * 2.6 } // ~180 px per swipe incl. inertia
            if let b = backAt { swipes.insert(-60, at: b) }
            func tick() {
                guard t >= nextTick else { return }
                nextTick += 0.12
                guard let r = tracker.capture(at: t) else { return }
                captures += 1
                let outcome = st.add(chat.frame(offset: Int(offset)), expected: r.expected, tolerance: r.tolerance)
                if ProcessInfo.processInfo.environment["JZ_DEBUG"] != nil {
                    print("  manual t=\(String(format: "%.2f", t)) offset \(Int(offset)) estimate \(tracker.estimate) expected \(r.expected.map(String.init) ?? "-") ratio \(String(format: "%.2f", tracker.ratio)): \(outcome)")
                }
                switch outcome {
                case .shifted(let d) where d != 0: tracker.placed(d: d, capture: r, edges: st.edgeBands)
                case .lost: tracker.lost(r)
                default: break
                }
            }
            for v0 in swipes {
                // 0.15 s of finger movement then an inertia tail decaying over ~0.6 s, 8 ms events.
                var v = v0 / 19
                for k in 0..<95 {
                    if k >= 19 { v *= 0.95 }
                    let target = min(Double(end), max(0, offset + v))
                    let moved = Double(Int(target)) - Double(Int(offset))
                    offset = target
                    if moved != 0 { tracker.wheel(deltaY: -moved * readingFactor, precise: true, at: t) }
                    t += 0.008
                    tick()
                }
            }
            for _ in 0..<100 { t += 0.008; tick() } // the user stops; the tracker takes the last frame
            return (st, Int(offset), captures)
        }
        for (factor, back) in [(1.0, nil), (1.2, nil), (0.8, nil), (1.0, 6), (1.2, 9)] as [(Double, Int?)] {
            let (st, end, captures) = manualRun(web, readingFactor: factor, backAt: back, end: 2900)
            let name = "manual wheel x\(factor)" + (back != nil ? " with a swipe back" : "")
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                let bad = web.cleanRowsMatch(out, from: web.topFade, to: out.height - web.bottomOverlay)
                check(name + ": every row once, clean, nothing dropped",
                      out.height == end + web.height && bad == nil && !st.needsRecovery,
                      "height=\(out.height) want=\(end + web.height) lost=\(st.lostFrames) frames=\(st.acceptedFrames) captures=\(captures) bad=\(bad.map(String.init) ?? "-") recovering=\(st.needsRecovery)")
            } else { check(name, false) }
        }

        // 15. Identical bubbles repeating every 150 px: the full search must refuse (any of several
        // shifts fits), but the wheel's estimate picks the one true shift inside its window.
        let repeating = WebChat(width: 360, height: 480, contentHeight: 3400, period: 150)
        let pf = Stitcher()
        _ = pf.add(repeating.frame(offset: 0))
        check("identical bubbles: full search refuses", pf.add(repeating.frame(offset: 200)) == .lost)
        let (pw, pend, _) = manualRun(repeating, readingFactor: 1.1, backAt: nil, end: 2400)
        if let img = pw.finish() {
            check("identical bubbles: wheel window places them at the right shift", img.height == pend + repeating.height && !pw.needsRecovery,
                  "height=\(img.height) want=\(pend + repeating.height) lost=\(pw.lostFrames)")
        } else { check("identical bubbles: wheel window", false) }

        // 16. Bottom of the page (real Guardian capture, 2026-10-22): one step lines up only around an ad
        // that changed after its rows were written, the page then ends after a short step, and an ad
        // loads in place on the last screen. Every frame is placed, the last screen is in, the capture
        // is not partial, and the image holds each content row once, changed parts in their newest version.
        do {
            let pw = 360, view = 500, end = 854
            let page = makeContent(width: pw, height: end + view)
            func shot(_ offset: Int, changes: [(Range<Int>, UInt64)] = []) -> PixelFrame {
                var b = Array(page[(offset * pw * 4)..<((offset + view) * pw * 4)])
                for (rows, seed) in changes {
                    var rng = SplitMix(seed: seed)
                    for y in rows where y >= offset && y < offset + view {
                        for x in 20..<(pw - 20) { let i = ((y - offset) * pw + x) * 4; let v = UInt8(rng.next() % 256); b[i] = v; b[i + 1] = 255 - v; b[i + 2] = v / 2 }
                    }
                }
                return PixelFrame(width: pw, height: view, bytes: b)
            }
            let st = Stitcher()
            var outcomes: [Stitcher.Outcome] = []
            for o in [0, 200, 400, 600] { outcomes.append(st.add(shot(o))) }
            let adB: (Range<Int>, UInt64) = (860..<950, 501)
            outcomes.append(st.add(shot(800, changes: [adB])))           // ad changed after it was written
            outcomes.append(st.add(shot(end, changes: [adB])))           // the page ends: 54 px
            outcomes.append(st.add(shot(end, changes: [adB, (884..<974, 502)]))) // ad loads in place
            outcomes.append(st.add(shot(end, changes: [adB, (884..<974, 502)])))
            let placedAll = !outcomes.contains(.lost) && outcomes[4] == .shifted(200) && outcomes[5] == .shifted(54) && outcomes[6] == .shifted(0)
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                check("page end: ad changed in the overlap, short last step, ad loads in place — every frame placed",
                      placedAll && st.lostFrames == 0 && !st.needsRecovery, "\(outcomes) recovering=\(st.needsRecovery)")
                // Both ads are in their newest version (the image is cut back where a change starts, or the
                // changed rows rewritten); everything else once, as on the page.
                let want = shot(end, changes: [adB, (884..<974, 502)]).bytes
                let latest = Array(page[0..<(end * pw * 4)]) + want
                check("page end: last screen in, each row once, in-place change in its new version", out.height == end + view && out.bytes == latest,
                      "height=\(out.height) want=\(end + view)")
            } else { check("page end", false) }
            // A change across the seam, or before anything lined up, is not taken for "nothing moved".
            let early = Stitcher()
            _ = early.add(shot(0))
            check("page end: in-place change before the first match is dropped", early.add(shot(0, changes: [(20..<120, 9)])) == .lost && early.canvasRows == 0)
        }

        // 17. A privacy banner pinned over the bottom 40% of the view the whole time, a lazy image loading
        // mid-way: nothing dropped, the banner exactly once (at the end), content rows once. A jump past the
        // overlap, with only the banner still the same, is dropped, never taken for "nothing moved".
        do {
            let pw = 360, view = 500, bannerH = 200, last = 840
            let page = makeContent(width: pw, height: last + view - bannerH)
            let banner = solid(width: pw, height: bannerH, rgb: (20, 40, 110), seed: 33)
            func shot(_ offset: Int, lazy: Bool = false) -> PixelFrame {
                var b = Array(page[(offset * pw * 4)..<((offset + view - bannerH) * pw * 4)])
                if lazy { var rng = SplitMix(seed: 71); for y in 20..<120 { for x in 30..<(pw - 30) { let i = (y * pw + x) * 4; let v = UInt8(rng.next() % 256); b[i] = v; b[i + 1] = v; b[i + 2] = 255 - v } } }
                return PixelFrame(width: pw, height: view, bytes: b + banner)
            }
            let st = Stitcher()
            var outcomes: [Stitcher.Outcome] = []
            for (o, lazy) in [(0, false), (120, false), (240, false), (360, false), (480, false), (480, true), (600, false), (720, false), (840, false)] {
                outcomes.append(st.add(shot(o, lazy: lazy)))
            }
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                var want = Array(page[0..<((last + view - bannerH) * pw * 4)]) + banner
                // The lazy image (frame rows 20..<120 at offset 480) in its loaded version.
                let lazyShot = shot(480, lazy: true).bytes
                want.replaceSubrange((500 * pw * 4)..<(600 * pw * 4), with: lazyShot[(20 * pw * 4)..<(120 * pw * 4)])
                check("pinned banner: nothing dropped, banner once, content once, lazy image as loaded", st.lostFrames == 0 && !st.needsRecovery && out.bytes == want,
                      "\(outcomes) height=\(out.height) want=\(last + view) firstDiffRow=\(zip(out.bytes, want).enumerated().first { $0.element.0 != $0.element.1 }.map { $0.offset / (pw * 4) } ?? -1)")
            } else { check("pinned banner", false) }
            let jump = Stitcher()
            _ = jump.add(shot(0)); _ = jump.add(shot(120))
            check("pinned banner: a jump with only the banner unchanged is dropped", jump.add(shot(600)) == .lost)
        }

        // 18. Classic scrollbar on the right: its knob creeps down while the content moves up. The image
        // gets the plain track there, not a piece of the knob in every stretch; the content is untouched.
        do {
            let pw = 360, view = 400, band = 15, contentH = 1600
            let page = makeContent(width: pw - band, height: contentH)
            func shot(_ offset: Int) -> PixelFrame {
                var b: [UInt8] = []
                // Inset from the ends like real knobs (macOS overlay, Chrome classic: a few px clear of the edge).
                let knob = 6 + offset * (view - 52) / (contentH - view)
                for y in 0..<view {
                    let rowStart: Int = (offset + y) * (pw - band) * 4
                    b += page[rowStart..<(rowStart + (pw - band) * 4)]
                    let onKnob = y >= knob && y < knob + 40
                    for x in 0..<band {
                        let v: UInt8 = x == 0 ? 232 : ((onKnob && x > 3 && x < 12) ? 190 : 250)
                        b += [v, v, v, 255]
                    }
                }
                return PixelFrame(width: pw, height: view, bytes: b)
            }
            let st = Stitcher()
            for o in stride(from: 0, through: contentH - view, by: 150) { _ = st.add(shot(o)) }
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                var knobRows = 0, contentOK = true
                for y in 0..<(out.height - view) {
                    let row: Int = y * pw * 4, src: Int = y * (pw - band) * 4
                    if ((pw - band + 4)..<(pw - band + 12)).contains(where: { (x: Int) -> Bool in out.bytes[row + x * 4] == 190 }) { knobRows += 1 }
                    if !out.bytes[row..<(row + (pw - band) * 4)].elementsEqual(page[src..<(src + (pw - band) * 4)]) { contentOK = false }
                }
                check("scrollbar knob not repeated in the image", knobRows == 0 && contentOK && st.lostFrames == 0, "knob rows=\(knobRows) content=\(contentOK)")
            } else { check("scrollbar knob", false) }
        }

        // 20. Live Guardian capture (live-opus, 2026-10-22): the ad slot at the top was still empty in the
        // first frame and filled in before any scrolling. Before any input the newest picture simply becomes
        // the first frame; once input may have scrolled, the same "everything else still" picture is
        // dropped instead (a jump with a pinned banner looks exactly like that).
        do {
            let pw = 360, view = 500
            let page = makeContent(width: pw, height: 1600)
            func shot(_ offset: Int, ad: Bool) -> PixelFrame {
                var b = Array(page[(offset * pw * 4)..<((offset + view) * pw * 4)])
                if ad { var rng = SplitMix(seed: 404); for y in 0..<150 where y + offset < 150 { for x in 10..<(pw - 10) { let i = ((y) * pw + x) * 4; let v = UInt8(rng.next() % 256); b[i] = v; b[i + 1] = 255 - v; b[i + 2] = 90 } } }
                return PixelFrame(width: pw, height: view, bytes: b)
            }
            let st = Stitcher()
            st.scrollStarted = false
            var outcomes = [st.add(shot(0, ad: false)), st.add(shot(0, ad: true)), st.add(shot(0, ad: true))]
            st.scrollStarted = true // the first wheel event
            for o in [200, 400, 600, 800, 1000, 1100] { outcomes.append(st.add(shot(o, ad: true))) }
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                var want = shot(0, ad: true).bytes
                want += page[(view * pw * 4)..<((1100 + view) * pw * 4)]
                check("ad fills in before the first scroll: newest picture is the first frame, nothing dropped",
                      st.lostFrames == 0 && !st.needsRecovery && out.bytes == want, "\(outcomes) height=\(out.height)")
            } else { check("ad fills in before the first scroll", false) }
            let after = Stitcher()
            _ = after.add(shot(0, ad: false))
            after.scrollStarted = true // input seen, nothing placed yet
            check("after input, an unplaceable change before the first match is still dropped", after.add(shot(0, ad: true)) == .lost && after.canvasRows == 0)
            let selfMoved = Stitcher()
            selfMoved.scrollStarted = false
            _ = selfMoved.add(shot(0, ad: false))
            check("before input, a page that moves by itself is stitched, not swallowed", selfMoved.add(shot(150, ad: false)) == .shifted(150) && selfMoved.scrollStarted)
        }

        // 21. Auto-scroll caps its step at the share of the view that scrolls (after codex 64e78ce).
        do {
            var pacer = AutoPacer()
            _ = pacer.next(after: .first, movingShare: 0.3)
            var steps: [Double] = []
            for _ in 0..<5 { if case .scroll(let f) = pacer.next(after: .shifted(80), movingShare: 0.3) { steps.append(f) } }
            check("auto step capped at the moving share of the view", !steps.isEmpty && steps.allSatisfy { $0 <= 0.3 + 1e-9 }, "\(steps)")
        }

        // 22. An ad slot fills while the page scrolls, across the seam (live-opus 228 -> 229): the image is
        // cut back to where the slot starts and goes on with the new frame; the ad is whole, nothing repeats.
        do {
            let pw = 360, view = 500, contentH = 1700
            let page = makeContent(width: pw, height: contentH)
            var filled = page
            var rng = SplitMix(seed: 909)
            for y in 560..<700 { for x in 0..<pw { let i = (y * pw + x) * 4; let v = UInt8(rng.next() % 256); filled[i] = v; filled[i + 1] = v / 3; filled[i + 2] = 255 - v } }
            var blank = page
            for y in 560..<700 { for x in 0..<pw { let i = (y * pw + x) * 4; blank[i] = 250; blank[i + 1] = 250; blank[i + 2] = 250 } }
            func shot(_ src: [UInt8], _ o: Int) -> PixelFrame { PixelFrame(width: pw, height: view, bytes: Array(src[(o * pw * 4)..<((o + view) * pw * 4)])) }
            let st = Stitcher()
            var outcomes = [st.add(shot(blank, 0)), st.add(shot(blank, 200))]
            for o in [400, 600, 800, 1000, 1200] { outcomes.append(st.add(shot(filled, o))) }
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                check("ad fills across the seam while scrolling: cut back, ad whole, nothing repeated",
                      st.lostFrames == 0 && out.bytes == filled, "\(outcomes) height=\(out.height) want=\(contentH)")
            } else { check("ad fills across the seam", false) }
        }

        // 23. Chrome adds its scroll bar and recentres the page 7 px to the right, without scrolling
        // (live-opus 112 -> 113): later frames are moved back and keep lining up; nothing dropped.
        do {
            let pw = 360, view = 500, contentH = 1600
            let page = makeContent(width: pw, height: contentH)
            func shot(_ o: Int, right: Int) -> PixelFrame {
                var b = [UInt8](repeating: 255, count: pw * view * 4)
                for y in 0..<view { for x in 0..<pw {
                    let sx = x - right
                    guard sx >= 0 else { continue }
                    let i = (y * pw + x) * 4, j = ((o + y) * pw + sx) * 4
                    b[i] = page[j]; b[i + 1] = page[j + 1]; b[i + 2] = page[j + 2]; b[i + 3] = page[j + 3]
                } }
                return PixelFrame(width: pw, height: view, bytes: b)
            }
            let st = Stitcher()
            var outcomes: [Stitcher.Outcome] = []
            for (o, r) in [(0, 0), (200, 0), (400, 0), (400, 7), (600, 7), (800, 7), (1000, 7), (1100, 7)] { outcomes.append(st.add(shot(o, right: r))) }
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                check("page recentred sideways: re-anchored, nothing dropped, content in place",
                      st.lostFrames == 0 && out.bytes == Array(page[0..<((1100 + view) * pw * 4)]), "\(outcomes) height=\(out.height)")
            } else { check("page recentred sideways", false) }
        }

        // 24. Manual mode, live2-opus: wheel events of 260 px every 0.6 s; one frame cannot be joined (here
        // the view is briefly covered) and the wheel keeps going far past the overlap. The tracker must keep
        // taking frames the whole time (not fall silent until the wheel stops), the capture stays "not
        // joined" while past, and scrolling back reconnects with every row once and nothing pasted.
        do {
            let pw = 360, view = 500, end = 3000
            let page = makeContent(width: pw, height: end + view)
            var cover = SplitMix(seed: 2026)
            let noise = (0..<(pw * view * 4)).map { _ in UInt8(cover.next() % 256) }
            let st = Stitcher()
            var tracker = ManualTracker(body: view, pixelScale: 1)
            var offset = 0, t = 0.0, nextTick = 0.0
            var covered = false, capturesWhileOver = 0, everUnjoinedPastOverlap = false
            func shot() -> PixelFrame {
                covered ? PixelFrame(width: pw, height: view, bytes: noise)
                    : PixelFrame(width: pw, height: view, bytes: Array(page[(offset * pw * 4)..<((offset + view) * pw * 4)]))
            }
            func tick() {
                guard t >= nextTick else { return }
                nextTick += 0.12
                // As CaptureSession: wheel-driven once something is placed and the wheel is active.
                var r: ManualTracker.Capture?
                if st.acceptedFrames > 0, tracker.active(at: t) {
                    guard let c = tracker.capture(at: t) else { return }
                    r = c
                }
                if tracker.estimate > tracker.maxShift { capturesWhileOver += 1; if st.needsRecovery { everUnjoinedPastOverlap = true } }
                let o = st.add(shot(), expected: r?.expected, tolerance: r?.tolerance ?? 0)
                switch (o, r) {
                case (.shifted(let d), let c?) where d != 0: tracker.placed(d: d, capture: c, edges: st.edgeBands)
                case (.lost, let c?): tracker.lost(c)
                case (.shifted(let d), nil) where d != 0: tracker.resync()
                case (.first, _): tracker.resync()
                default: break
                }
            }
            func run(_ seconds: Double) { let stop = t + seconds; while t < stop { t += 0.01; tick() } }
            _ = st.add(shot())
            func wheel(_ dy: Int) { offset = min(end, max(0, offset + dy)); tracker.wheel(deltaY: Double(-dy), precise: true, at: t); run(0.6) }
            for _ in 0..<4 { wheel(260) }
            covered = true; wheel(260); covered = false   // the frame at this step cannot be joined
            for _ in 0..<6 { wheel(260) }                  // ...and the wheel keeps going, far past the overlap
            let lostWhileGoing = st.needsRecovery
            for _ in 0..<6 { wheel(-260) }                 // the user scrolls back as told
            while offset < end { wheel(260) }
            run(3)
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                check("manual: after a dropped frame the wheel keeps going — frames still taken, reconnects on the way back",
                      capturesWhileOver >= 5 && lostWhileGoing && everUnjoinedPastOverlap && !st.needsRecovery && st.lostFrames > 0
                          && out.bytes == Array(page[0..<((end + view) * pw * 4)]),
                      "captures while past=\(capturesWhileOver) lost=\(st.lostFrames) recovering=\(st.needsRecovery) height=\(out.height) want=\(end + view)")
            } else { check("manual: dropped frame then keeps scrolling", false) }
        }

        // 25. A donation panel pinned over the bottom 45% of the view appears while the page scrolls
        // (live3-opus): only the part above it scrolls from then on. Every content row once, the panel
        // once at the very end, never pasted into the middle; nothing placed wrongly.
        do {
            let pw = 360, view = 500, panelH = 225, contentH = 2400
            let page = makeContent(width: pw, height: contentH)
            let panel = solid(width: pw, height: panelH, rgb: (235, 240, 250), seed: 61)
            func shot(_ o: Int, panelOn: Bool) -> PixelFrame {
                var b = Array(page[(o * pw * 4)..<((o + view) * pw * 4)])
                if panelOn { b.replaceSubrange(((view - panelH) * pw * 4)..<(view * pw * 4), with: panel) }
                return PixelFrame(width: pw, height: view, bytes: b)
            }
            let st = Stitcher()
            var outcomes: [Stitcher.Outcome] = []
            var o = 0
            for _ in 0..<4 { outcomes.append(st.add(shot(o, panelOn: false))); o += 120 }
            while o + view <= contentH { outcomes.append(st.add(shot(o, panelOn: true))); o += 120 }
            let last = o - 120
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                let want = Array(page[0..<((last + view - panelH) * pw * 4)]) + panel
                var panelRowsInside = 0
                for y in 0..<max(0, out.height - panelH) where out.bytes[(y * pw * 4)..<((y + 1) * pw * 4)].elementsEqual(panel[0..<(pw * 4)]) { panelRowsInside += 1 }
                check("bottom panel appears mid-scroll: content once, panel once at the end, never pasted inside",
                      out.bytes == want && panelRowsInside == 0,
                      "lost=\(st.lostFrames) height=\(out.height) want=\(last + view) panel rows inside=\(panelRowsInside) \(outcomes.suffix(6))")
            } else { check("bottom panel appears mid-scroll", false) }
        }

        // 26. A sign-in prompt pinned over the top right corner (about a third of the width, a third of the
        // view; live3-opus): the frame still lines up on the rest, and the prompt is not repeated down the
        // image wherever the content behind it was seen uncovered in the previous frame.
        do {
            let pw = 360, view = 500, contentH = 2000, step = 280
            let page = makeContent(width: pw, height: contentH)
            var rng = SplitMix(seed: 88)
            let box = (x0: 220, x1: 350, y0: 20, y1: 170)
            var prompt = [UInt8](repeating: 0, count: (box.x1 - box.x0) * (box.y1 - box.y0) * 4)
            for i in stride(from: 0, to: prompt.count, by: 4) { let v = UInt8(rng.next() % 2 == 0 ? 40 : 250); prompt[i] = v; prompt[i + 1] = v; prompt[i + 2] = 255; prompt[i + 3] = 255 }
            func shot(_ o: Int) -> PixelFrame {
                var b = Array(page[(o * pw * 4)..<((o + view) * pw * 4)])
                for y in box.y0..<box.y1 { for x in box.x0..<box.x1 { let i = (y * pw + x) * 4, j = ((y - box.y0) * (box.x1 - box.x0) + x - box.x0) * 4; for c in 0..<4 { b[i + c] = prompt[j + c] } } }
                return PixelFrame(width: pw, height: view, bytes: b)
            }
            let st = Stitcher()
            var o = 0
            while o + view <= contentH { _ = st.add(shot(o)); o += step }
            let last = o - step
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                // Below the first screen (which shows the prompt as it was), no row carries prompt pixels.
                var promptRows = 0
                for y in view..<out.height {
                    let i = (y * pw + box.x0) * 4
                    if (0..<(box.x1 - box.x0)).allSatisfy({ out.bytes[i + $0 * 4 + 2] == 255 && (out.bytes[i + $0 * 4] == 40 || out.bytes[i + $0 * 4] == 250) }) { promptRows += 1 }
                }
                let contentOK = out.height == last + view && (view..<out.height).allSatisfy { y in
                    out.bytes[(y * pw * 4)..<((y * pw + box.x0) * 4)].elementsEqual(page[(y * pw * 4)..<((y * pw + box.x0) * 4)])
                }
                check("pinned corner prompt: lined up on the rest, not repeated down the image", st.lostFrames == 0 && promptRows == 0 && contentOK,
                      "lost=\(st.lostFrames) prompt rows=\(promptRows) height=\(out.height) want=\(last + view) content=\(contentOK)")
            } else { check("pinned corner prompt", false) }
        }

        // 27. A sticky ad bar pinned over the top of the view, and an ad loading further down during the first
        // steps (live5-guardian: the image began with the bar pasted twice and ~180 rows of the first screen
        // gone). The image must begin with the last picture before scrolling, row for row, and never contain
        // the bar again further down.
        do {
            let pw = 360, view = 500, barH = 120, contentH = 1800, step = 130
            let page = makeContent(width: pw, height: contentH)
            var bar = [UInt8](repeating: 0, count: pw * barH * 4)
            for y in 0..<barH { for x in 0..<pw {
                let edge = y < 3 || y >= barH - 3 || x < 3 || x >= pw - 3
                let v: UInt8 = edge ? 150 : 236
                let i = (y * pw + x) * 4; bar[i] = v; bar[i + 1] = v; bar[i + 2] = v; bar[i + 3] = 255
            } }
            var loaded = page
            var rng = SplitMix(seed: 4242)
            for y in 640..<720 { for x in 20..<(pw - 20) { let i = (y * pw + x) * 4; let v = UInt8(rng.next() % 256); loaded[i] = v; loaded[i + 1] = 200; loaded[i + 2] = 255 - v } }
            func shot(_ src: [UInt8], _ o: Int) -> PixelFrame {
                var b = Array(src[(o * pw * 4)..<((o + view) * pw * 4)])
                // The bar sits a few rows below the top of the view; those rows show the page moving.
                b.replaceSubrange((8 * pw * 4)..<((8 + barH) * pw * 4), with: bar)
                // macOS overlay scroll knob, creeping down over the bar and the page.
                let k = 6 + o / 40
                for y in k..<(k + 30) { for x in (pw - 9)..<(pw - 3) { let i = (y * pw + x) * 4; b[i] = 120; b[i + 1] = 120; b[i + 2] = 120 } }
                return PixelFrame(width: pw, height: view, bytes: b)
            }
            let st = Stitcher()
            var o = 0
            var outs: [Stitcher.Outcome] = []
            outs.append(st.add(shot(page, 0))); o += step
            outs.append(st.add(shot(page, o))); o += step
            while o + view <= contentH { outs.append(st.add(shot(loaded, o))); o += step }
            if ProcessInfo.processInfo.environment["JZ_DEBUG"] != nil { print("  sticky outcomes \(outs)") }
            let last = o - step
            if let img = st.finish(), let out = PixelFrame(cgImage: img) {
                let first = shot(page, 0).bytes
                // The ad that loaded later is in its newest version wherever the first screen showed it; the
                // scroll bar band (the knob is painted out separately) is left out of the comparison.
                let startsRight = out.bytes.count >= first.count && (0..<(view * pw * 4)).allSatisfy { i in
                    let y = i / (pw * 4), x = (i / 4) % pw
                    return x >= pw - 16 || out.bytes[i] == ((640..<720).contains(y) ? loaded[i] : first[i])
                }
                var barRows = 0
                for y in (barH + 8)..<out.height where out.bytes[(y * pw * 4)..<((y * pw + pw - 16) * 4)].elementsEqual(bar[(10 * pw * 4)..<((10 * pw + pw - 16) * 4)]) { barRows += 1 }
                check("sticky top bar: image begins with the first screen, bar never pasted again",
                      startsRight && barRows == 0 && st.lostFrames == 0 && out.height == last + view,
                      "begins right=\(startsRight) first diff row=\((0..<(view * pw * 4)).first { i in let y = i / (pw * 4), x = (i / 4) % pw; return x < pw - 16 && out.bytes[i] != ((640..<720).contains(y) ? loaded[i] : first[i]) }.map { "\($0 / (pw * 4)),x\(($0 / 4) % pw)" } ?? "-") bar rows below=\(barRows) lost=\(st.lostFrames) height=\(out.height) want=\(last + view)")
            } else { check("sticky top bar", false) }
        }

        // 19. A capture whose area slid off the window has whole transparent columns; rounded corners do not.
        do {
            var b = frame(offset: 0, cursor: false).bytes
            for y in 0..<(header + bodyH + footer) { for x in 0..<20 { b[(y * w + x) * 4 + 3] = 0 } }
            check("capture outside the window is recognised, rounded corners are not",
                  PixelFrame(width: w, height: header + bodyH + footer, bytes: b).reachesOutsideWindow && !frame(offset: 0, cursor: false).reachesOutsideWindow)
        }

        // 8. Export round trip.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("livingscrollpdf-selftest-\(getpid())")
        do {
            let rec = CaptureRecord(appName: "SelfTest", windowTitle: "synthetic", startedAt: Date(), endedAt: Date(),
                                    framesStitched: s.acceptedFrames, droppedFrames: s.lostFrames, pixelWidth: img.width,
                                    pixelHeight: img.height, pointScale: 2)
            let pdf = try Exporter.export(img, record: rec, folder: dir)
            let pages = CGPDFDocument(pdf as CFURL)?.numberOfPages ?? 0
            check("long pdf is one page", pages == 1, "pages=\(pages)")
            let a4 = dir.appendingPathComponent("a4.pdf")
            let a4Pages = try Exporter.writePDF(img, scale: 2, layout: .a4, record: rec, to: a4)
            check("a4 pdf paginated", a4Pages > 1 && CGPDFDocument(a4 as CFURL)?.numberOfPages == a4Pages, "pages=\(a4Pages)")
            let again = try Exporter.export(img, record: rec, folder: dir)
            check("same-second export does not overwrite", again != pdf, again.lastPathComponent)
            var partial = rec
            partial.isPartial = true; partial.partialReason = "ended-before-reconnecting"
            let partialPDF = try Exporter.export(img, record: partial, folder: dir)
            let partialJSON = partialPDF.deletingPathExtension().appendingPathExtension("json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: partialJSON)) as? [String: Any]
            let subject = PDFDocument(url: partialPDF)?.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
            check("partial export: file name, JSON and PDF subject say so",
                  partialPDF.lastPathComponent.contains(L("未完成", "partial")) && object?["isPartial"] as? Bool == true
                  && object?["partialReason"] as? String == "ended-before-reconnecting" && subject.contains(L("未完成", "PARTIAL")),
                  "\(partialPDF.lastPathComponent) subject=\(subject)")
            print("     output: \(dir.path)")
        } catch {
            check("export", false, "\(error)")
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// From codex's review: repeated glyph shapes with a unique right-hand ID per message.
    private static func makeChatContent(width w: Int, height h: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for message in 0..<(h / 100) {
            let top = message * 100 + 8, left = message % 2 == 0 ? 12 : 95
            for y in top..<min(h, top + 78) { for x in left..<min(w - 12, left + 210) {
                let i = (y * w + x) * 4
                bytes[i] = 230; bytes[i + 1] = 230; bytes[i + 2] = 235
            } }
            var rng = SplitMix(seed: UInt64(message + 17))
            for line in 0..<3 { for glyph in 0..<23 { for gy in 0..<10 { for gx in 0..<5 {
                let y = top + 10 + line * 18 + gy, x = left + 8 + glyph * 8 + gx
                guard y < h, x < w - 12 else { continue }
                let ink = glyph < 18 ? ((gx * 3 + gy * 5 + glyph + line) % 7 < 3) : rng.next() % 3 == 0
                if ink { let i = (y * w + x) * 4; bytes[i] = 35; bytes[i + 1] = 35; bytes[i + 2] = 40 }
            } } } }
        }
        return bytes
    }

    /// Message-like blocks of noise separated by blank gaps (which look identical across frames).
    private static func makeContent(width w: Int, height h: Int) -> [UInt8] {
        var rng = SplitMix(seed: 42)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        var y = 0
        while y < h {
            let gap = Int(rng.next() % 30) + 4
            y += gap
            if y >= h { break }
            let block = Int(rng.next() % 90) + 20
            let left = Int(rng.next() % 2) == 0
            let x0 = left ? 12 : w / 3, x1 = left ? w * 2 / 3 : w - 12
            for yy in y..<min(h, y + block) {
                for x in x0..<x1 {
                    let i = (yy * w + x) * 4
                    let v = UInt8(rng.next() % 200)
                    bytes[i] = v; bytes[i + 1] = v &+ 30; bytes[i + 2] = 200
                }
            }
            y += block
        }
        return bytes
    }

    private static func solid(width w: Int, height h: Int, rgb: (UInt8, UInt8, UInt8), seed: UInt64) -> [UInt8] {
        var rng = SplitMix(seed: seed)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                bytes[i] = rgb.0; bytes[i + 1] = rgb.1; bytes[i + 2] = rgb.2
                if y > 8 && y < h - 8 && x > 10 && x < 120 && rng.next() % 3 == 0 { bytes[i] = 20 }
            }
        }
        return bytes
    }
}

/// Synthetic web chat in the style of the failing sample. Content rows are what the page holds;
/// `frame(offset:)` is what a capture shows: fades, a pinned button and a floating pill on top.
struct WebChat {
    let width: Int
    let height: Int
    let topFade: Int
    let bottomFade: Int
    /// Rows at the bottom covered by the bottom fade or the floating pill.
    let bottomOverlay: Int
    let content: [UInt8]

    init(width: Int, height: Int, contentHeight: Int, sparse: Bool = false, twins: Bool = false, period: Int? = nil) {
        self.width = width
        self.height = height
        topFade = height * 11 / 100
        bottomFade = height / 20
        bottomOverlay = max(bottomFade, 46)
        var c = [UInt8](repeating: 250, count: width * contentHeight * 4)
        for i in stride(from: 3, to: c.count, by: 4) { c[i] = 255 }
        var rng = SplitMix(seed: twins ? 77 : 11)
        var y = 8
        var k = 0
        while y < contentHeight - 200 {
            let lines = sparse ? 1 : (twins ? 3 : Int(rng.next() % 6) + 1)
            let left = sparse ? true : k % 2 == 0
            let bw = sparse ? 70 : (twins ? width * 2 / 3 : width / 2 + Int(rng.next() % UInt64(width / 3)))
            let x0 = left ? 14 : width - 14 - bw, x1 = x0 + bw
            let bh = lines * 22 + 14
            let shade: UInt8 = left ? 228 : 238
            for yy in y..<min(contentHeight, y + bh) {
                for x in x0..<x1 { let i = (yy * width + x) * 4; c[i] = shade; c[i + 1] = shade; c[i + 2] = shade + 4 }
            }
            // "Text": glyph-like dark marks. Twins share their first two lines exactly and differ
            // only in a few glyphs of the last one.
            for line in 0..<lines {
                var g = twins && line < 2 ? SplitMix(seed: UInt64(1000 + line)) : SplitMix(seed: rng.next())
                let ty = y + 8 + line * 22
                var x = x0 + 10
                while x < x1 - 16 {
                    let gw = Int(g.next() % 6) + 7
                    for yy in ty..<min(contentHeight, ty + 14) {
                        for xx in x..<min(x1 - 10, x + gw) where g.next() % 3 == 0 {
                            let i = (yy * width + xx) * 4; c[i] = 30; c[i + 1] = 30; c[i + 2] = 34
                        }
                    }
                    x += gw + 3
                }
                if twins && line == 2 { // tiny difference: one glyph changes per bubble
                    let gx = x0 + 10 + (k * 37) % max(1, bw - 40)
                    for yy in ty..<(ty + 14) { for xx in gx..<(gx + 10) { let i = (yy * width + xx) * 4; c[i] = 200; c[i + 1] = 40; c[i + 2] = 40 } }
                }
            }
            y += bh + (sparse ? 140 : (twins ? 12 : Int(rng.next() % 26) + 8))
            k += 1
        }
        if let period { // every `period` rows the same again, pixel for pixel
            let rowBytes = width * 4
            for y in period..<contentHeight { c.replaceSubrange((y * rowBytes)..<((y + 1) * rowBytes), with: c[((y % period) * rowBytes)..<((y % period + 1) * rowBytes)]) }
        }
        content = c
    }

    func frame(offset: Int) -> PixelFrame {
        let w = width
        var b = Array(content[(offset * w * 4)..<((offset + height) * w * 4)])
        func fade(_ y: Int, keep: Double) {
            for x in 0..<w { let i = (y * w + x) * 4; for ch in 0..<3 { b[i + ch] = UInt8(Double(b[i + ch]) * keep + 250 * (1 - keep)) } }
        }
        for y in 0..<topFade { fade(y, keep: 0.25 + 0.75 * Double(y) / Double(topFade)) }
        for y in (height - bottomFade)..<height { fade(y, keep: 0.4 + 0.6 * Double(height - 1 - y) / Double(bottomFade)) }
        // Pinned "invite" button, top right.
        for y in 4..<26 { for x in (w - 78)..<(w - 8) { let i = (y * w + x) * 4; let on = (x / 5 + y / 4) % 3 == 0; b[i] = on ? 20 : 252; b[i + 1] = on ? 20 : 252; b[i + 2] = on ? 20 : 252 } }
        // Floating "N 則訊息" pill, bottom centre; its count drops as the reader scrolls.
        let count = 80 - offset / 40
        for y in (height - 44)..<(height - 20) {
            for x in (w / 2 - 44)..<(w / 2 + 44) {
                let i = (y * w + x) * 4
                let digit = x < w / 2 - 20 && (x * 7 + y * 3 + count * 13) % 5 < 2
                let v: UInt8 = digit ? 250 : 70
                b[i] = v; b[i + 1] = v; b[i + 2] = v
            }
        }
        return PixelFrame(width: w, height: height, bytes: b)
    }

    /// First canvas row in [from, to) that differs from the clean content, or nil.
    func cleanRowsMatch(_ out: PixelFrame, from: Int, to: Int) -> Int? {
        let stride = width * 4
        for y in from..<min(to, out.height) where y * stride + stride <= content.count {
            if out.bytes[(y * stride)..<((y + 1) * stride)] != content[(y * stride)..<((y + 1) * stride)] {
                // The pinned button covers the top right of the first frame's rows only.
                if y < 26 { continue }
                return y
            }
        }
        return nil
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
