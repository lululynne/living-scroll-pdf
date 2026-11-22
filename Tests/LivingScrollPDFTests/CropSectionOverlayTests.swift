import AppKit
import XCTest
@testable import LivingScrollPDF

final class CropSectionOverlayTests: XCTestCase {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class ScrollView: NSScrollView {
        var receivedWheel: NSEvent?
        override func scrollWheel(with event: NSEvent) {
            receivedWheel = event
            super.scrollWheel(with: event)
        }
    }

    @MainActor private final class Viewport {
        let window: NSWindow
        let scroll = ScrollView()
        let document: NSView
        let overlay: CropSectionOverlay

        init(height: Int = 32_000) {
            _ = NSApplication.shared
            let frame = NSRect(x: 0, y: 0, width: 400, height: 240)
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            scroll.allowsMagnification = true
            scroll.hasVerticalScroller = true
            document = DocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
            scroll.documentView = document
            overlay = CropSectionOverlay(frame: document.bounds)
            document.addSubview(overlay)
            scroll.layoutSubtreeIfNeeded()
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: overlay.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }

        func click(x: CGFloat = 100, y: CGFloat) throws {
            let point = CGPoint(x: x, y: y)
            overlay.mouseDown(with: try event(.leftMouseDown, at: point))
            overlay.mouseUp(with: try event(.leftMouseUp, at: point))
        }
    }

    @MainActor func testClicksAcrossScrollAndZoomSwapLinesInOriginalPixels() throws {
        let view = Viewport()
        defer { view.window.close() }
        view.document.scroll(CGPoint(x: 0, y: 24_000))
        try view.click(y: 24_060)
        XCTAssertNil(view.overlay.selectedRows)
        view.scroll.setMagnification(2, centeredAt: CGPoint(x: 140, y: 24_060))
        view.document.scroll(CGPoint(x: 0, y: 120))
        try view.click(y: 175)
        XCTAssertEqual(view.overlay.selectedRows, 175..<24_060)
        view.scroll.magnification = 0.5
        XCTAssertEqual(view.overlay.selectedRows, 175..<24_060)
    }

    @MainActor func testWheelAndTrackpadEventsReachTheNativeScrollViewBetweenClicks() throws {
        let view = Viewport()
        defer { view.window.close() }
        view.document.scroll(CGPoint(x: 0, y: 500))
        try view.click(y: 560)
        for unit in [CGScrollEventUnit.line, .pixel] {
            let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: unit,
                wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
            let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
            view.overlay.scrollWheel(with: event)
            XCTAssertTrue(view.scroll.receivedWheel === event)
            XCTAssertNil(view.overlay.selectedRows)
        }
        view.document.scroll(CGPoint(x: 0, y: 1_000))
        try view.click(y: 1_100)
        XCTAssertEqual(view.overlay.selectedRows, 560..<1_100)
    }

    @MainActor func testOneGestureSelectionCrossingAndCoincidentHandles() throws {
        let view = Viewport(), overlay = view.overlay
        defer { view.window.close() }
        func down(_ x: CGFloat, _ y: CGFloat) throws {
            overlay.mouseDown(with: try view.event(.leftMouseDown, at: CGPoint(x: x, y: y)))
        }
        func drag(_ x: CGFloat, _ y: CGFloat) throws {
            overlay.mouseDragged(with: try view.event(.leftMouseDragged, at: CGPoint(x: x, y: y)))
        }
        func up(_ x: CGFloat, _ y: CGFloat) throws {
            overlay.mouseUp(with: try view.event(.leftMouseUp, at: CGPoint(x: x, y: y)))
        }

        try down(100, 80)
        try drag(100, 130)
        try up(100, 130)
        XCTAssertEqual(overlay.selectedRows, 80..<130)
        let left = overlay.visibleRect.minX + 12, right = overlay.visibleRect.maxX - 12
        try down(left, 80)
        try drag(left, 149)
        XCTAssertEqual(overlay.selectedRows, 130..<149)
        try drag(left, 130)
        try up(left, 130)
        XCTAssertEqual(overlay.selectedRows, 130..<130)
        try down(right, 130)
        try drag(right, 131)
        try up(right, 131)
        XCTAssertEqual(overlay.selectedRows, 130..<131)
        try down(left, 130)
        try drag(left, 80)
        try up(left, 80)
        XCTAssertEqual(overlay.selectedRows, 80..<131)
    }

