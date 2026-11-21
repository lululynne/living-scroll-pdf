import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import Vision
import XCTest
@testable import LivingScrollPDF

final class BandedExportTests: XCTestCase {
    private func record(_ image: CGImage, scale: Double = 2) -> CaptureRecord {
        CaptureRecord(appName: "Fixture", windowTitle: "Secret", startedAt: Date(), endedAt: Date(),
                      framesStitched: 2, droppedFrames: 0, pixelWidth: image.width, pixelHeight: image.height, pointScale: scale)
    }

    private func png(_ pdf: URL) throws -> CGImage {
        let url = pdf.deletingPathExtension().appendingPathExtension("png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testOversizedPNGRowIsRejectedBeforeDecoding() throws {
        for width in [UInt32.max, 1 << 29] {
            var header = Data()
            header.appendUInt32(width)
            header.appendUInt32(1)
            header.append(contentsOf: [16, 6, 0, 0, 0])
            var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
            png.append(pngChunk("IHDR", header))
            png.append(pngChunk("IDAT", try Data(repeating: 0, count: 9).deflated()))
            png.append(pngChunk("IEND", Data()))
            XCTAssertThrowsError(try StripedLayerPNG(png)) { error in
                XCTAssertEqual(error as? StripedLayerPNG.Failure, .dimensions)
            }
        }
    }

    func testVisionReadsRetinaTextBeforeMosaicAndCannotReadItInExport() throws {
        let width = 560, height = 128
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                               bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        let label = "PRIVATE 865927"
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 28, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 48, y: 60)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try XCTUnwrap(context.makeImage())

        func recognize(_ image: CGImage, _ level: VNRequestTextRecognitionLevel) throws -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            for (stage, devices) in try request.supportedComputeStageDevices {
                if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).flatMap { $0.topCandidates(3).map { $0.string.uppercased() } }
        }

