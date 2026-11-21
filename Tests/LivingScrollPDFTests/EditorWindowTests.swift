import AppKit
import XCTest
@testable import LivingScrollPDF

final class EditorWindowTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private func waitFor(_ message: String, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(try condition(), message)
    }

    private func capture() throws -> (CGImage, CaptureRecord) {
        let width = 192, height = 96
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return (try XCTUnwrap(context.makeImage()), CaptureRecord(appName: "Editor", windowTitle: "Private",
                startedAt: Date(), endedAt: Date(), framesStitched: 1, droppedFrames: 0,
                pixelWidth: width, pixelHeight: height, pointScale: 2))
    }

    @MainActor func testCapturePersistsBeforeEditingAndTypingAutosavesWithoutLosingFocus() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = ScrollLibrary(outputFolder: base.appendingPathComponent("Exports"), root: base.appendingPathComponent("Library"))
        let (image, record) = try capture()
        let saved = AppDelegate.saveCapture(image, record: record, library: library)
        XCTAssertNil(saved.error)
        let id = saved.document.id
        let recovered = try library.load(id)
        XCTAssertEqual(PixelFrame(cgImage: recovered.original)?.bytes, PixelFrame(cgImage: image)?.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.outputFolder.path))
        let editor = EditorWindow(document: recovered.document, original: image, categoryID: nil, saved: true, library: library)
        let window = try XCTUnwrap(editor.window)
        defer { window.close() }
        let canvas = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? EditCanvas }.first)
        canvas.tool = .text
        canvas.beginInteraction(at: CGPoint(x: 12, y: 10))
        let typing = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        typing.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        try await waitFor("text is recoverable before Return") { try library.load(id).document.layers.first?.text == "draft" }
        XCTAssertTrue(typing.superview === canvas)
        XCTAssertTrue(canvas.layers.isEmpty)
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        typing.keyDown(with: esc)
        try await waitFor("Escape rolls back the on-disk draft") { try library.load(id).document.layers.isEmpty }
        canvas.tool = .pen
        canvas.beginInteraction(at: CGPoint(x: 8, y: 20))
        canvas.endInteraction(at: CGPoint(x: 130, y: 72))
        let stroke = try XCTUnwrap(canvas.layers.first)
        try await waitFor("committed stroke autosaved") { try library.load(id).document.layers == [stroke] }
        XCTAssertEqual(try library.entries().map(\.id), [id])
    }

    @MainActor func testExportButtonPublishesCurrentLayersWhenLibraryCannotBeWritten() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default, base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let unavailable = base.appendingPathComponent("occupied-by-file")
        try Data([0]).write(to: unavailable)
        let library = ScrollLibrary(outputFolder: base.appendingPathComponent("Exports"), root: unavailable)
        let (image, record) = try capture()
        let capture = AppDelegate.saveCapture(image, record: record, library: library)
        XCTAssertNotNil(capture.error)
        let editor = EditorWindow(document: capture.document, original: image, categoryID: nil, saved: false, library: library)
        let window = try XCTUnwrap(editor.window)
        defer {
            if let sheet = NSApp.windows.first(where: { $0.sheetParent === window }) { window.endSheet(sheet) }
            window.close()
        }
        let views = descendants(try XCTUnwrap(window.contentView))
        let canvas = try XCTUnwrap(views.compactMap { $0 as? EditCanvas }.first)
        canvas.tool = .pen
        canvas.beginInteraction(at: CGPoint(x: 30, y: 50))
        canvas.endInteraction(at: CGPoint(x: 150, y: 50))
        var published: URL?
        editor.showExportedFiles = { published = $0 }
        let export = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == EditorCopy.export })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(export.action), to: export.target, from: export))
        try await waitFor("export completed independently of the library") { published != nil && !editor.isBusy }
        let pdf = try XCTUnwrap(published)
        XCTAssertNotNil(CGPDFDocument(pdf as CFURL)?.page(at: 1))
        let stem = pdf.deletingPathExtension()
        let data = try Data(contentsOf: stem.appendingPathExtension("json"))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(meta["editLayerCount"] as? Int, 1)
        XCTAssertEqual(meta["pngSHA256"] as? String, try Exporter.sha256(of: stem.appendingPathExtension("png")))
        XCTAssertTrue(window.isDocumentEdited)
    }

    @MainActor func testLibraryDeletionRequiresConfirmationAndPreservesExport() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let library = ScrollLibrary(outputFolder: base.appendingPathComponent("Exports"), root: base.appendingPathComponent("Library"))
        let (image, record) = try capture()
        let capture = AppDelegate.saveCapture(image, record: record, library: library)
        XCTAssertNil(capture.error)
        let id = capture.document.id
        let original = try library.originalURL(for: id)
        let pdf = try EditorExport.write(capture.document, original: image, folder: library.outputFolder)
        var removed: UUID?
        let browser = LibraryWindow(library: library, onDelete: { removed = $0 }, onOpen: { _ in })
        let window = try XCTUnwrap(browser.window)
        defer { window.close() }
        let views = descendants(try XCTUnwrap(window.contentView))
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == EditorCopy.deleteCapture })
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await waitFor("library shows the capture") { table.numberOfRows == 1 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        func requestDelete() throws -> NSWindow {
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
            // A sheet on an ordered-out AppKit window exposes sheetParent only.
            return try XCTUnwrap(NSApp.windows.first { $0.sheetParent === window })
        }
        let cancelSheet = try requestDelete()
        XCTAssertTrue(fm.fileExists(atPath: original.path))
        window.endSheet(cancelSheet, returnCode: .alertFirstButtonReturn)
        try await waitFor("cancel dismisses confirmation") { cancelSheet.sheetParent == nil }
        XCTAssertNil(removed)
        XCTAssertEqual(try library.load(id).document.id, id)
        window.endSheet(try requestDelete(), returnCode: .alertSecondButtonReturn)
        try await waitFor("confirmed deletion removes the library entry") { removed == id && table.numberOfRows == 0 }
        XCTAssertFalse(fm.fileExists(atPath: original.deletingLastPathComponent().path))
        XCTAssertTrue(fm.fileExists(atPath: pdf.path))
    }

    @MainActor func testOffscreenEditorFitsScrollsAndRoutesToolbarAndZoomShortcuts() async throws {
        _ = NSApplication.shared
        let width = 416, height = 23_269
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let record = CaptureRecord(appName: "Layout", windowTitle: "Long", startedAt: Date(), endedAt: Date(),
                                   framesStitched: 2, droppedFrames: 0, pixelWidth: width, pixelHeight: height, pointScale: 1)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = ScrollLibrary(outputFolder: base.appendingPathComponent("Exports"), root: base.appendingPathComponent("Library"))
        let editor = EditorWindow(document: EditDocument(name: "Layout", record: record), original: image,
                                  categoryID: nil, saved: true, library: library)
        let window = try XCTUnwrap(editor.window)
        let content = try XCTUnwrap(window.contentView)
        defer { window.close() }
        window.setContentSize(NSSize(width: 750, height: 490))
        content.layoutSubtreeIfNeeded()
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
