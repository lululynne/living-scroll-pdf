import CoreGraphics
import Darwin
import Foundation
import ImageIO
import zlib

/// Insertions produced by the editor are noninterlaced PNGs. ImageIO allocates
/// their entire decoded raster even for a lazy crop. For large insertions,
/// unfilter once into an unlinked private file and give ImageIO small standalone
/// strips with the original color profile, palette and transparency.
final class StripedLayerPNG {
    let width: Int
    let height: Int
    private let rowSize: Int
    private let headerTail: Data
    private let colorChunks: Data
    private let spool: FileHandle

    init?(_ data: Data) throws {
        guard data.count >= 33,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              data[12..<16].elementsEqual("IHDR".utf8), data[28] == 0 else { return nil }
        let w = Self.uint32(data, 16), h = Self.uint32(data, 20)
        let bits = Int(data[24]), type = data[25]
        let channels: Int
        switch type {
        case 0, 3: channels = 1
        case 2: channels = 3
        case 4: channels = 2
        case 6: channels = 4
        default: throw Failure.invalid
        }
        // PNG limits a dimension to 2^31-1. Bound the scanline before allocating
        // two of them or narrowing its length for zlib. 8 MiB still permits over
        // a million RGBA16 pixels in a single row.
        guard w > 0, w <= Int(Int32.max), h > 0, h <= Int(Int32.max) else { throw Failure.dimensions }
        guard [1, 2, 4, 8, 16].contains(bits), data[26] == 0, data[27] == 0 else { throw Failure.invalid }
        let rowSize = 1 + (w * bits * channels + 7) / 8
        guard rowSize <= 8 << 20 else { throw Failure.dimensions }
        self.rowSize = rowSize
        self.width = w
        self.height = h
        headerTail = data[24..<29]

        var color = Data(), payloads: [Range<Int>] = [], offset = 8
        while offset <= data.count - 12 {
            let size = Self.uint32(data, offset), start = offset + 8
            guard size <= data.count - offset - 12 else { throw Failure.invalid }
            let type = String(decoding: data[(start-4)..<start], as: UTF8.self)
            if type == "IDAT" && size > 0 { payloads.append(start..<(start + size)) }
            if ["PLTE", "tRNS", "iCCP", "sRGB", "gAMA", "cHRM", "sBIT"].contains(type) {
                color.append(data[offset..<(start + size + 4)])
            }
            offset += size + 12
            if type == "IEND" { break }
        }
        guard !payloads.isEmpty else { throw Failure.invalid }
        colorChunks = color
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("living-scroll-layer.XXXXXX").path
        var path = Array(template.utf8CString)
        let fd = mkstemp(&path)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        spool = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard unlink(path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try unpack(data, payloads: payloads, pixelBytes: max(1, (bits * channels + 7) / 8))
    }

    private static func uint32(_ data: Data, _ i: Int) -> Int {
        Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
    }

    private func unpack(_ png: Data, payloads: [Range<Int>], pixelBytes: Int) throws {
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid }
        defer { inflateEnd(&stream) }
        var prior = [UInt8](repeating: 0, count: rowSize)
        var current = prior, chunk = 0, status = Z_OK
        try png.withUnsafeBytes { input in
            let source = input.bindMemory(to: Bytef.self).baseAddress!
            // An extra one-byte output probe also verifies the Adler checksum when
            // the final row ended exactly at the end of the inflate output buffer.
            func fill(_ raw: UnsafeMutableBufferPointer<UInt8>) throws {
                stream.next_out = raw.baseAddress
                stream.avail_out = uInt(raw.count)
                while stream.avail_out > 0 && status != Z_STREAM_END {
                    if stream.avail_in == 0 {
                        guard chunk < payloads.count else { throw Failure.invalid }
                        let next = payloads[chunk]
                        stream.next_in = UnsafeMutablePointer(mutating: source + next.lowerBound)
                        stream.avail_in = uInt(next.count)
                        chunk += 1
                    }
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else { throw Failure.invalid }
                }
            }
            for _ in 0..<height {
                try current.withUnsafeMutableBufferPointer { row in
                    try fill(row)
                    guard stream.avail_out == 0 else { throw Failure.invalid }
                    let filter = row[0]
                    if filter != 0 {
                        try prior.withUnsafeBufferPointer { prev in
                            try Self.unfilter(row, prev, filter: filter, bpp: pixelBytes)
                        }
                        row[0] = 0
                    }
                    try spool.write(contentsOf: Data(bytesNoCopy: row.baseAddress!, count: row.count, deallocator: .none))
                }
                swap(&current, &prior)
            }
            var probe: UInt8 = 0
            try withUnsafeMutablePointer(to: &probe) { try fill(UnsafeMutableBufferPointer(start: $0, count: 1)) }
            guard status == Z_STREAM_END, stream.avail_out == 1 else { throw Failure.invalid }
        }
    }

