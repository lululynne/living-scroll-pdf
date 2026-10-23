import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureRecord: Codable {
    var tool = "卷轴PDF · Living Scroll PDF \(Exporter.version)"
    var appName: String
    var windowTitle: String
    var startedAt: Date
    var endedAt: Date
    var framesStitched: Int
    /// Frames dropped because they could not be placed; the image has no seams.
    var droppedFrames: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var pointScale: Double
    var pdfPages: Int = 0
    var pngSHA256: String = ""
    var pdfSHA256: String = ""
    /// The capture ended while the last frame could not be placed: content is missing at the end.
    var isPartial = false
    var partialReason: String? = nil
}

enum Exporter {
    static let version = "0.1.0"

    enum PDFLayout: String {
        /// One tall page, like the PNG; split only where a page would exceed the PDF size limit.
        case long
        /// A4-proportioned pages, for printing.
        case a4
    }

    static var pdfLayout: PDFLayout {
        get { PDFLayout(rawValue: UserDefaults.standard.string(forKey: "pdfLayout") ?? "") ?? .long }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pdfLayout") }
    }

    /// 200 inches: the largest page Acrobat and most viewers accept.
    static let maxPagePoints = 14_400

    static var outputFolder: URL {
        if let custom = ProcessInfo.processInfo.environment["JZ_OUT"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/" + L("卷轴PDF", "Living Scroll PDF"), isDirectory: true)
    }

    /// Writes `<stem>.png`, `<stem>.pdf` and `<stem>.json` and returns the PDF URL.
    static func export(_ image: CGImage, record: CaptureRecord, folder: URL = outputFolder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let safeApp = record.appName.replacingOccurrences(of: "/", with: "-")
        let base = L("卷轴PDF", "LivingScrollPDF") + "-\(safeApp)-\(stamp.string(from: record.endedAt))"
            + (record.isPartial ? L("-未完成", "-partial") : "")
        // Two captures ending in the same second must not overwrite each other.
        var stem = base, n = 1
        while ["png", "pdf", "json"].contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent(stem + "." + $0).path) }) {
            n += 1
            stem = "\(base)-\(n)"
        }
        let png = folder.appendingPathComponent(stem + ".png")
        let pdf = folder.appendingPathComponent(stem + ".pdf")
        let json = folder.appendingPathComponent(stem + ".json")

        try writePNG(image, to: png)
        let pages = try writePDF(image, scale: record.pointScale, layout: pdfLayout, record: record, to: pdf)

        var rec = record
        rec.pdfPages = pages
        rec.pngSHA256 = try sha256(of: png)
        rec.pdfSHA256 = try sha256(of: pdf)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rec).write(to: json)
        return pdf
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.cannotCreate(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.cannotCreate(url) }
    }

    /// Writes the long image as one tall page, or as A4-proportioned pages; every cut is
    /// nudged up to a blank row so lines of text are not sliced in half.
    @discardableResult
    static func writePDF(_ image: CGImage, scale: Double, layout: PDFLayout, record: CaptureRecord, to url: URL) throws -> Int {
        let s = CGFloat(max(scale, 1))
        let info: [CFString: Any] = [
            kCGPDFContextTitle: "\(record.appName) · \(record.windowTitle)",
            kCGPDFContextCreator: record.tool,
            kCGPDFContextSubject: "Scrolling capture \(ISO8601DateFormatter().string(from: record.startedAt)) – \(ISO8601DateFormatter().string(from: record.endedAt))"
                + (record.isPartial ? " · " + L("未完成", "PARTIAL") + ": \(record.partialReason ?? "")" : ""),
        ]
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw ExportError.cannotCreate(url)
        }
        let cuts = pageCuts(image, pageHeight: pageHeight(image, scale: scale, layout: layout))
        for (start, end) in zip(cuts, cuts.dropFirst()) {
            guard let slice = image.cropping(to: CGRect(x: 0, y: start, width: image.width, height: end - start)) else { continue }
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) / s, height: CGFloat(end - start) / s)
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(slice, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return cuts.count - 1
    }

    static func pageHeight(_ image: CGImage, scale: Double, layout: PDFLayout) -> Int {
        switch layout {
        case .long: return Int(Double(maxPagePoints) * max(scale, 1))
        case .a4: return max(200, Int(Double(image.width) * 1.414))
        }
    }

    static func pageCuts(_ image: CGImage, pageHeight: Int) -> [Int] {
        let w = image.width, h = image.height
        guard h > pageHeight else { return [0, h] }
        return withRGBA(image) { b in
            var cuts = [0]
            var start = 0
            while h - start > pageHeight {
                let target = start + pageHeight
                var cut = target
                for y in stride(from: target, to: target - pageHeight / 6, by: -1) where isQuietRow(b, width: w, y) {
                    cut = y
                    break
                }
                cuts.append(cut)
                start = cut
            }
            cuts.append(h)
            return cuts
        }
    }

    /// Reads the stitched image's own pixel buffer when it is packed RGBA8 (it always is
    /// for our captures), instead of rendering a second full-size copy.
    private static func withRGBA<T>(_ image: CGImage, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        if image.bitsPerPixel == 32, image.bytesPerRow == image.width * 4,
           image.alphaInfo == .premultipliedLast, let data = image.dataProvider?.data {
            let count = CFDataGetLength(data)
            return body(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: count))
        }
        let frame = PixelFrame(cgImage: image)!
        return frame.bytes.withUnsafeBufferPointer(body)
    }

    private static func isQuietRow(_ b: UnsafeBufferPointer<UInt8>, width w: Int, _ y: Int) -> Bool {
        let base = y * w * 4
        let r = Int(b[base]), g = Int(b[base + 1]), bl = Int(b[base + 2])
        var i = base
        for _ in 0..<w {
            if abs(Int(b[i]) - r) > 10 || abs(Int(b[i + 1]) - g) > 10 || abs(Int(b[i + 2]) - bl) > 10 { return false }
            i += 4
        }
        return true
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum ExportError: Error, CustomStringConvertible {
        case cannotCreate(URL)
        var description: String {
            switch self {
            case .cannotCreate(let url): return "无法写入 \(url.path)"
            }
        }
    }
}
