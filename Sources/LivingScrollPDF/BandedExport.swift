import Accelerate
import CoreGraphics
import Darwin
import Foundation
import zlib

/// PNG and PDF consume the same composited scanlines. In particular a PDF image
/// object never refers to the source or to a layer underneath a redaction.
enum BandedExport {
    static func write(original: CGImage, layers: [EditLayer], record: CaptureRecord,
                      layout: Exporter.PDFLayout, png: URL, pdf: URL) throws -> Int {
        let renderer = EditRenderer(original: original, pointScale: record.pointScale)
        let width = original.width, height = original.height, bits = renderer.componentBits
        let profile = renderer.colorSpace.copyICCData() as Data?
        let pngWriter = try ScanlinePNG(url: png, width: width, height: height, bits: bits, profile: profile)
        let pdfWriter = try StripPDF(url: pdf, width: width, bits: bits, profile: profile)
        var pages = PageBreaks(height: height, pageHeight: Exporter.pageHeight(original, scale: record.pointScale, layout: layout))

        // Bound temporary bitmaps by bytes as well as rows (including deep-color imports).
        let bandHeight = max(1, min(128, (1 << 20) / (width * 4 * bits / 8)))
        for y in stride(from: 0, to: height, by: bandHeight) {
            try autoreleasepool {
                let rows = min(bandHeight, height - y)
                let image = try renderer.tile(CGRect(x: 0, y: y, width: width, height: rows), layers: layers)
                let pixels = try renderer.bitmap(width: width, height: rows)
                pixels.setBlendMode(.copy)
                pixels.draw(image, in: CGRect(x: 0, y: 0, width: width, height: rows))
                pixels.flush()
                guard let bytes = pixels.data else { throw RasterError.encoding }
                pages.inspect(bytes, y: y, rows: rows, width: width, bits: bits)

                var band = vImage_Buffer(data: bytes, height: vImagePixelCount(rows),
                                         width: vImagePixelCount(width), rowBytes: pixels.bytesPerRow)
                // PNG and PDF store straight color. PDF and PNG 16-bit samples are big-endian.
                var source = band
                let conversion = bits == 8 ? vImageUnpremultiplyData_RGBA8888 : vImageUnpremultiplyData_RGBA16U
                guard conversion(&source, &band, 0) == kvImageNoError else { throw RasterError.encoding }
                if bits == 16 {
                    var words = band
                    words.width *= 4
                    var destination = words
                    guard vImageByteSwap_Planar16U(&words, &destination, 0) == kvImageNoError else { throw RasterError.encoding }
                }
                try pngWriter.append(band)
                try pdfWriter.append(band, y: y)
            }
        }
        try pngWriter.finish()
        let cuts = pages.starts + [height]
        try pdfWriter.finish(cuts: cuts, scale: max(1, record.pointScale), record: record)
        return cuts.count - 1
    }

    /// Search the same final sixth of each page for a quiet row as in the capture
    /// exporter. Only the few rows near a possible cut need to be inspected.
    private struct PageBreaks {
        let height: Int
        let pageHeight: Int
        var starts = [0]
        private var lastQuiet: Int?

        mutating func inspect(_ pixels: UnsafeRawPointer, y: Int, rows: Int, width: Int, bits: Int) {
            for row in 0..<rows {
                let target = starts.last! + pageHeight, line = y + row
                guard target < height, line > target - pageHeight / 6 else { continue }
                let pointer = pixels + row * width * 4 * (bits / 8)
                let quiet = bits == 8
                    ? Self.quiet(pointer.assumingMemoryBound(to: UInt8.self), width: width)
                    : Self.quiet(pointer.assumingMemoryBound(to: UInt16.self), width: width)
                if quiet { lastQuiet = line }
                if line == target {
                    starts.append(lastQuiet ?? target)
                    lastQuiet = nil
                }
            }
        }

        private static func quiet<T: UnsignedInteger & FixedWidthInteger>(_ p: UnsafePointer<T>, width: Int) -> Bool {
            let tolerance = 10 * Int(T.max) / 255
            for x in 1..<width {
                let q = p + x * 4
                for c in 0..<3 where abs(Int(q[c]) - Int(p[c])) > tolerance { return false }
            }
            return true
        }

        init(height: Int, pageHeight: Int) {
            self.height = height
            self.pageHeight = pageHeight
        }
    }
}