    private static func unfilter(_ row: UnsafeMutableBufferPointer<UInt8>, _ prev: UnsafeBufferPointer<UInt8>,
                                 filter: UInt8, bpp: Int) throws {
        switch filter {
        case 1:
            for i in (bpp + 1)..<row.count { row[i] &+= row[i - bpp] }
        case 2:
            for i in 1..<row.count { row[i] &+= prev[i] }
        case 3, 4:
            for i in 1..<row.count {
                let left = i > bpp ? Int(row[i - bpp]) : 0
                let up = Int(prev[i])
                if filter == 3 {
                    row[i] &+= UInt8((left + up) / 2)
                } else {
                    let corner = i > bpp ? Int(prev[i - bpp]) : 0
                    let a = abs(up - corner), b = abs(left - corner), c = abs(left + up - 2 * corner)
                    row[i] &+= UInt8(a <= b && a <= c ? left : b <= c ? up : corner)
                }
            }
        default: throw Failure.invalid
        }
    }

    /// Paint only intersecting rows, with neighboring source pixels for Quartz's
    /// resampling kernel. Adjacent fractional strip edges share the same transform.
    func draw(in context: CGContext, rect: CGRect, region: CGRect) throws {
        let visible = region.intersection(rect)
        guard !visible.isEmpty else { return }
        let sy = rect.height / CGFloat(height)
        guard sy > 0, sy.isFinite else { return }
        let first = Int(min(CGFloat(height), max(0, floor((visible.minY - rect.minY) / sy))))
        let end = Int(min(CGFloat(height), max(0, ceil((visible.maxY - rect.minY) / sy))))
        guard first < end else { return }
        let rowsPerStrip = max(1, (512 << 10) / rowSize)
        let halo = Int(min(CGFloat(rowsPerStrip), max(4, ceil(4 / sy))))
        for y in stride(from: first, to: end, by: rowsPerStrip) {
            let bottom = min(end, y + rowsPerStrip)
            let rows = max(0, y - halo)..<min(height, bottom + halo)
            try autoreleasepool {
                let image = try image(for: rows)
                context.saveGState()
                defer { context.restoreGState() }
                context.setShouldAntialias(false)
                context.clip(to: CGRect(x: rect.minX, y: rect.minY + CGFloat(y) * sy,
                                        width: rect.width, height: CGFloat(bottom - y) * sy))
                context.translateBy(x: rect.minX, y: rect.minY + CGFloat(rows.upperBound) * sy)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: CGFloat(rows.count) * sy))
            }
        }
    }

    private func image(for rows: Range<Int>) throws -> CGImage {
        let count = rows.count * rowSize
        var raw = Data(count: count)
        try raw.withUnsafeMutableBytes { out in
            var position = 0
            while position < count {
                let n = pread(spool.fileDescriptor, out.baseAddress! + position, count - position,
                              off_t(rows.lowerBound * rowSize + position))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.invalid }
                position += n
            }
        }
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var header = Data()
        header.appendUInt32(UInt32(width))
        header.appendUInt32(UInt32(rows.count))
        header.append(headerTail)
        png.append(pngChunk("IHDR", header))
        png.append(colorChunks)
        png.append(pngChunk("IDAT", try raw.deflated()))
        png.append(pngChunk("IEND", Data()))
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure.invalid }
        return image
    }

    enum Failure: LocalizedError {
        case invalid, dimensions
        var errorDescription: String? {
            switch self {
            case .invalid: return L("无法解码图层中的 PNG。", "Could not decode the PNG in the image layer.")
            case .dimensions: return L("插图的像素尺寸超出可处理的范围。", "The inserted image dimensions are too large to process.")
            }
        }
    }
}
