import AppKit
import XCTest
@testable import LivingScrollPDF

final class EditorWindowTests: XCTestCase {
    @MainActor func testOffscreenEditorFitsScrollsAndRoutesToolbarAndZoomShortcuts() async throws {
        _ = NSApplication.shared
        let width = 416, height = 23_269
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let record = CaptureRecord(appName: "Layout", windowTitle: "Long", startedAt: Date(), endedAt: Date(),
                                   framesStitched: 2, droppedFrames: 0, pixelWidth: width, pixelHeight: height, pointScale: 1)
        let library = ScrollLibrary(outputFolder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let editor = EditorWindow(document: EditDocument(name: "Layout", record: record), original: image,
                                  categoryID: nil, saved: true, library: library)
        let window = try XCTUnwrap(editor.window)
        let content = try XCTUnwrap(window.contentView)
        defer { window.close() }
        window.setContentSize(NSSize(width: 750, height: 490))
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(content)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
        let canvas = try XCTUnwrap(scroll.documentView as? EditCanvas)
        func activate(_ title: String) throws {
            let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        }
        try activate(EditorCopy.fit)
        XCTAssertEqual(scroll.magnification * CGFloat(width), scroll.contentView.frame.width, accuracy: 1)
        func shortcut(_ key: String, _ code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
        }
        let fitted = scroll.magnification
        try shortcut("=", 24)
        XCTAssertGreaterThan(scroll.magnification, fitted)
        try shortcut("-", 27)
        XCTAssertEqual(scroll.magnification, fitted, accuracy: 0.001)
        canvas.scroll(CGPoint(x: 0, y: height))
        XCTAssertEqual(scroll.documentVisibleRect.maxY, CGFloat(height), accuracy: 1)
        try activate(EditorCopy.title(for: .pen))
        canvas.beginInteraction(at: CGPoint(x: 12, y: height - 25))
        canvas.endInteraction(at: CGPoint(x: 25, y: height - 5))
        XCTAssertTrue(window.isDocumentEdited)
        XCTAssertEqual(canvas.layers.count, 1)
        try activate(EditorCopy.undo)
        XCTAssertTrue(canvas.layers.isEmpty)
        XCTAssertFalse(window.isVisible)
    }
}
