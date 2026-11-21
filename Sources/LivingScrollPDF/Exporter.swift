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
    /// Where the image stops being a continuous capture. Nil, and omitted from JSON, when it does not.
    var gaps: [ContentGap]? = nil
    /// A local library reference allows a flattened export to reopen with its original layers.
    var editingProjectID: UUID? = nil
    var editLayerCount: Int? = nil
}

/// A stretch that was on screen and is not in the image. `afterRow` is the image height:
/// the missing rows are after the last row that was proved to follow the one above it.
struct ContentGap: Codable, Equatable {
    var afterRow: Int
    var droppedFrames: Int
    var reason: String
}

enum Exporter {
    /// A packaged app records CFBundleShortVersionString. `dev` is only the command-line
    /// binary, which has no app bundle; it must not be written up as 0.1.0. A bare `1.0`
    /// from an unrelated bundle is not a release of this app either.
    static func releaseVersion(bundleShort: String?, bundleIdentifier: String?) -> String {
        let packaged = bundleIdentifier == "io.github.lululynne.livingscrollpdf"
        if let raw = bundleShort?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if packaged { return raw }
            if raw != "1.0" { return raw }
        }
        return "dev"
    }

    static var version: String {
        releaseVersion(
            bundleShort: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier)
    }

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

    static func fileStem(for record: CaptureRecord, name: String? = nil) -> String {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        var supplied = name?.trimmingCharacters(in: trim) ?? ""
        if supplied.isEmpty {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            supplied = L("卷轴PDF", "LivingScrollPDF") + "-\(record.appName)-\(stamp.string(from: record.endedAt))"
        }
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let cleaned = supplied.components(separatedBy: unsafe).joined(separator: "-")
        // Leave room for a collision suffix and extension even with multibyte filenames.
        var stem = ""
        for character in cleaned {
            if stem.utf8.count + String(character).utf8.count > 220 { break }
            stem.append(character)
        }
        if stem.isEmpty { stem = L("长截图", "Screenshot") }
        if record.isPartial && !stem.hasSuffix("-未完成") && !stem.lowercased().hasSuffix("-partial") {
            stem += L("-未完成", "-partial")
        }
        return stem
    }

    /// Form all three files in private first. The record appears only after both
    /// final payloads exist, and a name collision never replaces an older capture.
    static func export(_ image: CGImage, record: CaptureRecord, folder: URL = outputFolder, name: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".export-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let png = staging.appendingPathComponent("output.png")
        let pdf = staging.appendingPathComponent("output.pdf")
        let json = staging.appendingPathComponent("output.json")
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

        let base = fileStem(for: record, name: name)
        var suffix = 1
        while true {
            let stem = suffix == 1 ? base : "\(base)-\(suffix)"
            let sources = [png, pdf, json]
            let destinations = sources.map { folder.appendingPathComponent(stem + "." + $0.pathExtension) }
            suffix += 1
            if destinations.contains(where: { fm.fileExists(atPath: $0.path) }) { continue }
            var published: [URL] = []
            do {
                // Same-volume hard links reserve names without clobbering a concurrent export.
                // copyItem also refuses replacements and works on volumes without hard links.
                for (source, destination) in zip(sources, destinations) {
                    do {
                        try fm.linkItem(at: source, to: destination)
                    } catch let error as NSError where error.code != NSFileWriteFileExistsError {
                        try fm.copyItem(at: source, to: destination)
                    }
                    published.append(destination)
                }
                return destinations[1]
            } catch {
                for url in published { try? fm.removeItem(at: url) }
                if (error as NSError).code == NSFileWriteFileExistsError { continue }
                throw error
            }
        }
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

    enum ExportError: LocalizedError, CustomStringConvertible {
        case cannotCreate(URL)
        var errorDescription: String? { description }
        var description: String {
            switch self {
            case .cannotCreate(let url): return L("无法写入 \(url.path)", "Could not write \(url.path)")
            }
        }
    }
}