        let evidence = ProcessInfo.processInfo.environment["LIVING_SCROLL_OCR_FIXTURES"].map(URL.init(fileURLWithPath:))
        let folder = evidence ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if evidence == nil { try? FileManager.default.removeItem(at: folder) } }
        let mosaic = EditLayer(kind: .mosaic, rect: CGRect(x: 38, y: 32, width: 280, height: 52))
        let pdf = try Exporter.export(image, record: record(image), folder: folder, name: "redacted", layers: [mosaic])
        if evidence != nil { try Exporter.writePNG(image, to: folder.appendingPathComponent("original.png")) }
        let result = try png(pdf)
        var issues: [String] = []
        for level: VNRequestTextRecognitionLevel in [.accurate, .fast] {
            do {
                let before = try recognize(image, level)
                guard before.contains(where: { $0.contains("PRIVATE") }),
                      before.contains(where: { $0.contains("865927") }) else {
                    issues.append("level \(level.rawValue) read \(before) from the original")
                    continue
                }
                let after = try recognize(result, level)
                XCTAssertFalse(after.contains { $0.contains("PRIVATE") || $0.contains("865927") }, "\(after)")
                print("Vision OCR positive: \(before); 2× redacted export: \(after)")
                return
            } catch {
                issues.append("level \(level.rawValue): \(error)")
            }
        }
        XCTFail("Vision could not complete the positive-control/export comparison: \(issues.joined(separator: ", "))")
    }

    func testDifferentMosaicGridsAgreeAtStripEdgesAndAcrossPDFPageCuts() throws {
        let width = 525, height = 1240
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        // The only quiet row in the A4 cut window is y=713 from the image top.
        for x in stride(from: 0, to: width, by: 3) {
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: height - 714, width: width, height: 1))
        let original = try XCTUnwrap(context.makeImage())
        let layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 5, y: 75, width: 516, height: 491)),
                      EditLayer(kind: .mosaic, rect: CGRect(x: 31, y: 93, width: 481, height: 455))]
        let renderer = EditRenderer(original: original, pointScale: 2)
        XCTAssertEqual(renderer.mosaicSide(for: layers[0].rect), 41)
        XCTAssertEqual(renderer.mosaicSide(for: layers[1].rect), 38)
        XCTAssertEqual(renderer.mosaicSide(for: CGRect(x: 0, y: 0, width: 54, height: 22)), 32)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let expected = try XCTUnwrap(PixelFrame(cgImage: renderer.tile(full, layers: layers)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = try Exporter.export(original, record: record(original), folder: folder, layers: layers, layout: .a4)
        let result = try XCTUnwrap(PixelFrame(cgImage: png(pdf)))
        XCTAssertTrue(result.bytes == expected.bytes, "A mosaic cell changed color at a band boundary")
        let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        XCTAssertEqual(document.numberOfPages, 2)
        var start = 0
        for n in 1...document.numberOfPages {
            let page = try XCTUnwrap(document.page(at: n))
            let box = page.getBoxRect(.mediaBox), rows = Int(box.height * 2)
            if n == 1 { XCTAssertEqual(rows, 713) }
            let surface = try XCTUnwrap(CGContext(data: nil, width: width, height: rows, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            surface.scaleBy(x: 2, y: 2)
            surface.drawPDFPage(page)
            let raster = try XCTUnwrap(PixelFrame(cgImage: XCTUnwrap(surface.makeImage())))
            let bytes = expected.bytes[(start * width * 4)..<((start + rows) * width * 4)]
            XCTAssertTrue(raster.bytes.elementsEqual(bytes), "PDF page \(n) shifts a row or changes a redacted pixel")
            start += rows
        }
        XCTAssertEqual(start, height)
    }

    func testStripedDeepColorInsertionPreservesFractionalAlphaAndP3() throws {
        let w = 521, h = 661
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        func surface() throws -> CGContext {
            try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder16Little.rawValue))
        }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let base = try surface(), overlay = try surface()
        base.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0.0811, 0.3421, 0.0872, 0.6132])))
        base.fill(full)
        overlay.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0.9134, 0.0373, 0.0555, 0.4203])))
        for y in stride(from: 5, to: h, by: 37) {
            overlay.fill(CGRect(x: 28, y: y, width: w - 52, height: 17))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stampURL = folder.appendingPathComponent("stamp.png")
        let stamp = try XCTUnwrap(overlay.makeImage())
        try Exporter.writePNG(stamp, to: stampURL)
        let layer = EditLayer(kind: .image, rect: full, imageData: try Data(contentsOf: stampURL))
        let original = try XCTUnwrap(base.makeImage())
        let pdf = try Exporter.export(original, record: record(original), folder: folder, layers: [layer])
        let exported = try png(pdf)
        XCTAssertEqual(exported.bitsPerComponent, 16)
        XCTAssertEqual(exported.colorSpace?.name, CGColorSpace.displayP3)
        let expected = try surface(), actual = try surface()
        expected.draw(original, in: full)
        expected.draw(stamp, in: full)
        actual.draw(exported, in: full)
        let before = try XCTUnwrap(expected.data).assumingMemoryBound(to: UInt16.self)
        let after = try XCTUnwrap(actual.data).assumingMemoryBound(to: UInt16.self)
        for y in 0..<h {
            for x in [14, w / 2, w - 15] {
                let i = 4 * (y * w + x)
                for c in 0..<4 {
                    if abs(Int(before[i + c]) - Int(after[i + c])) > 3 {
                        XCTFail("deep color or alpha mismatch at \(x), \(y), channel \(c): \(before[i+c]) vs \(after[i+c])")
                        return
                    }
                }
            }
        }
    }

    func testEditorExportPeakUnderOneAndAHalfFullImages() throws {
        let marker = "LIVING_SCROLL_XCTEST_EXPORT_FOOTPRINT"
        let width = 1152, height = 24_617, count = width * height * 4
        guard let overlayPath = ProcessInfo.processInfo.environment[marker] else {
            // A process-lifetime peak is only meaningful in a fresh process: other
            // XCTest fixtures allocate whole images before this test starts.
            let overlay = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: overlay) }
            try autoreleasepool {
                let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.setFillColor(red: 1, green: 0, blue: 0.25, alpha: 0.5)
                for y in stride(from: 0, to: height, by: 256) {
                    ctx.fill(CGRect(x: 0, y: y, width: width, height: 25))
                }
                try Exporter.writePNG(XCTUnwrap(ctx.makeImage()), to: overlay)
            }
            let bundle = Bundle(for: Self.self).bundleURL
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest",
                                 "LivingScrollPDFTests.BandedExportTests/testEditorExportPeakUnderOneAndAHalfFullImages", bundle.path]
            var environment = ProcessInfo.processInfo.environment
            environment[marker] = overlay.path
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, log)
            let readings = log.split(separator: "\n").filter { $0.contains("OS export peak") }
            XCTAssertEqual(readings.count, 2, log)
            readings.forEach { print($0) }
            return
        }

        func footprint() throws -> rusage_info_current {
            var info = rusage_info_current()
            let status = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
                }
            }
            XCTAssertEqual(status, 0)
            return info
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let baseline = try footprint().ri_phys_footprint
        // One resident allocation, incompressible RGB, full-height annotation, a
        // single unsplit long PDF page. A deferred full-page raster blows the cap.
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        arc4random_buf(storage, count)
        let pixels = storage.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 3, to: count, by: 4) { pixels[i] = 255 }
        let provider = try XCTUnwrap(CGDataProvider(dataInfo: nil, data: storage, size: count) { _, p, _ in
            UnsafeMutableRawPointer(mutating: p).deallocate()
        })
        let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                           bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let mosaic = EditLayer(kind: .mosaic, rect: CGRect(x: width / 2, y: 0, width: 80, height: height))
        let insert = EditLayer(kind: .image, rect: CGRect(x: 0, y: 0, width: width, height: height),
                               imageData: try Data(contentsOf: URL(fileURLWithPath: overlayPath)))
        for layout: Exporter.PDFLayout in [.long, .a4] {
            let pdf = try autoreleasepool {
                try Exporter.export(source, record: record(source), folder: folder, layers: [insert, mosaic], layout: layout)
            }
            let peak = try footprint().ri_lifetime_max_phys_footprint - baseline
            print("OS export peak \(layout.rawValue): \(peak) bytes / \(count) full-image bytes = \(Double(peak) / Double(count))")
            XCTAssertLessThanOrEqual(peak, UInt64(count * 3 / 2))
            let pages = CGPDFDocument(pdf as CFURL)?.numberOfPages ?? 0
            if layout == .long { XCTAssertEqual(pages, 1) } else { XCTAssertGreaterThan(pages, 1) }
        }
    }
}
