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

    @MainActor func testMemberGateKeepsCropVisibleAndExistingEditsAvailable() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, key = "membershipActive"
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = ScrollLibrary(outputFolder: base.appendingPathComponent("Exports"), root: base.appendingPathComponent("Library"))
        let (image, record) = try capture()
        let saved = try library.save(EditDocument(name: "Notes", record: record), original: image, categoryID: nil)
        let editor = EditorWindow(document: saved, original: image, categoryID: nil, saved: true, library: library)
        let window = try XCTUnwrap(editor.window)
        defer {
            if let sheet = NSApp.windows.first(where: { $0.sheetParent === window }) { window.endSheet(sheet) }
            window.close()
        }
        let views = descendants(try XCTUnwrap(window.contentView))
        let buttons = views.compactMap { $0 as? NSButton }
        let crop = try XCTUnwrap(buttons.first { $0.title.hasPrefix(L("截一段", "Crop Section")) })
        window.setContentSize(window.contentMinSize)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(try XCTUnwrap(crop.cell).cellSize.width, crop.bounds.width + 1)
        XCTAssertTrue(crop.isEnabled)
        XCTAssertTrue(crop.attributedTitle.string.contains(L("会员", "Pro")))
        crop.performClick(nil)
        let sheet = try XCTUnwrap(NSApp.windows.first { $0.sheetParent === window })
        let prompt = descendants(try XCTUnwrap(sheet.contentView))
        XCTAssertTrue(prompt.contains { ($0 as? NSTextField)?.stringValue == L("截一段是会员功能", "Crop Section is a member feature") })
        for title in [L("了解会员", "Learn About Membership"), L("好", "OK")] {
            XCTAssertTrue(prompt.contains { ($0 as? NSButton)?.title == title })
        }
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await waitFor("membership prompt closes") { sheet.sheetParent == nil }
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == EditorCopy.title(for: .mosaic) }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == EditorCopy.export }).isEnabled)
        XCTAssertEqual(try library.entries().map(\.id), [saved.id])
    }

    @MainActor func testCropFromLongEditorSavesPendingEditsAndExpiredMemberCanEditAndExportChild() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, memberKey = "membershipActive"
        let previous = defaults.object(forKey: memberKey)
        defaults.set(true, forKey: memberKey)
        defer { defaults.set(previous, forKey: memberKey) }
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let export = base.appendingPathComponent("Chosen")
        try fm.createDirectory(at: export, withIntermediateDirectories: true)
        let library = ScrollLibrary(root: base.appendingPathComponent("Private")) {
            ExportDestination(defaultFolder: base.appendingPathComponent("Desktop"), customFolder: export)
        }
        let width = 96, height = 30_041
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let record = CaptureRecord(appName: "Editor", windowTitle: "Receipt", startedAt: Date(), endedAt: Date(),
                                   framesStitched: 12, droppedFrames: 0, pixelWidth: width, pixelHeight: height, pointScale: 2)
        let category = try library.addCategory("Examples")
        let parent = try library.save(EditDocument(name: "Original", record: record), original: image, categoryID: category.id)
        let editor = EditorWindow(document: parent, original: image, categoryID: category.id, saved: true, library: library)
        let window = try XCTUnwrap(editor.window), content = try XCTUnwrap(window.contentView)
        defer { window.close() }
        window.setContentSize(window.contentMinSize)
        content.layoutSubtreeIfNeeded()
        let views = descendants(content), buttons = views.compactMap { $0 as? NSButton }
        let canvas = try XCTUnwrap(views.compactMap { $0 as? EditCanvas }.first)
        let crop = try XCTUnwrap(buttons.first { $0.title == EditorCopy.cropSection })
        let save = try XCTUnwrap(buttons.first { $0.title == EditorCopy.saveSection })
        let pen = try XCTUnwrap(buttons.first { $0.title == EditorCopy.title(for: .pen) })
        func clickRow(_ row: Int, on overlay: CropSectionOverlay) throws {
            let point = overlay.convert(CGPoint(x: 45, y: row), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                if type == .leftMouseDown { overlay.mouseDown(with: event) } else { overlay.mouseUp(with: event) }
            }
        }
        crop.performClick(nil)
        content.layoutSubtreeIfNeeded()
        let short = try XCTUnwrap(canvas.subviews.compactMap { $0 as? CropSectionOverlay }.first)
        XCTAssertFalse(pen.isEnabled)
        XCTAssertFalse(save.isEnabled)
        try clickRow(50, on: short)
        try clickRow(40, on: short)
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(views.contains { ($0 as? NSTextField)?.stringValue == EditorCopy.cropTooShort })
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                               isARepeat: false, keyCode: 53))
        window.makeFirstResponder(try XCTUnwrap(buttons.first { $0.title == EditorCopy.fit }))
        window.sendEvent(esc)
        XCTAssertNil(short.superview)
        XCTAssertTrue(pen.isEnabled)
        XCTAssertEqual(try library.load(parent.id).document.revision, parent.revision)

        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == EditorCopy.name })
        field.stringValue = "Notes"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        canvas.tool = .mosaic
        canvas.beginInteraction(at: CGPoint(x: 10, y: 10))
        canvas.endInteraction(at: CGPoint(x: 85, y: 80))
        let mask = try XCTUnwrap(canvas.layers.first)
        var openedID: UUID?
        editor.onOpenSection = { openedID = $0 }
        crop.performClick(nil)
        content.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(canvas.subviews.compactMap { $0 as? CropSectionOverlay }.first)
        try clickRow(30, on: overlay)
        XCTAssertFalse(save.isEnabled)
        canvas.scroll(CGPoint(x: 0, y: height))
        try clickRow(30_035, on: overlay)
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(save.action), to: save.target, from: save))
        XCTAssertTrue(editor.isBusy)
        let progress = try XCTUnwrap(NSApp.windows.first { $0.sheetParent === window })
        XCTAssertTrue(descendants(try XCTUnwrap(progress.contentView)).contains { $0 is NSProgressIndicator })
        try await waitFor("the new library entry opens after the private save") { openedID != nil && !editor.isBusy }
        let id = try XCTUnwrap(openedID), child = try library.load(id)
        XCTAssertNil(overlay.superview)
        XCTAssertEqual(child.document.name, L("Notes-片段1", "Notes-Section 1"))
        XCTAssertEqual(child.categoryID, category.id)
        XCTAssertEqual(child.original.height, 30_005)
        XCTAssertEqual(child.document.layers, [mask.translated(dx: 0, dy: -30)])
        XCTAssertEqual(try library.load(parent.id).document.layers, [mask])
        XCTAssertEqual(try library.load(parent.id).document.name, "Notes")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: export.path), [])

        defaults.set(false, forKey: memberKey)
        let next = EditorWindow(document: child.document, original: child.original, categoryID: child.categoryID, saved: true, library: library)
        let nextWindow = try XCTUnwrap(next.window)
        defer {
            if let sheet = NSApp.windows.first(where: { $0.sheetParent === nextWindow }) { nextWindow.endSheet(sheet) }
            nextWindow.close()
        }
        let nextViews = descendants(try XCTUnwrap(nextWindow.contentView))
        let nextCanvas = try XCTUnwrap(nextViews.compactMap { $0 as? EditCanvas }.first)
        let mosaic = try XCTUnwrap(nextViews.compactMap { $0 as? NSButton }.first { $0.title == EditorCopy.title(for: .mosaic) })
        mosaic.performClick(nil)
        nextCanvas.beginInteraction(at: CGPoint(x: 15, y: 120))
        nextCanvas.endInteraction(at: CGPoint(x: 80, y: 150))
        var published: [URL]?
        next.showExportedFiles = { published = $0 }
        let exportButton = try XCTUnwrap(nextViews.compactMap { $0 as? NSButton }.first { $0.title == EditorCopy.export })
        exportButton.performClick(nil)
        try await waitFor("expired membership still allows export through the editor") { published != nil }
        let files = try XCTUnwrap(published)
        XCTAssertEqual(files.map(\.pathExtension), ["png", "pdf"])
        XCTAssertTrue(files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == export.standardizedFileURL.path })
        XCTAssertEqual(try library.load(id).document.layers.count, 2)
        XCTAssertThrowsError(try library.cropSection(of: child.document, original: child.original, rows: 0..<60)) { XCTAssertTrue($0 is Membership.Required) }
        XCTAssertEqual(try library.entries().count, 2)
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

    @MainActor func testPartialSuffixCanBeRemovedBeforeSavingAndExporting() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = ScrollLibrary(outputFolder: base.appendingPathComponent("Exports"), root: base.appendingPathComponent("Library"))
        let (image, complete) = try capture()
        var record = complete
        record.isPartial = true
        let initial = AppDelegate.saveCapture(image, record: record, library: library)
        XCTAssertNil(initial.error)
        XCTAssertTrue(initial.document.name.hasSuffix(L("-未完成", "-partial")))
        let editor = EditorWindow(document: initial.document, original: image, categoryID: nil, saved: true, library: library)
        let window = try XCTUnwrap(editor.window)
        defer { window.close() }
        let views = descendants(try XCTUnwrap(window.contentView))
        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == EditorCopy.name })
        field.stringValue = "Trip"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await waitFor("autosave keeps the chosen partial name") { try library.entries().first?.name == "Trip" }
        var selections: [[URL]] = []
        editor.showExportedFiles = { selections.append($0) }
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == EditorCopy.export })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        try await waitFor("export finishes") { !selections.isEmpty && !editor.isBusy }
        XCTAssertEqual(field.stringValue, "Trip")
        let files = ["Trip.png", "Trip.pdf"].map { library.outputFolder.appendingPathComponent($0) }
        XCTAssertEqual(selections, [files])
        XCTAssertTrue(try library.load(initial.document.id).document.record.isPartial)
        XCTAssertEqual(button.title, L("导出（PNG + PDF）", "Export (PNG + PDF)"))
        let sheet = try XCTUnwrap(NSApp.windows.first { $0.sheetParent === window })
        let notice = descendants(try XCTUnwrap(sheet.contentView))
        let labels = notice.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains(L("已存好 PNG 和 PDF 各一份", "Saved one PNG and one PDF")))
        XCTAssertTrue(labels.contains((library.outputFolder.path as NSString).abbreviatingWithTildeInPath))
        let titles = notice.compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains(L("打开文件夹", "Open Folder")))
        XCTAssertTrue(titles.contains(L("好", "OK")))
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await waitFor("Open Folder selects the same two files again") { selections == [files, files] }
    }

    @MainActor func testRedactedExportShowsActualFallbackPathAndKeepsPrivateOriginalNotice() async throws {
        try await checkRedactedExport(readOnlyIndex: false)
    }

    @MainActor func testRedactedExportExplainsSavedOriginalWhenRecordingTheExportFails() async throws {
        try await checkRedactedExport(readOnlyIndex: true)
    }

    @MainActor private func checkRedactedExport(readOnlyIndex: Bool) async throws {
        _ = NSApplication.shared
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let chosen = root.appendingPathComponent("Removable", isDirectory: true)
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        let fallback = root.appendingPathComponent("Desktop/卷轴PDF", isDirectory: true)
        let privateRoot = root.appendingPathComponent("Library")
        let library = ScrollLibrary(root: privateRoot) {
            ExportDestination(defaultFolder: fallback, customFolder: chosen)
        }
        let defaults = UserDefaults.standard, key = "explainedPrivateRedactionOriginal"
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer { defaults.set(previous, forKey: key) }

        let (image, record) = try capture()
        var draft = EditDocument(name: "Redacted", record: record)
        draft.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 2, y: 2, width: 32, height: 32))]
        let document = try library.save(draft, original: image, categoryID: nil)
        if readOnlyIndex { try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: privateRoot.path) }
        defer { if readOnlyIndex { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateRoot.path) } }
        let editor = EditorWindow(document: document, original: image, categoryID: nil, saved: true, library: library)
        let window = try XCTUnwrap(editor.window)
        defer { window.close() }
        let views = descendants(try XCTUnwrap(window.contentView))
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == EditorCopy.export })
        var selections: [[URL]] = []
        editor.showExportedFiles = { selections.append($0) }
        try fm.removeItem(at: chosen)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        try await waitFor("redacted pair revealed") { !selections.isEmpty && !editor.isBusy }
        let files = ["Redacted.png", "Redacted.pdf"].map { fallback.appendingPathComponent($0) }
        XCTAssertEqual(selections, [files])
        let sheet = try XCTUnwrap(NSApp.windows.first { $0.sheetParent === window })
        let labels = descendants(try XCTUnwrap(sheet.contentView)).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains(EditorCopy.exported))
        let body = try XCTUnwrap(labels.first { $0.hasPrefix(ExportUI.path(fallback)) })
        let expected = [ExportUI.path(fallback), EditorCopy.desktopFallback("卷轴PDF"),
                        EditorCopy.redactionExported, EditorCopy.privateOriginalNotice].joined(separator: "\n")
        if readOnlyIndex { XCTAssertTrue(body.hasPrefix(expected + "\n" + EditorCopy.exportedWithoutLibrary)) }
        else { XCTAssertEqual(body, expected) }
        XCTAssertTrue(defaults.bool(forKey: key))
        // Reconnecting the chosen disk must not change which files Open Folder reveals.
        try fm.createDirectory(at: chosen, withIntermediateDirectories: false)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await waitFor("the button reveals the actual fallback pair") { selections == [files, files] }
        XCTAssertNotNil(try library.load(document.id).original)
    }

    @MainActor func testLibraryChangesReachAnOpenEditorAndSurviveItsNextAutosave() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let output = base.appendingPathComponent("Exports"), root = base.appendingPathComponent("Library")
        let library = ScrollLibrary(outputFolder: output, root: root)
        let (image, record) = try capture()
        let from = try library.addCategory("Inbox"), to = try library.addCategory("Filed")
        let saved = try library.save(EditDocument(name: "Old name", record: record), original: image, categoryID: from.id)
        let editor = EditorWindow(document: saved, original: image, categoryID: from.id, saved: true, library: library)
        let window = try XCTUnwrap(editor.window)
        defer { window.close() }
        let views = descendants(try XCTUnwrap(window.contentView))
        let name = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == EditorCopy.name })
        let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == EditorCopy.category })
        try library.rename(id: saved.id, to: "From the library")
        try library.setCategory(ids: [saved.id], category: to.id)
        try await waitFor("open editor shows the library name and category") {
            name.stringValue == "From the library" && picker.selectedItem?.representedObject as? UUID == to.id
        }
        // A separate process can move the same row without notifying this window.
        try ScrollLibrary(outputFolder: output, root: root).setCategory(ids: [saved.id], category: nil)
        let canvas = try XCTUnwrap(views.compactMap { $0 as? EditCanvas }.first)
        canvas.tool = .pen
        canvas.beginInteraction(at: CGPoint(x: 5, y: 5))
        canvas.endInteraction(at: CGPoint(x: 100, y: 50))
        try await waitFor("edits save on the renamed project") { try library.load(saved.id).document.layers.count == 1 }
        let reopened = try library.load(saved.id)
        XCTAssertEqual(reopened.document.name, "From the library")
        XCTAssertNil(reopened.categoryID)
        XCTAssertEqual(try library.entries().map(\.id), [saved.id])
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
        var published: [URL]?
        editor.showExportedFiles = { published = $0 }
        let export = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == EditorCopy.export })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(export.action), to: export.target, from: export))
        try await waitFor("export completed independently of the library") { published != nil && !editor.isBusy }
        let files = try XCTUnwrap(published)
        XCTAssertEqual(files.map(\.pathExtension), ["png", "pdf"])
        let pdf = try XCTUnwrap(files.last)
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
