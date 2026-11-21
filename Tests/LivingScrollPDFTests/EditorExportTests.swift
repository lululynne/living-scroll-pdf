import CoreGraphics
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
            let item = try library.load(library.importPNG(at: input))
            var doc = item.document
            doc.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 12, y: 3, width: 20, height: 18))]
            let pdf = try EditorExport.write(doc, original: item.original, folder: folder)
            let png = pdf.deletingPathExtension().appendingPathExtension("png")
            XCTAssertEqual(png, input)
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
        XCTAssertTrue(base.lastPathComponent.contains(L("-未完成", "-partial")))
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
        XCTAssertEqual(saved.gaps, record.gaps)
        XCTAssertEqual(saved.pngSHA256, try Exporter.sha256(of: png))
        XCTAssertEqual(saved.pdfSHA256, try Exporter.sha256(of: pdf))
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

    func testBadFinalDestinationLeavesEarlierProductsIntact() throws {
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
        XCTAssertThrowsError(try EditorExport.write(doc, original: image, folder: folder))
        XCTAssertEqual(try Data(contentsOf: png), oldPNG)
        XCTAssertEqual(try Data(contentsOf: pdf), oldPDF)
        XCTAssertEqual(try Set(fm.contentsOfDirectory(atPath: folder.path)), Set(["kept.png", "kept.pdf", "kept.json"]))
        try fm.removeItem(at: json)
        XCTAssertEqual(try EditorExport.write(doc, original: image, folder: folder), pdf)
        XCTAssertEqual(try readRecord(json).editLayerCount, 1)
    }

    func testConcurrentSameNameExportsPublishOneMatchingGeneration() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let image = try stripedOriginal()
        let mask = EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 64, height: 64))
        let plain = EditDocument(name: "shared", record: fixtureRecord())
        let redacted = EditDocument(name: "shared", record: fixtureRecord(), layers: [mask])
        let pdf = folder.appendingPathComponent("shared.pdf")
        try await withThrowingTaskGroup(of: URL.self) { group in
            for doc in [plain, redacted, plain, redacted] {
                group.addTask { try EditorExport.write(doc, original: image, folder: folder) }
            }
            for try await url in group { XCTAssertEqual(url, pdf) }
        }
        let result = try readRecord(folder.appendingPathComponent("shared.json"))
        XCTAssertTrue(result.editingProjectID == plain.id || result.editingProjectID == redacted.id)
        XCTAssertEqual(result.editLayerCount, result.editingProjectID == plain.id ? 0 : 1)
        XCTAssertEqual(result.pngSHA256, try Exporter.sha256(of: folder.appendingPathComponent("shared.png")))
        XCTAssertEqual(result.pdfSHA256, try Exporter.sha256(of: pdf))
        XCTAssertEqual(try Set(fm.contentsOfDirectory(atPath: folder.path)), Set(["shared.pdf", "shared.png", "shared.json"]))
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
        _ = try EditorExport.write(doc, original: image, folder: other)
        // Model interruption after the first atomic rename; PDF and JSON are still staged.
        let stage = folder.appendingPathComponent(".living-scroll-export")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        try Data().write(to: stage.appendingPathComponent(".living-scroll-publication-v1"))
        try Data().write(to: stage.appendingPathComponent("capture.ready"))
        for ext in ["pdf", "json"] {
            try fm.copyItem(at: other.appendingPathComponent("capture." + ext), to: stage.appendingPathComponent("output." + ext))
        }
        let png = folder.appendingPathComponent("capture.png")
        try fm.removeItem(at: png)
        try fm.copyItem(at: other.appendingPathComponent("capture.png"), to: png)
        try Exporter.recoverPendingExport(in: folder)
        try Exporter.recoverPendingExport(in: folder)
        let result = try readRecord(folder.appendingPathComponent("capture.json"))
        XCTAssertEqual(result.editLayerCount, 1)
        XCTAssertEqual(result.pngSHA256, try Exporter.sha256(of: png))
        XCTAssertEqual(result.pdfSHA256, try Exporter.sha256(of: folder.appendingPathComponent("capture.pdf")))
        XCTAssertFalse(fm.fileExists(atPath: stage.path))
    }
}