private enum RasterError: LocalizedError {
    case encoding
    var errorDescription: String? { L("无法编码导出的图像。", "Could not encode the exported image.") }
}

private func outputFile(_ url: URL) throws -> FileHandle {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var word = value.bigEndian
        Swift.withUnsafeBytes(of: &word) { append(contentsOf: $0) }
    }

    /// Single small streams for PDF strips and color profiles.
    func deflated() throws -> Data {
        var length = compressBound(uLong(count))
        var result = Data(count: Int(length))
        let status = result.withUnsafeMutableBytes { out in
            withUnsafeBytes { input in
                compress2(out.bindMemory(to: Bytef.self).baseAddress!, &length,
                          input.bindMemory(to: Bytef.self).baseAddress!, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw RasterError.encoding }
        result.count = Int(length)
        return result
    }
}

func pngChunk(_ tag: String, _ body: Data) -> Data {
    let type = Data(tag.utf8)
    let initial = type.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, 4) }
    let crc = body.isEmpty ? initial : body.withUnsafeBytes {
        crc32(initial, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))
    }
    var chunk = Data()
    chunk.appendUInt32(UInt32(body.count))
    chunk.append(type)
    chunk.append(body)
    chunk.appendUInt32(UInt32(crc))
    return chunk
}

/// A single zlib stream spanning IDAT chunks. Each scanline starts with PNG
/// filter 0. No full-height pixel buffer or full compressed payload is kept.
private final class ScanlinePNG {
    private let file: FileHandle
    private var stream = z_stream()

    init(url: URL, width: Int, height: Int, bits: Int, profile: Data?) throws {
        file = try outputFile(url)
        guard deflateInit_(&stream, Z_DEFAULT_COMPRESSION, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw RasterError.encoding }

        try file.write(contentsOf: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        var header = Data()
        header.appendUInt32(UInt32(width))
        header.appendUInt32(UInt32(height))
        header.append(contentsOf: [UInt8(bits), 6, 0, 0, 0])
        try chunk("IHDR", header)
        if let profile {
            var icc = Data("ICC".utf8) + Data([0, 0])
            icc.append(try profile.deflated())
            try chunk("iCCP", icc)
        }
    }

    deinit { deflateEnd(&stream) }

    func append(_ band: vImage_Buffer) throws {
        let rowBytes = band.rowBytes
        var scanlines = Data(count: Int(band.height) * (rowBytes + 1))
        scanlines.withUnsafeMutableBytes { out in
            for y in 0..<Int(band.height) {
                memcpy(out.baseAddress! + y * (rowBytes + 1) + 1, band.data + y * rowBytes, rowBytes)
            }
        }
        try encode(scanlines, final: false)
    }

    func finish() throws {
        try encode(Data(), final: true)
        try chunk("IEND", Data())
        try file.close()
    }

    private func encode(_ data: Data, final: Bool) throws {
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data(count: 64 << 10)
            var status: Int32
            repeat {
                status = output.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return deflate(&stream, final ? Z_FINISH : Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw RasterError.encoding }
                let used = output.count - Int(stream.avail_out)
                if used > 0 { try chunk("IDAT", output.prefix(used)) }
            } while final ? status != Z_STREAM_END : stream.avail_in > 0
            stream.next_in = nil
            stream.next_out = nil
        }
    }

    private func chunk(_ tag: String, _ body: Data) throws {
        try file.write(contentsOf: pngChunk(tag, body))
    }
}

/// Quartz retains images drawn into an open PDF page until it closes the page.
/// Write standard image XObjects directly so even one 200-inch page only retains
/// object offsets and strip positions. The page clips a strip spanning a quiet cut.
private final class StripPDF {
    private let file: FileHandle
    private let width: Int
    private let bits: Int
    private var colorSpace = "/DeviceRGB"
    private var offsets = [UInt64](repeating: 0, count: 3) // 1: Catalog, 2: Pages
    private var strips: [(id: Int, rows: Range<Int>)] = []

    init(url: URL, width: Int, bits: Int, profile: Data?) throws {
        file = try outputFile(url)
        self.width = width
        self.bits = bits
        try text("%PDF-1.5\n")
        try file.write(contentsOf: Data([0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]))
        try object("<< /Type /Catalog /Pages 2 0 R >>", id: 1)
        if let profile {
            let id = try stream("/N 3 /Alternate /DeviceRGB", data: profile)
            colorSpace = "[/ICCBased \(id) 0 R]"
        }
    }

