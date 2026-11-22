import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import LivingScrollPDF

final class EditorExportTests: XCTestCase {
    func testRedactedExportKeepsItsFilenameWhenTheAppRelaunchesInAnotherLanguage() throws {
        let desktop = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: desktop) }
        let firstLaunch = Exporter.desktopFolders(in: desktop, preferredName: "Living Scroll PDF", savedName: nil)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                              bytesPerRow: 128, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let record = CaptureRecord(appName: "Fixture", windowTitle: "", startedAt: Date(), endedAt: Date(),
                                   framesStitched: 1, droppedFrames: 0, pixelWidth: 32, pixelHeight: 32, pointScale: 1)
        var document = EditDocument(name: "Receipt", record: record)
        let first = try EditorExport.write(document, original: image, folder: firstLaunch[0])
        let png = first.deletingPathExtension().appendingPathExtension("png")
        let initialHash = try Exporter.sha256(of: png)
        let nextLaunch = Exporter.desktopFolders(in: desktop, preferredName: "卷轴PDF", savedName: firstLaunch[0].lastPathComponent)
        document.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 32, height: 32))]
        XCTAssertEqual(try EditorExport.write(document, original: image, folder: nextLaunch[0]), first)
        XCTAssertNotEqual(try Exporter.sha256(of: png), initialHash)
        XCTAssertEqual(nextLaunch, firstLaunch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextLaunch[1].path))
        // A pre-fix project can already have its valid triplet in the other language's folder.
        let migrated = try EditorExport.write(document, original: image, folder: nextLaunch[1], legacyFolders: firstLaunch)
        XCTAssertEqual(migrated, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextLaunch[1].path))
        try Data("separately replaced file".utf8).write(to: png)
        let fresh = try EditorExport.write(document, original: image, folder: nextLaunch[1], legacyFolders: firstLaunch)
        XCTAssertEqual(fresh.deletingLastPathComponent().standardizedFileURL.path, nextLaunch[1].standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: png), Data("separately replaced file".utf8))
    }

    func testRedactingAnImportedPNGPreservesWideGamutAndDeepColorOutsideTheSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ScrollLibrary(outputFolder: folder, root: root.appendingPathComponent("Library", isDirectory: true))
        for (bits, profile) in [(8, CGColorSpace.displayP3), (16, CGColorSpace.sRGB)] {
            let space = try XCTUnwrap(CGColorSpace(name: profile))
            let order = bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
            func surface() throws -> CGContext {
                try XCTUnwrap(CGContext(data: nil, width: 560, height: 40, bitsPerComponent: bits,
                                        bytesPerRow: 560 * 4 * bits / 8, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | order))
            }
            let source = try surface()
            let full = CGRect(x: 0, y: 0, width: 560, height: 40)
            let values: [CGFloat] = bits == 16 ? [0.39264, 0.57406, 0.83131, 1] : [1, 0, 0, 1]
            source.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: values)))
            source.fill(full)
            let input = folder.appendingPathComponent("source-\(bits).png")
            try Exporter.writePNG(XCTUnwrap(source.makeImage()), to: input)
            let inputBytes = try Data(contentsOf: input)
            let item = try library.load(library.importPNG(at: input))
            var doc = item.document
            doc.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 12, y: 3, width: 20, height: 18))]
            let pdf = try EditorExport.write(doc, original: item.original, folder: folder)
            let png = pdf.deletingPathExtension().appendingPathExtension("png")
            XCTAssertEqual(png.lastPathComponent, "source-\(bits)-2.png")
            XCTAssertEqual(try Data(contentsOf: input), inputBytes)
            let dst = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
            let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(dst, 0, nil))
            XCTAssertEqual(result.bitsPerComponent, bits)
            let before = try surface(), after = try surface()
            before.draw(item.original, in: full)
            after.draw(result, in: full)
            let byteCount = bits / 8 * 4
            for x in [450, 540] {
                let offset = 35 * before.bytesPerRow + x * byteCount
                let a = Data(bytes: try XCTUnwrap(before.data) + offset, count: byteCount)
                let b = Data(bytes: try XCTUnwrap(after.data) + offset, count: byteCount)
                XCTAssertEqual(a, b, "\(bits) bits, x=\(x)")
            }
        }
    }

    func testNamedPartialExportIsFlattenedInBothFormatsAndReopensWithItsLayers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ScrollLibrary(outputFolder: folder, root: root.appendingPathComponent("Library", isDirectory: true))
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 144, bitsPerComponent: 8,
                                              bytesPerRow: 384, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 144))
        let original = try XCTUnwrap(context.makeImage())
        var record = CaptureRecord(appName: "Example", windowTitle: "Capture", startedAt: Date(), endedAt: Date(),
                                   framesStitched: 4, droppedFrames: 1, pixelWidth: 96, pixelHeight: 144, pointScale: 1)
        record.isPartial = true
        record.partialReason = "ended-before-reconnecting"
        record.gaps = [ContentGap(afterRow: 144, droppedFrames: 1, reason: record.partialReason!)]
        let ink = EditLayer(kind: .pen, rect: CGRect(x: 24, y: 32, width: 40, height: 0),
                            points: [CGPoint(x: 24, y: 32), CGPoint(x: 64, y: 32)],
                            color: InkColor(red: 1, green: 0, blue: 0), width: 14)
        let redaction = EditLayer(kind: .mosaic, rect: CGRect(x: 48, y: 16, width: 16, height: 32))
        let doc = EditDocument(name: "标注 / proof", record: record, layers: [ink, redaction])
        try library.save(doc, original: original, categoryID: nil)
        let pdf = try EditorExport.write(doc, original: original, folder: folder)
        try library.recordExport(pdf, for: doc.id)
        let base = pdf.deletingPathExtension()
        let png = base.appendingPathExtension("png")
        XCTAssertEqual(pdf.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(base.lastPathComponent, "标注 - proof")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = try XCTUnwrap(PixelFrame(cgImage: image))
        let expected = try EditRenderer(original: original).flattened(layers: doc.layers)
        XCTAssertEqual(pixels.bytes, PixelFrame(cgImage: expected)?.bytes)
        let page = try XCTUnwrap(CGPDFDocument(pdf as CFURL)?.page(at: 1))
        XCTAssertEqual(page.getBoxRect(.mediaBox).size, CGSize(width: 96, height: 144))
        context.drawPDFPage(page)
        let pdfPixels = try XCTUnwrap(PixelFrame(cgImage: XCTUnwrap(context.makeImage())))
        for (x, y) in [(35, 32), (57, 32), (57, 45), (35, 109)] {
            let index = (y * 96 + x) * 4
            for channel in 0..<3 {
                XCTAssertEqual(Int(pdfPixels.bytes[index + channel]), Int(pixels.bytes[index + channel]), accuracy: 2)
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(CaptureRecord.self, from: Data(contentsOf: base.appendingPathExtension("json")))
        XCTAssertEqual(saved.editingProjectID, doc.id)
        XCTAssertEqual(saved.editLayerCount, 2)
        XCTAssertEqual(saved.windowTitle, "")
        XCTAssertTrue(saved.isPartial)
        XCTAssertEqual(saved.partialReason, record.partialReason)
        XCTAssertEqual(saved.gaps, record.gaps)
        XCTAssertEqual(saved.pngSHA256, try Exporter.sha256(of: png))
        XCTAssertEqual(saved.pdfSHA256, try Exporter.sha256(of: pdf))
        let privatePNG = try library.originalURL(for: doc.id)
        let sidecar = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: privatePNG.deletingLastPathComponent(),
                                                                             includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(".edit.json") })
        let modes = try [png, pdf, base.appendingPathExtension("json"), privatePNG, sidecar].map {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? Int
        }
        XCTAssertEqual(modes, [0o644, 0o644, 0o644, 0o600, 0o600])
        let duplicate = try EditorExport.write(doc, original: original, folder: folder)
        XCTAssertEqual(duplicate, pdf)
        let resumed = try library.load(library.importPNG(at: png))
        XCTAssertEqual(resumed.document.record.windowTitle, record.windowTitle)
        XCTAssertEqual(resumed.document.layers, doc.layers)
        XCTAssertEqual(PixelFrame(cgImage: resumed.original)?.bytes, PixelFrame(cgImage: original)?.bytes)
    }

    private func stripedOriginal() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                              bytesPerRow: 256, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<64 {
            context.setFillColor(gray: x.isMultiple(of: 2) ? 1 : 0, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 64))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func fixtureRecord() -> CaptureRecord {
        CaptureRecord(appName: "编辑(器) 🖌", windowTitle: "private contact 431929",
                      startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 120),
                      framesStitched: 2, droppedFrames: 0, pixelWidth: 64, pixelHeight: 64, pointScale: 2)
    }

    func testPartialFilenameRemainsStableAtTheByteLimit() {
        var record = fixtureRecord()
        record.isPartial = true
        record.appName = String(repeating: "截图", count: 100)
        let initial = Exporter.fileStem(for: record)
        XCTAssertTrue(initial.hasSuffix(L("-未完成", "-partial")))
        XCTAssertEqual(Exporter.fileStem(for: record, name: initial), initial)

        let base = String(repeating: "x", count: 220)
        for suffix in ["-未完成", "-PARTIAL"] {
            XCTAssertEqual(Exporter.fileStem(for: record, name: base + suffix), base + suffix)
        }
        XCTAssertEqual(Exporter.fileStem(for: record, name: base), base)
    }

    private func readRecord(_ url: URL) throws -> CaptureRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CaptureRecord.self, from: Data(contentsOf: url))
    }

    func testRedactedReexportAtomicallyReplacesAllThreeFilesAndLimitsPDFInfo() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let image = try stripedOriginal()
        var doc = EditDocument(name: "public", record: fixtureRecord())
        let pdf = try EditorExport.write(doc, original: image, folder: folder)
        let png = folder.appendingPathComponent("public.png")
        let json = folder.appendingPathComponent("public.json")
        let first = try readRecord(json)
        let oldDescriptors = try [png, pdf, json].map { try FileHandle(forReadingFrom: $0) }
        defer { oldDescriptors.forEach { try? $0.close() } }
        let neighbor = folder.appendingPathComponent("public-2.png")
        try Data("unrelated".utf8).write(to: neighbor)
        doc.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height))]
        XCTAssertEqual(try EditorExport.write(doc, original: image, folder: folder), pdf)
        let result = try readRecord(json)
        XCTAssertEqual(result.editLayerCount, 1)
        XCTAssertEqual(result.windowTitle, "")
        XCTAssertEqual(result.pngSHA256, try Exporter.sha256(of: png))
        XCTAssertEqual(result.pdfSHA256, try Exporter.sha256(of: pdf))
        XCTAssertNotEqual(result.pngSHA256, first.pngSHA256)
        XCTAssertNotEqual(result.pdfSHA256, first.pdfSHA256)
        for (old, url) in zip(oldDescriptors, [png, pdf, json]) {
            var replaced = stat(), current = stat()
            XCTAssertEqual(fstat(old.fileDescriptor, &replaced), 0)
            XCTAssertEqual(lstat(url.path, &current), 0)
            XCTAssertNotEqual(replaced.st_ino, current.st_ino)
            XCTAssertEqual(replaced.st_nlink, 0)
        }
        XCTAssertEqual(try Set(fm.contentsOfDirectory(atPath: folder.path)),
                       Set(["public.pdf", "public.png", "public.json", "public-2.png"]))
        XCTAssertEqual(try Data(contentsOf: neighbor), Data("unrelated".utf8))
        let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        let info = try XCTUnwrap(document.info)
        XCTAssertEqual(CGPDFDictionaryGetCount(info), 2)
        func string(_ key: String) throws -> String? {
            var field: CGPDFStringRef?
            XCTAssertTrue(CGPDFDictionaryGetString(info, key, &field))
            return CGPDFStringCopyTextString(try XCTUnwrap(field)) as String?
        }
        XCTAssertEqual(try string("Title"), doc.record.appName)
        XCTAssertEqual(try string("CreationDate"), "D:19700101000200Z")
    }

    func testUnusableOrMissingSidecarLeavesEarlierProductsIntact() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let image = try stripedOriginal()
        var doc = EditDocument(name: "kept", record: fixtureRecord())
        let pdf = try EditorExport.write(doc, original: image, folder: folder)
        let png = folder.appendingPathComponent("kept.png")
        let json = folder.appendingPathComponent("kept.json")
        let oldPNG = try Data(contentsOf: png), oldPDF = try Data(contentsOf: pdf)
        try fm.removeItem(at: json)
        try fm.createDirectory(at: json, withIntermediateDirectories: false)
        doc.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 64, height: 64))]
        let alternate = try EditorExport.write(doc, original: image, folder: folder)
        XCTAssertEqual(alternate.lastPathComponent, "kept-2.pdf")
        XCTAssertEqual(try Data(contentsOf: png), oldPNG)
        XCTAssertEqual(try Data(contentsOf: pdf), oldPDF)
        XCTAssertEqual(try fm.attributesOfItem(atPath: json.path)[.type] as? FileAttributeType, .typeDirectory)
        try fm.removeItem(at: json)
        XCTAssertEqual(try EditorExport.write(doc, original: image, folder: folder), alternate)
        XCTAssertFalse(fm.fileExists(atPath: json.path))
        XCTAssertEqual(try readRecord(alternate.deletingPathExtension().appendingPathExtension("json")).editLayerCount, 1)
    }

    func testDifferentProjectsWithTheSameNameKeepBothExportSets() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let image = try stripedOriginal()
        let a = EditDocument(name: "Chats", record: fixtureRecord())
        var b = EditDocument(name: a.name, record: fixtureRecord())
        let first = try EditorExport.write(a, original: image, folder: folder)
        let originals = ["png", "pdf", "json"].map { first.deletingPathExtension().appendingPathExtension($0) }
        let bytes = try originals.map { try Data(contentsOf: $0) }
        let second = try EditorExport.write(b, original: image, folder: folder)
        XCTAssertEqual(second.lastPathComponent, "Chats-2.pdf")
        b.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 64, height: 64))]
        XCTAssertEqual(try EditorExport.write(b, original: image, folder: folder), second)
        let updated = try readRecord(second.deletingPathExtension().appendingPathExtension("json"))
        XCTAssertEqual(updated.editingProjectID, b.id)
        XCTAssertEqual(updated.editLayerCount, 1)
        XCTAssertEqual(try originals.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(try readRecord(originals[2]).editingProjectID, a.id)
    }

    func testPersonalPDFAndInvalidRecordReserveTheirNames() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let personal = folder.appendingPathComponent("Report.pdf")
        let invalid = folder.appendingPathComponent("Report-2.json")
        try Data("my PDF".utf8).write(to: personal)
        try Data("unreadable record".utf8).write(to: invalid)
        let image = try stripedOriginal()
        let doc = EditDocument(name: "Report", record: fixtureRecord())
        let pdf = try EditorExport.write(doc, original: image, folder: folder)
        XCTAssertEqual(pdf.lastPathComponent, "Report-3.pdf")
        XCTAssertEqual(try Data(contentsOf: personal), Data("my PDF".utf8))
        XCTAssertEqual(try Data(contentsOf: invalid), Data("unreadable record".utf8))
        // Removing an earlier collision must not strand a project's previous export.
        try fm.removeItem(at: personal)
        XCTAssertEqual(try EditorExport.write(doc, original: image, folder: folder), pdf)
    }

    func testExportWithoutAProjectIDDoesNotClaimAnotherUnidentifiedExport() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let image = try stripedOriginal(), record = fixtureRecord()
        let initial = try Exporter.export(image, record: record, folder: folder, name: "Legacy")
        let json = initial.deletingPathExtension().appendingPathExtension("json")
        let bytes = try Data(contentsOf: json)
        XCTAssertNil(try readRecord(json).editingProjectID)
        let next = try Exporter.export(image, record: record, folder: folder, name: "Legacy")
        XCTAssertEqual(next.lastPathComponent, "Legacy-2.pdf")
        let doc = EditDocument(name: "Legacy", record: record)
        XCTAssertEqual(try EditorExport.write(doc, original: image, folder: folder).lastPathComponent, "Legacy-3.pdf")
        XCTAssertEqual(try Data(contentsOf: json), bytes)
    }

    func testManuallyReplacedPDFIsProtectedEvenWithItsOldProjectRecord() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let image = try stripedOriginal()
        let doc = EditDocument(name: "Notes", record: fixtureRecord())
        let pdf = try EditorExport.write(doc, original: image, folder: folder)
        let personal = Data("hand-edited PDF".utf8)
        try personal.write(to: pdf)
        XCTAssertEqual(try EditorExport.write(doc, original: image, folder: folder).lastPathComponent, "Notes-2.pdf")
        XCTAssertEqual(try Data(contentsOf: pdf), personal)
    }

    func testConcurrentSameNameExportsPublishOneMatchingGeneration() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let image = try stripedOriginal()
        let mask = EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 64, height: 64))
        let plain = EditDocument(name: "shared", record: fixtureRecord())
        var redacted = plain
        redacted.layers = [mask]
        let pdf = folder.appendingPathComponent("shared.pdf")
        try await withThrowingTaskGroup(of: URL.self) { group in
            for doc in [plain, redacted, plain, redacted] {
                group.addTask { try EditorExport.write(doc, original: image, folder: folder) }
            }
            for try await url in group { XCTAssertEqual(url, pdf) }
        }
        let result = try readRecord(folder.appendingPathComponent("shared.json"))
        XCTAssertEqual(result.editingProjectID, plain.id)
        XCTAssertTrue([0, 1].contains(try XCTUnwrap(result.editLayerCount)))
        XCTAssertEqual(result.pngSHA256, try Exporter.sha256(of: folder.appendingPathComponent("shared.png")))
        XCTAssertEqual(result.pdfSHA256, try Exporter.sha256(of: pdf))
        XCTAssertEqual(try Set(fm.contentsOfDirectory(atPath: folder.path)), Set(["shared.pdf", "shared.png", "shared.json"]))
    }

    private func stageAfterPublishingPNG(from pdf: URL, in folder: URL) throws -> URL {
        let fm = FileManager.default
        let base = pdf.deletingPathExtension()
        let stage = folder.appendingPathComponent(".living-scroll-export")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data().write(to: stage.appendingPathComponent(".living-scroll-publication-v1"))
        try Data().write(to: stage.appendingPathComponent(base.lastPathComponent + ".ready"))
        for ext in ["pdf", "json"] {
            try fm.copyItem(at: base.appendingPathExtension(ext), to: stage.appendingPathComponent("output." + ext))
        }
        let png = folder.appendingPathComponent(base.lastPathComponent + ".png")
        let stagedPNG = stage.appendingPathComponent("output.png")
        try fm.copyItem(at: base.appendingPathExtension("png"), to: stagedPNG)
        guard Darwin.rename(stagedPNG.path, png.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return stage
    }

    func testInterruptedStageDeletionIsFinishedOnStartupAndBeforeTheNextExport() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let image = try stripedOriginal()
        let published = try EditorExport.write(EditDocument(name: "Original", record: fixtureRecord()), original: image, folder: folder)
        let originalPDF = try Data(contentsOf: published)
        let prefix = ".living-scroll-export-done-"
        let contents = Data("keep".utf8)
        func directory(_ name: String, containing filename: String) throws -> URL {
            let directory = folder.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try contents.write(to: directory.appendingPathComponent(filename))
            return directory
        }

        let similar = try directory(prefix + "notes", containing: "prepared.pdf")
        let unrelated = try directory(prefix + UUID().uuidString, containing: "personal.pdf")
        let file = folder.appendingPathComponent(prefix + UUID().uuidString)
        try contents.write(to: file)
        let link = folder.appendingPathComponent(prefix + UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: similar)

        // A crash after the rename and the first few unlinks can leave just one prepared file.
        let first = try directory(prefix + UUID().uuidString, containing: "prepared.pdf")
        try Exporter.recoverPendingExport(in: folder)
        XCTAssertFalse(fm.fileExists(atPath: first.path))
        let second = try directory(prefix + UUID().uuidString, containing: "prepared.png")
        let next = try EditorExport.write(EditDocument(name: "Next", record: fixtureRecord()), original: image, folder: folder)
        XCTAssertEqual(next.lastPathComponent, "Next.pdf")
        XCTAssertFalse(fm.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: published), originalPDF)
        XCTAssertEqual(try Data(contentsOf: similar.appendingPathComponent("prepared.pdf")), contents)
        XCTAssertEqual(try Data(contentsOf: unrelated.appendingPathComponent("personal.pdf")), contents)
        XCTAssertEqual(try Data(contentsOf: file), contents)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), similar.path)
    }

    func testReconnectedFolderFinishesItsInterruptedPairAfterChoosingAnotherLocation() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "ExportRecoveryTests." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("Removable", isDirectory: true)
        let next = root.appendingPathComponent("Next", isDirectory: true)
        let offline = root.appendingPathComponent("Disconnected", isDirectory: true)
        func destination() -> ExportDestination {
            .current(defaults: defaults, environment: [:], desktop: root.appendingPathComponent("Desktop", isDirectory: true))
        }
        func chmod(_ arguments: [String]) throws {
            let tool = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: arguments)
            tool.waitUntilExit()
            XCTAssertEqual(tool.terminationStatus, 0)
        }
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: next, withIntermediateDirectories: true)
        ExportDestination.setCustomFolder(first, defaults: defaults)
        let image = try stripedOriginal()
        var doc = EditDocument(name: "Receipt", record: fixtureRecord())
        let old = try EditorExport.write(doc, original: image, to: destination())
        let oldPNGHash = try Exporter.sha256(of: old.png), oldPDFHash = try Exporter.sha256(of: old.pdf)
        // Only the PDF replacement is denied. PNG has already been published when the swap fails.
        try chmod(["+a", "everyone deny delete", old.pdf.path])
        defer {
            let file = fm.fileExists(atPath: old.pdf.path) ? old.pdf : offline.appendingPathComponent("Receipt.pdf")
            try? chmod(["-N", file.path])
        }
        doc.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 64, height: 64))]
        let redacted = try EditorExport.write(doc, original: image, to: destination())
        XCTAssertTrue(redacted.usedDesktopFallback)
        XCTAssertTrue(redacted.unfinishedAtCustomFolder)
        XCTAssertEqual(redacted.folder, destination().defaultFolder)
        XCTAssertTrue(redacted.files.allSatisfy { fm.fileExists(atPath: $0.path) })
        XCTAssertNotEqual(try Exporter.sha256(of: old.png), oldPNGHash)
        XCTAssertEqual(try Exporter.sha256(of: old.pdf), oldPDFHash)
        try fm.moveItem(at: first, to: offline)

        ExportDestination.setCustomFolder(next, defaults: defaults)
        let tracking = PendingCustomExports(defaults: defaults)
        XCTAssertEqual(try EditorExport.write(doc, original: image, to: destination()).folder, next)
        XCTAssertEqual(Array(tracking.entries.values), [first])
        XCTAssertFalse(fm.fileExists(atPath: first.path))

        try fm.moveItem(at: offline, to: first)
        try chmod(["-N", old.pdf.path])
        XCTAssertEqual(try EditorExport.write(doc, original: image, to: destination()).folder, next)
        let meta = try readRecord(first.appendingPathComponent("Receipt.json"))
        XCTAssertEqual(meta.editLayerCount, 1)
        XCTAssertEqual(meta.pdfSHA256, try Exporter.sha256(of: old.pdf))
        XCTAssertEqual(meta.pngSHA256, try Exporter.sha256(of: old.png))
        XCTAssertTrue(tracking.entries.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: first.appendingPathComponent(".living-scroll-export").path))
    }

    func testStartupRecoveryFinishesAnInterruptedReplacement() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("public"), other = root.appendingPathComponent("completed")
        let image = try stripedOriginal()
        var doc = EditDocument(name: "capture", record: fixtureRecord())
        _ = try EditorExport.write(doc, original: image, folder: folder)
        doc.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 64, height: 64))]
        let completed = try EditorExport.write(doc, original: image, folder: other)
        // Model interruption after the first atomic rename; PDF and JSON are still staged.
        let stage = try stageAfterPublishingPNG(from: completed, in: folder)
        let png = folder.appendingPathComponent("capture.png")
        // A v1 stage may already have moved one 0600 product before the app quit.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: png.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent("output.pdf").path)
        try Exporter.recoverPendingExport(in: folder)
        try Exporter.recoverPendingExport(in: folder)
        let result = try readRecord(folder.appendingPathComponent("capture.json"))
        XCTAssertEqual(result.editLayerCount, 1)
        XCTAssertEqual(result.pngSHA256, try Exporter.sha256(of: png))
        let pdf = folder.appendingPathComponent("capture.pdf")
        XCTAssertEqual(result.pdfSHA256, try Exporter.sha256(of: pdf))
        for file in [png, pdf] {
            XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o644)
        }
        XCTAssertFalse(fm.fileExists(atPath: stage.path))
    }

    func testStartupRecoveryKeepsAPersonalPDFArrivingAfterTheFirstRename() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("public")
        let doc = EditDocument(name: "capture", record: fixtureRecord())
        let original = try stripedOriginal()
        let other = root.appendingPathComponent("completed")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: other.appendingPathComponent("capture.pdf"))
        let completed = try EditorExport.write(doc, original: original, folder: other)
        XCTAssertEqual(completed.lastPathComponent, "capture-2.pdf")
        let stage = try stageAfterPublishingPNG(from: completed, in: folder)
        try Data(doc.name.utf8).write(to: stage.appendingPathComponent("capture-2.ready"))
        try Data("existing".utf8).write(to: folder.appendingPathComponent("capture.pdf"))
        let personal = folder.appendingPathComponent("capture-2.pdf")
        let contents = Data("personal PDF added while the app was closed".utf8)
        try contents.write(to: personal)
        try Exporter.recoverPendingExport(in: folder)
        let recovered = folder.appendingPathComponent("capture-3")
        let record = try readRecord(recovered.appendingPathExtension("json"))
        XCTAssertEqual(record.editingProjectID, doc.id)
        XCTAssertEqual(record.pngSHA256, try Exporter.sha256(of: recovered.appendingPathExtension("png")))
        XCTAssertEqual(record.pdfSHA256, try Exporter.sha256(of: recovered.appendingPathExtension("pdf")))
        XCTAssertEqual(try Data(contentsOf: personal), contents)
        XCTAssertFalse(fm.fileExists(atPath: stage.path))
        XCTAssertEqual(try EditorExport.write(doc, original: original, folder: folder), recovered.appendingPathExtension("pdf"))
    }

    func testReplacingAnAlreadyPublishedPNGDoesNotBlockFutureExports() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let image = try stripedOriginal(), doc = EditDocument(name: "Capture", record: fixtureRecord())
        let completed = try EditorExport.write(doc, original: image, folder: root.appendingPathComponent("completed"))
        for hasPreparedCopy in [false, true] {
            let folder = root.appendingPathComponent(hasPreparedCopy ? "current" : "v1")
            let stage = try stageAfterPublishingPNG(from: completed, in: folder)
            let png = folder.appendingPathComponent("Capture.png")
            if hasPreparedCopy { try fm.copyItem(at: png, to: stage.appendingPathComponent("prepared.png")) }
            let personal = Data("my replacement".utf8)
            try personal.write(to: png)
            let next = EditDocument(name: "Next", record: fixtureRecord())
            XCTAssertEqual(try EditorExport.write(next, original: image, folder: folder).lastPathComponent, "Next.pdf")
            XCTAssertEqual(try Data(contentsOf: png), personal)
            XCTAssertFalse(fm.fileExists(atPath: stage.path))
            if hasPreparedCopy {
                let restored = folder.appendingPathComponent("Capture-2")
                let record = try readRecord(restored.appendingPathExtension("json"))
                XCTAssertEqual(record.editingProjectID, doc.id)
                XCTAssertEqual(record.pngSHA256, try Exporter.sha256(of: restored.appendingPathExtension("png")))
            } else {
                let retained = try XCTUnwrap(fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".living-scroll-interrupted-") })
                XCTAssertEqual(try readRecord(retained.appendingPathComponent("output.json")).editingProjectID, doc.id)
            }
        }
    }

    func testRestartRestoresTheActualFileDisplacedByARacingSave() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let image = try stripedOriginal()
        var doc = EditDocument(name: "Capture", record: fixtureRecord())
        let folder = root.appendingPathComponent("public")
        let old = try EditorExport.write(doc, original: image, folder: folder)
        let png = old.deletingPathExtension().appendingPathExtension("png")
        func version(_ url: URL) throws -> [String: NSNumber] {
            var state = stat()
            guard lstat(url.path, &state) == 0 else { throw POSIXError(.ENOENT) }
            return ["device": NSNumber(value: state.st_dev), "inode": NSNumber(value: state.st_ino),
                    "size": NSNumber(value: state.st_size), "modifiedSeconds": NSNumber(value: state.st_mtimespec.tv_sec),
                    "modifiedNanoseconds": NSNumber(value: state.st_mtimespec.tv_nsec)]
        }
        let previous = try version(png)
        doc.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 64, height: 64))]
        let new = try EditorExport.write(doc, original: image, folder: root.appendingPathComponent("completed"))
        let stage = try stageAfterPublishingPNG(from: new, in: folder)
        let personal = Data("saved in Finder just before the exchange".utf8)
        try personal.write(to: stage.appendingPathComponent("output.png"))
        let exchange: [String: Any] = ["ext": "png", "previous": previous, "incoming": try version(png)]
        try JSONSerialization.data(withJSONObject: exchange).write(to: stage.appendingPathComponent(".exchange.json"))
        try Exporter.recoverPendingExport(in: folder)
        XCTAssertEqual(try Data(contentsOf: png), personal)
        let newPNG = folder.appendingPathComponent("Capture-2.png")
        XCTAssertEqual(try Exporter.sha256(of: newPNG), try Exporter.sha256(of: new.deletingPathExtension().appendingPathExtension("png")))
        XCTAssertEqual(try readRecord(newPNG.deletingPathExtension().appendingPathExtension("json")).editingProjectID, doc.id)
    }
}
