import AppKit

/// A temporary view over EditCanvas. Its coordinates are source pixels, including the
/// bottom boundary one row past the last pixel. It never changes the editing layers.
final class CropSectionOverlay: NSView {
    private enum Handle { case first, second }
    private var first: Int?
    private var second: Int?
    var selectedRows: Range<Int>? {
        guard let first, let second else { return nil }
        return min(first, second)..<max(first, second)
    }
    var onSelectionChange: (() -> Void)?
    var onCancel: (() -> Void)?

    private var grabbed: Handle?
    private var grabOffset: CGFloat = 0
    private var pressY: CGFloat = 0
    private var pointerInWindow: CGPoint?
    private var scrollTimer: Timer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        stopTracking()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                              name: NSView.boundsDidChangeNotification, object: clip)
        setAccessibilityLabel(L("截取范围", "Section to crop"))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func viewportChanged() {
        // Handles stay at the visible ends of each line even when zoomed in and panned.
        setNeedsDisplay(visibleRect)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let visible = visibleRect
        addCursorRect(visible, cursor: .crosshair)
        guard let range = selectedRows else { return }
        for row in [range.lowerBound, range.upperBound] {
            let strip = CGRect(x: visible.minX, y: CGFloat(row) - 8 / zoom, width: visible.width, height: 16 / zoom)
            let hit = strip.intersection(visible)
            if !hit.isEmpty { addCursorRect(hit, cursor: .resizeUpDown) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let first else { return }
        let visible = visibleRect.intersection(bounds), dirty = visible.intersection(dirtyRect)
        guard !dirty.isEmpty else { return }
        let range = selectedRows
        let top = CGFloat(range?.lowerBound ?? first)
        let bottom = range.map { CGFloat($0.upperBound) } ?? bounds.maxY
        NSColor.black.withAlphaComponent(0.44).setFill()
        if dirty.minY < top {
            CGRect(x: dirty.minX, y: dirty.minY, width: dirty.width, height: min(dirty.maxY, top) - dirty.minY).fill()
        }
        if dirty.maxY > bottom {
            let y = max(dirty.minY, bottom)
            CGRect(x: dirty.minX, y: y, width: dirty.width, height: dirty.maxY - y).fill()
        }
        drawGuide(at: top, start: true, in: visible)
        if range != nil { drawGuide(at: bottom, start: false, in: visible) }
    }

    private func drawGuide(at y: CGFloat, start: Bool, in visible: CGRect) {
        guard y >= visible.minY - 1 / zoom, y <= visible.maxY + 1 / zoom else { return }
        // Draw the controls in window points. Scaling the document only moves the line.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let t = NSAffineTransform()
        t.translateX(by: visible.minX, yBy: y)
        t.scale(by: 1 / zoom)
        t.concat()
        let width = visible.width * zoom
        NSColor.black.withAlphaComponent(0.80).setFill()
        NSRect(x: 0, y: -1.5, width: width, height: 3).fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: -0.75, width: width, height: 1.5).fill()
        let inset = min(12, width / 2)
        let knobX = start ? inset : width - inset
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX - 5, y: -5, width: 10, height: 10))
        knob.fill()
        NSColor.white.setStroke()
        knob.lineWidth = 1.5
        knob.stroke()

        var title = start ? L("开始线", "Start") : L("结束线", "End")
        if let range = selectedRows { title += " · \(range.count) px" }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white
        ]
        let text = title as NSString, size = text.size(withAttributes: attributes)
        let w = ceil(size.width) + 12, h = ceil(size.height) + 4
        let x = start ? inset + 10 : width - inset - 10 - w
        let spaceAbove = (y - visible.minY) * zoom, spaceBelow = (visible.maxY - y) * zoom
        let above = start ? spaceAbove >= h + 3 : spaceBelow < h + 3
        let pill = CGRect(x: max(0, min(x, width - w)), y: above ? -h - 3 : 3, width: w, height: h)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attributes)
    }

    private func handle(at point: CGPoint, first: Int, second: Int) -> Handle? {
        let a = abs(point.y - CGFloat(first)) * zoom, b = abs(point.y - CGFloat(second)) * zoom
        guard min(a, b) <= 9 else { return nil }
        if max(a, b) <= 9 {
            // Close or coincident lines remain separable by their left/right grips.
            if (point.x - visibleRect.minX) * zoom <= 24 { return first <= second ? .first : .second }
            if (visibleRect.maxX - point.x) * zoom <= 24 { return first <= second ? .second : .first }
        }
        return a <= b ? .first : .second
    }

    private func place(_ handle: Handle, at y: CGFloat) {
        let row: Int
        if y <= bounds.minY + 0.5 / zoom { row = 0 }
        else if y >= bounds.maxY - 0.5 / zoom { row = Int(bounds.height) }
        else { row = Int(min(bounds.height, max(0, y + grabOffset)).rounded()) }
        switch handle {
        case .first:
            guard first != row else { return }
            first = row
        case .second:
            guard second != row else { return }
            second = row
        }
        viewportChanged()
        onSelectionChange?()
    }

    override func mouseDown(with event: NSEvent) {
        stopTracking()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        pressY = event.locationInWindow.y
        if let first, let second {
            guard let hit = handle(at: point, first: first, second: second) else { return }
            grabbed = hit
            grabOffset = CGFloat(hit == .first ? first : second) - point.y
        } else {
            // A plain first click leaves the end unset; dragging that same press sets it.
            place(first == nil ? .first : .second, at: point.y)
            grabbed = .second
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabbed, second != nil || abs(event.locationInWindow.y - pressY) >= 3 else { return }
        pointerInWindow = event.locationInWindow
        let y = convert(event.locationInWindow, from: nil).y
        place(grabbed, at: y)
        if scrollStep(at: y) == 0 {
            stopScrolling()
        } else if scrollTimer == nil {
            let timer = Timer(timeInterval: 1 / 60, target: self, selector: #selector(scrollWhileDragging),
                              userInfo: nil, repeats: true)
            scrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func scrollStep(at y: CGFloat) -> CGFloat {
        let visible = visibleRect
        let zone = min(32, visible.height * zoom / 4)
        guard zone > 0 else { return 0 }
        let top = (y - visible.minY) * zoom, bottom = (visible.maxY - y) * zoom
        let distance = min(top, bottom)
        guard distance < zone else { return 0 }
        let strength = min(1, (zone - distance) / zone)
        let step = (2 + 30 * strength * strength) / zoom
        return top < bottom ? -min(step, visible.minY) : min(step, bounds.maxY - visible.maxY)
    }

    @objc private func scrollWhileDragging() {
        guard let pointerInWindow, let grabbed, let document = enclosingScrollView?.documentView else {
            stopScrolling()
            return
        }
        let delta = scrollStep(at: convert(pointerInWindow, from: nil).y)
        guard delta != 0 else { stopScrolling(); return }
        let origin = CGPoint(x: visibleRect.minX, y: visibleRect.minY + delta)
        document.scroll(document.convert(origin, from: self))
        // The window point didn't move. It now lies over a different source row.
        place(grabbed, at: convert(pointerInWindow, from: nil).y)
    }

    override func mouseUp(with event: NSEvent) {
        if let grabbed, pointerInWindow != nil || abs(event.locationInWindow.y - pressY) >= 3 {
            place(grabbed, at: convert(event.locationInWindow, from: nil).y)
        }
        stopTracking()
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func stopTracking() {
        stopScrolling()
        grabbed = nil
        grabOffset = 0
        pointerInWindow = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancelOperation(nil)
        case 51, 117: break // A crop gesture must not delete a selected annotation underneath.
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        stopTracking()
        onCancel?()
    }
}
