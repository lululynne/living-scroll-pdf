import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Follows one window: captures the picked region of that window only (occluding windows
/// and our own overlays never appear), several times a second, while the user scrolls —
/// or while auto-scroll scrolls for them.
@MainActor
final class CaptureSession {
    private let pick: PickResult
    /// Region relative to the window's top-left corner, in points.
    private let sourceRect: CGRect
    private let stitcher = Stitcher()
    private let work = DispatchQueue(label: "livingscrollpdf.stitch", qos: .userInitiated)
    private let startedAt = Date()
    private let onEnd: (CaptureSession) -> Void
    private var ended = false

    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    /// Frame of the display being captured, in global coordinates (top-left origin).
    private var display: CGRect = .zero
    private var scale: Double = 2
    private var timer: Timer?
    private var inFlight = false
    private var finishing = false
    private var autoScroll = false
    /// Auto-scroll step size; resamples, backs up and halves after a lost frame.
    private var pacer = AutoPacer()
    /// Auto mode only stitches frames that have stopped moving.
    private var settler = FrameSettler()
    private var lastScroll = Date.distantPast
    /// Manual mode: the moving mark, driven by the user's wheel events.
    private var tracker: ManualTracker?
    private var wheelMonitor: Any?
    private var inputMonitor: Any?
    /// A wheel, key or drag event (or an auto-scroll step) since the start: the page may have moved.
    private var inputSeen = false
    /// The last frame could not be joined and nothing has been joined since.
    private var recovering = false
    private let clock0 = Date()
    private var now: Double { Date().timeIntervalSince(clock0) }
    private var captureFailures = 0
    private var status = L("准备中…", "Getting ready…")
    private var dumpIndex = 0

    private let border: BorderWindow
    private let hud: HUDPanel

    private let autoStart: Bool

    init(pick: PickResult, autoStart: Bool = false, onEnd: @escaping (CaptureSession) -> Void) {
        self.pick = pick
        self.autoStart = autoStart
        self.onEnd = onEnd
        sourceRect = pick.region.offsetBy(dx: -pick.windowFrame.minX, dy: -pick.windowFrame.minY)
        border = BorderWindow()
        hud = HUDPanel()
        hud.onAuto = { [weak self] in self?.toggleAuto() }
        hud.onDone = { [weak self] in self?.finish() }
        hud.onCancel = { [weak self] in self?.cancel() }
    }

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == pick.windowID }) else {
                fail(L("找不到刚才选中的窗口了", "The window you picked is gone"))
                return
            }
            // A window filter measures `sourceRect` from the corner of the window's capture area, and
            // that area can grow on the fly (Chrome attaches child windows, popups, bubbles to its
            // window): the picked region then slides, toolbars and empty space come into the frame.
            // A display filter that renders only this window keeps the region where it was picked,
            // in display coordinates, and other windows stay out just the same.
            guard let display = content.displays.first(where: { $0.frame.intersects(pick.region) }) ?? content.displays.first else {
                fail(L("找不到窗口所在的屏幕", "Can't find the display the window is on"))
                return
            }
            let filter = SCContentFilter(display: display, including: [window])
            self.display = display.frame
            scale = Double(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.sourceRect = displayRect()
            config.width = Int((sourceRect.width * CGFloat(scale)).rounded())
            config.height = Int((sourceRect.height * CGFloat(scale)).rounded())
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            self.filter = filter
            self.config = config
        } catch {
            fail(L("没有屏幕录制权限，或窗口不可截取：", "No screen recording permission, or the window can't be captured: ") + error.localizedDescription)
            return
        }
        // Ended (hotkey, cancel) while the window list was being fetched.
        guard !finishing else { return }
        stitcher.pixelScale = max(1, Int(scale.rounded()))
        // Until the user (or auto-scroll) can have moved the page, changes are the page settling.
        stitcher.scrollStarted = false

        placeChrome()
        border.orderFrontRegardless()
        hud.orderFrontRegardless()
        update(L("开始了：去滚你的窗口，我跟着截", "Go ahead and scroll the window, I'll keep up"))
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        settler.pixelScale = stitcher.pixelScale
        startWheelMonitor()
        if autoStart { toggleAuto() }
        tick()
    }

    /// Hotkey during a session ends it.
    func hotkey() { finish() }

    // MARK: - Loop

    private func tick() {
        guard !inFlight, !finishing, let filter, let config else { return }
        placeChrome()
        if autoScroll, Date().timeIntervalSince(lastScroll) < 0.35 { return }
        // Manual, wheel-driven: only look when the moving mark has reached the seam line (or the
        // user stopped short of it). Without recent wheel events (keyboard, dragging the scroll
        // bar) every tick is matched over the full range, as before.
        var request: ManualTracker.Capture?
        if !autoScroll, stitcher.acceptedFrames > 0, let t = tracker, t.active(at: now) {
            // While a frame could not be joined, the advice to scroll back stays up (`report`).
            if !recovering { reportGauge(t.gauge) }
            guard let r = tracker?.capture(at: now) else { return }
            request = r
        }
        let auto = autoScroll
        // The region follows the window if it is moved.
        config.sourceRect = displayRect()
        inFlight = true
        Task { @MainActor in
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                inFlight = false
                captureFailures += 1
                if captureFailures == 25, !finishing { // about three seconds of failures
                    stopAuto()
                    update(L("截不到画面了（\(error.localizedDescription)）· 点完成可保存已截的部分", "Can't capture the window (\(error.localizedDescription)) · press Done to save what you have"))
                }
                return
            }
            captureFailures = 0
            guard let frame = PixelFrame(cgImage: image) else {
                inFlight = false
                return
            }
            // Part of the picture is outside the window (moved off screen, or the capture area slid):
            // it is not the picked region, so it is neither stitched nor counted as lost.
            if frame.reachesOutsideWindow {
                inFlight = false
                update(L("截取区域跑到窗口外面了，这一张不拼 · 把窗口挪回原处或点完成", "The capture area is outside the window, this frame is skipped · move the window back or press Done"))
                return
            }
            if tracker == nil {
                tracker = ManualTracker(body: frame.height, pixelScale: stitcher.pixelScale)
            }
            if let dump = ProcessInfo.processInfo.environment["JZ_DUMP"] {
                dumpIndex += 1
                let name = String(format: "f%04d.png", dumpIndex)
                try? Exporter.writePNG(image, to: URL(fileURLWithPath: dump).appendingPathComponent(name))
                // `replay` reads this to know which frames came after input that may have scrolled.
                let line = "\(name)\t\(inputSeen ? 1 : 0)\n"
                let log = URL(fileURLWithPath: dump).appendingPathComponent("input.tsv")
                if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? Data(line.utf8).write(to: log) }
            }
            if auto {
                switch settler.observe(frame, at: now) {
                case .waiting:
                    inFlight = false
                    return
                case .timedOut:
                    // Never stitch a picture that is still moving, and do not scroll on either.
                    inFlight = false
                    settler.reset()
                    stopAuto()
                    update(L("画面一直在动，停不稳，自动已暂停 · 等它安静下来再点自动，或点完成保存已收的部分", "The picture keeps moving, auto-scroll paused · press Auto again once it settles, or Done to keep what you have"))
                    return
                case .ready:
                    settler.reset()
                }
            }
            let stitcher = self.stitcher
            let expected = auto ? pacer.expected : request?.expected
            let tolerance = auto ? max(16 * stitcher.pixelScale, frame.height * 12 / 100) : (request?.tolerance ?? 0)
            let (outcome, height, frames, dropped, edges, share, unjoined) = await withCheckedContinuation { cont in
                work.async {
                    let o = stitcher.add(frame, expected: expected, tolerance: tolerance)
                    cont.resume(returning: (o, stitcher.canvasRows, stitcher.acceptedFrames, stitcher.lostFrames, stitcher.edgeBands, stitcher.movingShare, stitcher.needsRecovery))
                }
            }
            inFlight = false
            guard !finishing else { return }
            if ProcessInfo.processInfo.environment["JZ_TEST_OWNER"] != nil { print("frame \(dumpIndex): \(outcome)") }
            if !auto {
                switch (outcome, request) {
                case (.shifted(let d), let r?) where d != 0: tracker?.placed(d: d, capture: r, edges: edges)
                case (.lost, let r?): tracker?.lost(r)
                case (.shifted(let d), nil) where d != 0: tracker?.resync()
                case (.first, _): tracker?.resync()
                default: break
                }
            }
            // Manual mode: the seam line and overlap limits follow the part of the view that scrolls.
            if case .shifted(let d) = outcome, d != 0 { tracker?.body = max(64, Int((Double(frame.height) * share).rounded())) }
            if unjoined && !recovering && !auto {
                // Say it at once, with a sound: the longer the wheel keeps going, the further back it is.
                NSSound(named: "Funk")?.play()
            }
            recovering = unjoined
            report(outcome, height: height, frames: frames, dropped: dropped)
            guard autoScroll else { return }
            switch pacer.next(after: outcome, movingShare: share) {
            case .resample:
                break // the next settled frame is matched again, without scrolling
            case .scroll(let fraction):
                scrollOnce(by: fraction)
            case .pause:
                stopAuto()
                update(L("这一段一直对不上，自动已暂停 · 可以手动往回滚一点再点自动，或点完成保存已收的部分", "This part keeps failing to line up, auto-scroll paused · scroll back a little and press Auto again, or press Done to keep what you have"))
            case .finish:
                update(L("到底了，正在生成…", "Reached the end, saving…"))
                finish()
            }
        }
    }

    private func report(_ o: Stitcher.Outcome, height: Int, frames: Int, dropped: Int) {
        let shown = max(height, Int(sourceRect.height * CGFloat(scale)))
        var text = L("已收 \(frames) 张 · 长 \(shown) px", "\(frames) taken · \(shown) px tall")
        if o == .lost || (recovering && !autoScroll) {
            text = autoScroll
                ? L("这一下没对上，往回退一点重来 · ", "Lost the place, backing up to retry · ") + text
                : L("滚过头了，往回滚一点就能接上 · ", "Scrolled too far, scroll back a little to reconnect · ") + text
        } else if case .shifted(let d) = o, d != 0, !autoScroll {
            text = L("刚接上 · ", "Joined · ") + text
        }
        update(text)
    }

    /// The overlap gauge, in words until the HUD has a bar for it.
    private func reportGauge(_ g: ManualTracker.Gauge) {
        let scalePx = max(1, stitcher.pixelScale)
        switch g {
        case .idle: break
        case .approaching(let rows) where rows > (tracker?.body ?? 0) / 10:
            update(L("再往下滚 \(rows / scalePx) 点就拍下一张", "\(rows / scalePx) pt more and the next frame is taken"))
        case .approaching, .ready:
            update(L("到了，停一下", "There, hold still"))
        case .over:
            update(L("滚过头了，往回滚一点", "Too far, scroll back a little"))
        }
    }

    /// Wheel and trackpad events (inertia included) over the picked region of the target window.
    private func startWheelMonitor() {
        wheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            let dy = e.scrollingDeltaY, precise = e.hasPreciseScrollingDeltas
            let loc = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, !self.autoScroll else { return }
                // AppKit's screen coordinates start bottom-left; window bounds start top-left.
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let point = CGPoint(x: loc.x, y: top - loc.y)
                let frame = WindowList.bounds(of: self.pick.windowID) ?? self.pick.windowFrame
                let region = self.sourceRect.offsetBy(dx: frame.minX, dy: frame.minY)
                guard region.contains(point), WindowList.frontmost(at: point)?.id == self.pick.windowID else { return }
                self.noteInput()
                self.tracker?.wheel(deltaY: dy, precise: precise, at: self.now)
            }
        }
        // Keys (arrows, space, page down) and dragging a scroll bar move pages without the wheel.
        // Any of them counts, wherever it happens: wrongly assuming a move only costs leniency.
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteInput() }
        }
    }

    private func noteInput() {
        guard !inputSeen else { return }
        inputSeen = true
        let stitcher = self.stitcher
        // On the stitch queue, so it lands before any frame captured after it.
        work.async { stitcher.scrollStarted = true }
    }

    // MARK: - Auto scroll

    private func toggleAuto() {
        if autoScroll {
            stopAuto()
            return
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            update(L("自动滚动要先在 系统设置 › 隐私与安全性 › 辅助功能 里打开卷轴PDF", "Auto-scroll needs Living Scroll PDF turned on in System Settings › Privacy & Security › Accessibility"))
            return
        }
        bringTargetToFront()
        CGWarpMouseCursorPosition(scrollPoint())
        autoScroll = true
        pacer = AutoPacer()
        settler.reset()
        hud.setAuto(true)
        lastScroll = Date().addingTimeInterval(0.3)
    }

    private func stopAuto() {
        autoScroll = false
        hud.setAuto(false)
    }

    /// The picked region in the captured display's coordinates, where the window is now.
    private func displayRect() -> CGRect {
        let frame = WindowList.bounds(of: pick.windowID) ?? pick.windowFrame
        return sourceRect.offsetBy(dx: frame.minX - display.minX, dy: frame.minY - display.minY)
    }

    private func scrollPoint() -> CGPoint {
        let frame = WindowList.bounds(of: pick.windowID) ?? pick.windowFrame
        return CGPoint(x: frame.minX + sourceRect.midX, y: frame.minY + sourceRect.midY)
    }

    /// Scrolls the content by `fraction` of the base step; negative goes back up.
    private func scrollOnce(by fraction: Double) {
        let point = scrollPoint()
        // Never scroll whatever happens to be on top: the wheel goes to the window under the point.
        guard WindowList.frontmost(at: point)?.id == pick.windowID else {
            stopAuto()
            update(L("目标窗口被别的窗口挡住了，自动滚动已暂停——挪开后再点一次", "Another window is covering the target, auto-scroll paused. Move it away and press again"))
            return
        }
        let step = Int32((max(40, sourceRect.height * 0.45) * fraction).rounded())
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0) {
            e.location = point
            e.post(tap: .cghidEventTap)
        }
        noteInput()
        pacer.sent(fraction)
        settler.reset()
        lastScroll = Date()
    }

    /// Raises the picked window through Accessibility; plain activation is refused for
    /// background apps on recent macOS.
    private func bringTargetToFront() {
        let app = AXUIElementCreateApplication(pick.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let target = WindowList.bounds(of: pick.windowID) ?? pick.windowFrame
        for w in windows {
            var pos: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size)
            var p = CGPoint.zero, sz = CGSize.zero
            if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
            if let size { AXValueGetValue(size as! AXValue, .cgSize, &sz) }
            if abs(p.x - target.minX) < 2, abs(p.y - target.minY) < 2, abs(sz.width - target.width) < 2 {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                break
            }
        }
    }

    // MARK: - End

    private func finish() {
        guard !finishing else { return }
        finishing = true
        autoScroll = false
        timer?.invalidate()
        hud.setBusy()
        update(L("正在生成 PDF…", "Saving PDF…"))
        let stitcher = self.stitcher
        let base = CaptureRecord(appName: pick.appName, windowTitle: pick.windowTitle, startedAt: startedAt,
                                 endedAt: Date(), framesStitched: 0, droppedFrames: 0, pixelWidth: 0,
                                 pixelHeight: 0, pointScale: scale)
        Task { @MainActor in
            while inFlight { try? await Task.sleep(nanoseconds: 30_000_000) }
            let result: Result<URL, Error>? = await withCheckedContinuation { cont in
                work.async {
                    guard let image = stitcher.finish() else { cont.resume(returning: nil); return }
                    var rec = base
                    rec.framesStitched = stitcher.acceptedFrames
                    rec.droppedFrames = stitcher.lostFrames
                    // Ending while a frame could not be placed: what was on screen then is not in the
                    // result. A frame lost and later reconnected leaves nothing missing.
                    if stitcher.needsRecovery {
                        rec.isPartial = true
                        rec.partialReason = "ended-before-reconnecting"
                    }
                    rec.pixelWidth = image.width
                    rec.pixelHeight = image.height
                    cont.resume(returning: Result { try Exporter.export(image, record: rec) })
                }
            }
            close()
            switch result {
            case .success(let pdf):
                if ProcessInfo.processInfo.environment["JZ_TEST_OWNER"] != nil {
                    print("exported \(pdf.path)")
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([pdf])
                    NSWorkspace.shared.open(pdf)
                }
            case .failure(let error):
                alert(L("保存失败", "Couldn't save"), "\(error)")
            case nil:
                alert(L("没有截到画面", "Nothing was captured"), L("请确认已在 系统设置 › 隐私与安全性 › 屏幕与系统录音 里打开卷轴PDF。", "Check that Living Scroll PDF is on in System Settings › Privacy & Security › Screen & System Audio Recording."))
            }
            end()
        }
    }

    private func cancel() {
        guard !finishing else { return }
        finishing = true
        autoScroll = false
        timer?.invalidate()
        close()
        end()
    }

    private func fail(_ message: String) {
        guard !finishing else { return }
        finishing = true
        close()
        alert(L("没法开始", "Can't start"), message)
        end()
    }

    private func end() {
        guard !ended else { return }
        ended = true
        onEnd(self)
    }

    private func close() {
        if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
        if let m = inputMonitor { NSEvent.removeMonitor(m); inputMonitor = nil }
        border.orderOut(nil)
        hud.orderOut(nil)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: - Chrome

    private func update(_ text: String) {
        status = text
        hud.setStatus(text)
    }

    /// Keeps the red frame and the control bar glued to the window if it moves.
    private func placeChrome() {
        let frame = WindowList.bounds(of: pick.windowID) ?? pick.windowFrame
        let region = sourceRect.offsetBy(dx: frame.minX, dy: frame.minY)
        let r = Coords.toAppKit(region)
        border.setFrame(r.insetBy(dx: -3, dy: -3), display: true)

        let size = hud.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(r) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        var origin = NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 10)
        if origin.y < screen.minY { origin.y = r.maxY + 10 }
        if origin.y + size.height > screen.maxY { origin.y = r.minY + 10 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        hud.setFrameOrigin(origin)
    }
}

