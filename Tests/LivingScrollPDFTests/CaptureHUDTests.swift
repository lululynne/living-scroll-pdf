import AppKit
import XCTest
@testable import LivingScrollPDF

final class CaptureHUDTests: XCTestCase {
    @MainActor func testReflowOfferFitsAndContinueOnlyAppearsDuringTheOffer() throws {
        _ = NSApplication.shared
        let hud = HUDPanel()
        defer { hud.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(hud.contentView)
        let label = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first)
        let title = L("接着拼", "Continue Here")
        func visibleButtons() -> [NSButton] {
            descendants(content).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        }
        XCTAssertFalse(visibleButtons().contains { $0.title == title })
        var hold = ManualTracker.HUDHold()
        let input = ManualTracker.HUDInput(now: 5, recovering: true, pageReflowed: true, browserTip: true,
                                           frames: 3, shownPx: 640)
        let offer = ManualTracker.hudLine(input, hold: &hold)
        hud.fit(availableWidth: 480)
        hud.setStatus(offer, detailed: true, showsContinue: true)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(label.stringValue, offer)
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping)
        let cell = try XCTUnwrap(label.cell)
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 1000))
        XCTAssertGreaterThanOrEqual(label.frame.height, needed.height - 1)
        XCTAssertLessThanOrEqual(content.bounds.width, 480)
        let buttons = visibleButtons()
        XCTAssertEqual(buttons.count, 4)
        for button in buttons {
            let bounds = button.convert(button.bounds, to: content)
            XCTAssertTrue(content.bounds.contains(bounds))
            XCTAssertLessThanOrEqual(bounds.maxY, label.frame.minY)
        }
        let button = try XCTUnwrap(buttons.first { $0.title == title })
        var clicks = 0
        hud.onContinue = { clicks += 1 }
        button.performClick(nil)
        XCTAssertEqual(clicks, 1)
        hud.setStatus("OK")
        XCTAssertFalse(visibleButtons().contains { $0.title == title })
        XCTAssertEqual(hud.frame.height, 46)
    }
}
