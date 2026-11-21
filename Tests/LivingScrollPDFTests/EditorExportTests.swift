import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LivingScrollPDF

final class EditorExportTests: XCTestCase {
    func testRedactingAnImportedPNGPreservesWideGamutAndDeepColorOutsideTheSelection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = ScrollLibrary(outputFolder: folder)
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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = ScrollLibrary(outputFolder: folder)
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
        XCTAssertEqual(saved.gaps, record.gaps)
        XCTAssertEqual(saved.pngSHA256, try Exporter.sha256(of: png))
        XCTAssertEqual(saved.pdfSHA256, try Exporter.sha256(of: pdf))
        let duplicate = try EditorExport.write(doc, original: original, folder: folder)
        XCTAssertEqual(duplicate.lastPathComponent, base.lastPathComponent + "-2.pdf")
        let resumed = try library.load(library.importPNG(at: png))
        XCTAssertEqual(resumed.document.layers, doc.layers)
        XCTAssertEqual(PixelFrame(cgImage: resumed.original)?.bytes, PixelFrame(cgImage: original)?.bytes)
    }
}