private final class BorderWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = BorderView()
    }
}

private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = 3
        p.setLineDash([10, 6], count: 2, phase: 0)
        p.stroke()
    }
}

final class HUDPanel: NSPanel {
    var onAuto: () -> Void = {}
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}

    private let label = NSTextField(labelWithString: "")
    private let autoButton = NSButton(title: L("自动滚到底", "Auto-scroll"), target: nil, action: nil)
    private var buttons: [NSButton] = []

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 46),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 560, height: 46))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        autoButton.target = self
        autoButton.action = #selector(autoTapped)
        let done = NSButton(title: L("完成", "Done"), target: self, action: #selector(doneTapped))
        done.keyEquivalent = "\r"
        done.bezelColor = .systemRed
        let cancel = NSButton(title: L("取消", "Cancel"), target: self, action: #selector(cancelTapped))
        buttons = [autoButton, done, cancel]
        for b in buttons { b.bezelStyle = .rounded; b.controlSize = .regular }

        let stack = NSStackView(views: [label, autoButton, done, cancel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        stack.frame = bg.bounds
        stack.autoresizingMask = [.width, .height]
        bg.addSubview(stack)
        contentView = bg
    }

    func setStatus(_ text: String) { label.stringValue = text }
    func setAuto(_ on: Bool) { autoButton.title = on ? L("停止自动", "Stop") : L("自动滚到底", "Auto-scroll") }
    /// Export has started; nothing on the bar can change the outcome any more.
    func setBusy() { buttons.forEach { $0.isEnabled = false } }

    @objc private func autoTapped() { onAuto() }
    @objc private func doneTapped() { onDone() }
    @objc private func cancelTapped() { onCancel() }
}