    @MainActor func testOnlyRowsOutsideTheSelectionAreDimmed() throws {
        let view = Viewport(height: 240), overlay = view.overlay
        defer { view.window.close() }
        try view.click(y: 60)
        try view.click(y: 180)
        let preview = NSImage(size: overlay.bounds.size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            overlay.draw(rect)
            return true
        }
        let image = try XCTUnwrap(preview.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixels = try XCTUnwrap(PixelFrame(cgImage: image))
        for (y, dimmed) in [(15, true), (120, false), (225, true)] {
            let row = Int(CGFloat(y) * CGFloat(pixels.height) / overlay.bounds.height)
            let column = Int(190 * CGFloat(pixels.width) / overlay.bounds.width)
            let offset = (row * pixels.width + column) * 4
            XCTAssertEqual(pixels.bytes[offset + 3], 255)
            if dimmed {
                XCTAssertLessThan(pixels.bytes[offset], 200)
                XCTAssertGreaterThan(pixels.bytes[offset], 40)
            } else {
                XCTAssertEqual(pixels.bytes[offset], 255)
            }
        }
    }

    @MainActor func testStationaryPointerScrollsAtBothEdgesAndStopsOnRelease() async throws {
        let view = Viewport(), overlay = view.overlay
        defer { view.window.close() }
        view.document.scroll(CGPoint(x: 0, y: 14_000))
        try view.click(y: 14_060)
        try view.click(y: 14_130)
        overlay.mouseDown(with: try view.event(.leftMouseDown, at: CGPoint(x: 120, y: 14_130)))
        let bottom = CGPoint(x: 120, y: overlay.visibleRect.maxY - 1)
        overlay.mouseDragged(with: try view.event(.leftMouseDragged, at: bottom))
        let initialTop = overlay.visibleRect.minY
        try await waitForScroll { overlay.visibleRect.minY > initialTop + 90 }
        XCTAssertEqual(try XCTUnwrap(overlay.selectedRows).upperBound, Int((overlay.visibleRect.maxY - 1).rounded()), accuracy: 1)

        let top = CGPoint(x: 120, y: overlay.visibleRect.minY + 1)
        overlay.mouseDragged(with: try view.event(.leftMouseDragged, at: top))
        let beforeReverse = overlay.visibleRect.minY
        try await waitForScroll { overlay.visibleRect.minY < beforeReverse - 90 }
        let release = CGPoint(x: 120, y: overlay.visibleRect.minY + 1)
        overlay.mouseUp(with: try view.event(.leftMouseUp, at: release))
        let stopped = overlay.visibleRect.minY, rows = overlay.selectedRows
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(overlay.visibleRect.minY, stopped)
        XCTAssertEqual(overlay.selectedRows, rows)
    }

    @MainActor private func waitForScroll(_ reached: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !reached(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(reached(), "A stationary drag should scroll for several successive timer ticks")
    }

    @MainActor func testClampsToImageEdgesAndEscapeEndsTracking() async throws {
        let view = Viewport(height: 600), overlay = view.overlay
        defer { view.window.close() }
        try view.click(y: 0)
        view.document.scroll(CGPoint(x: 0, y: 600))
        try view.click(y: 599)
        let handle = CGPoint(x: 110, y: 599), outside = CGPoint(x: 110, y: 620)
        overlay.mouseDown(with: try view.event(.leftMouseDown, at: handle))
        overlay.mouseDragged(with: try view.event(.leftMouseDragged, at: outside))
        XCTAssertEqual(overlay.selectedRows, 0..<600)
        overlay.mouseDragged(with: try view.event(.leftMouseDragged, at: CGPoint(x: 110, y: overlay.visibleRect.minY + 1)))
        var cancelled = false
        overlay.onCancel = { [weak overlay] in cancelled = true; overlay?.removeFromSuperview() }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: view.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        overlay.keyDown(with: escape)
        XCTAssertTrue(cancelled)
        let stopped = view.document.visibleRect.minY
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.document.visibleRect.minY, stopped)
    }
}