    func append(_ band: vImage_Buffer, y: Int) throws {
        var source = band
        let rows = Int(band.height), bytes = bits / 8
        var mask = Data(count: width * rows * bytes)
        let alphaStatus = mask.withUnsafeMutableBytes { alpha in
            var dest = vImage_Buffer(data: alpha.baseAddress!, height: band.height,
                                     width: band.width, rowBytes: width * bytes)
            let extract = bits == 8 ? vImageExtractChannel_ARGB8888 : vImageExtractChannel_ARGB16U
            return extract(&source, &dest, 3, 0)
        }
        guard alphaStatus == kvImageNoError else { throw RasterError.encoding }
        let opaque = mask.withUnsafeBytes { raw in
            raw[0] == 255 && memcmp(raw.baseAddress!, raw.baseAddress! + 1, raw.count - 1) == 0
        }
        let image = "/Type /XObject /Subtype /Image /Width \(width) /Height \(rows) /BitsPerComponent \(bits)"
        var descriptor = "\(image) /ColorSpace \(colorSpace)"
        if !opaque {
            let id = try stream("\(image) /ColorSpace /DeviceGray", data: mask)
            descriptor += " /SMask \(id) 0 R"
        }
        var rgb = Data(count: width * rows * 3 * bytes)
        let rgbStatus = rgb.withUnsafeMutableBytes { color in
            var dest = vImage_Buffer(data: color.baseAddress!, height: band.height,
                                     width: band.width, rowBytes: width * 3 * bytes)
            let convert = bits == 8 ? vImageConvert_RGBA8888toRGB888 : vImageConvert_RGBA16UtoRGB16U
            return convert(&source, &dest, 0)
        }
        guard rgbStatus == kvImageNoError else { throw RasterError.encoding }
        strips.append((try stream(descriptor, data: rgb), y..<(y + rows)))
    }

    func finish(cuts: [Int], scale: Double, record: CaptureRecord) throws {
        var pages: [Int] = []
        var firstStrip = 0
        for (start, end) in zip(cuts, cuts.dropFirst()) {
            while strips[firstStrip].rows.upperBound <= start { firstStrip += 1 }
            var commands = "q\n\(1 / scale) 0 0 \(1 / scale) 0 0 cm\n"
            var resources = ""
            for strip in strips[firstStrip...] {
                guard strip.rows.lowerBound < end else { break }
                resources += "/I\(strip.id) \(strip.id) 0 R "
                commands += "q \(width) 0 0 \(strip.rows.count) 0 \(end - strip.rows.upperBound) cm /I\(strip.id) Do Q\n"
            }
            commands += "Q\n"
            let content = try stream("", data: Data(commands.utf8))
            let size = "\(Double(width) / scale) \(Double(end - start) / scale)"
            let page = try object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(size)] " +
                                  "/Resources << /XObject << \(resources)>> >> /Contents \(content) 0 R >>")
            pages.append(page)
        }
        let kids = pages.map { "\($0) 0 R" }.joined(separator: " ")
        try object("<< /Type /Pages /Count \(pages.count) /Kids [\(kids)] >>", id: 2)
        let info = try object(Exporter.pdfInfoObject(for: record))
        let xref = try file.offset()
        try text("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
        for offset in offsets.dropFirst() {
            try text(String(format: "%010llu 00000 n \n", offset))
        }
        try text("trailer\n<< /Size \(offsets.count) /Root 1 0 R /Info \(info) 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        try file.close()
    }

    private func text(_ value: String) throws { try file.write(contentsOf: Data(value.utf8)) }

    private func begin(_ fixed: Int? = nil) throws -> Int {
        let id = fixed ?? offsets.count
        let offset = try file.offset()
        guard offset < 10_000_000_000 else { throw RasterError.encoding }
        if let fixed { offsets[fixed] = offset } else { offsets.append(offset) }
        try text("\(id) 0 obj\n")
        return id
    }

    @discardableResult
    private func object(_ value: String, id: Int? = nil) throws -> Int {
        let number = try begin(id)
        try text("\(value)\nendobj\n")
        return number
    }

    private func stream(_ descriptor: String, data: Data) throws -> Int {
        let compressed = try data.deflated()
        let id = try begin()
        try text("<< \(descriptor) /Filter /FlateDecode /Length \(compressed.count) >>\nstream\n")
        try file.write(contentsOf: compressed)
        try text("\nendstream\nendobj\n")
        return id
    }
}
