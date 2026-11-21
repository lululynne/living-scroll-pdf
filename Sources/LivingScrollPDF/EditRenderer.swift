import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Document geometry is in original image pixels, measured from the top left.
/// The canvas and the flattened export use the same rasterizer and tile boundaries.
final class EditRenderer {
    private static let tileSide = 512
    private static let mosaicSide = 16
    private let original: CGImage
    private let bounds: CGRect
    private let colorSpace: CGColorSpace
    private let componentBits: Int
    private let images = NSCache<NSUUID, DecodedImage>()

    init(original: CGImage) {
        self.original = original
        bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let profile = original.colorSpace
        if let profile, profile.model == .rgb { colorSpace = profile }
        else if let base = profile?.baseColorSpace, base.model == .rgb { colorSpace = base }
        else { colorSpace = Stitcher.colorSpace }
        componentBits = original.bitsPerComponent > 8 ? 16 : 8
        images.totalCostLimit = 48 << 20
    }

    func tiles(in rect: CGRect) -> [CGRect] {
        let visible = bounds.intersection(rect).integral
        guard !visible.isEmpty else { return [] }
        let side = Self.tileSide
        let firstX = Int(visible.minX) / side * side
        let firstY = Int(visible.minY) / side * side
        var result: [CGRect] = []
        for y in stride(from: firstY, to: Int(visible.maxY), by: side) {
            for x in stride(from: firstX, to: Int(visible.maxX), by: side) {
                result.append(CGRect(x: x, y: y, width: min(side, original.width - x),
                                     height: min(side, original.height - y)))
            }
        }
        return result
    }

    func tile(_ rect: CGRect, layers: [EditLayer]) throws -> CGImage {
        let requested = bounds.intersection(rect).integral
        guard !requested.isEmpty else { throw Failure.bitmap }
        guard layers.contains(where: { $0.paintBounds.intersects(requested) }) else {
            guard let crop = original.cropping(to: requested) else { throw Failure.bitmap }
            return crop
        }

        // Complete mosaic cells are needed even if a caller asks for a sub-tile crop.
        // Regular 512-pixel canvas tiles are already aligned to this grid.
        let side = CGFloat(Self.mosaicSide)
        let x = floor(requested.minX / side) * side
        let y = floor(requested.minY / side) * side
        let region = bounds.intersection(CGRect(x: x, y: y, width: ceil(requested.maxX / side) * side - x,
                                                height: ceil(requested.maxY / side) * side - y))
        let context = try bitmap(width: Int(region.width), height: Int(region.height))
        guard let background = original.cropping(to: region) else { throw Failure.bitmap }
        context.setBlendMode(.copy)
        context.draw(background, in: CGRect(origin: .zero, size: region.size))
        context.setBlendMode(.normal)
        context.translateBy(x: -region.minX, y: region.maxY)
        context.scaleBy(x: 1, y: -1)
        for layer in layers where layer.paintBounds.intersects(region) {
            context.saveGState()
            defer { context.restoreGState() }
            try draw(layer, in: context, region: region)
        }
        guard let image = context.makeImage() else { throw Failure.bitmap }
        if region == requested { return image }
        guard let crop = image.cropping(to: requested.offsetBy(dx: -region.minX, dy: -region.minY)) else {
            throw Failure.bitmap
        }
        return crop
    }

    func flattened(layers: [EditLayer]) throws -> CGImage {
        guard !layers.isEmpty else { return original }
        let context = try bitmap(width: original.width, height: original.height)
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(original, in: bounds)
        for rect in tiles(in: bounds) where layers.contains(where: { $0.paintBounds.intersects(rect) }) {
            try autoreleasepool {
                let image = try tile(rect, layers: layers)
                let dest = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
                context.draw(image, in: dest)
            }
        }
        guard let result = context.makeImage() else { throw Failure.bitmap }
        return result
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        let order = componentBits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: componentBits,
                                      bytesPerRow: width * 4 * componentBits / 8, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | order) else {
            throw Failure.bitmap
        }
        return context
    }

    private func draw(_ layer: EditLayer, in context: CGContext, region: CGRect) throws {
        let rect = layer.rect.standardized
        let alpha: CGFloat = layer.kind == .highlighter ? 0.36 : 1
        let color = CGColor(srgbRed: layer.color.red, green: layer.color.green, blue: layer.color.blue, alpha: alpha)
        let width = max(1, layer.width)
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch layer.kind {
        case .pen, .highlighter:
            guard let first = layer.points.first else { return }
            if layer.points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            } else {
                context.addLines(between: layer.points)
                context.strokePath()
            }
        case .rectangle:
            context.stroke(rect)
        case .ellipse:
            context.strokeEllipse(in: rect)
        case .arrow:
            guard let path = Self.arrowPath(for: layer) else { return }
            context.addPath(path)
            context.strokePath()
        case .mosaic:
            try pixelate(rect.intersection(region).offsetBy(dx: -region.minX, dy: -region.minY), in: context)
        case .image:
            let image = try decodedImage(for: layer)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        case .text:
            guard !rect.isEmpty, !layer.text.isEmpty else { return }
            let setter = Self.textSetter(layer.text, fontSize: layer.fontSize, color: color)
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            let box = CGRect(origin: .zero, size: rect.size).insetBy(dx: 1, dy: 1)
            guard box.width > 0, box.height > 0 else { return }
            let path = CGPath(rect: box, transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
        }
    }

    static func arrowPath(for layer: EditLayer) -> CGPath? {
        guard let tail = layer.points.first, let tip = layer.points.last else { return nil }
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let head = min(length * 0.65, max(10, layer.width * 3))
        let back = CGPoint(x: tip.x - head * dx / length, y: tip.y - head * dy / length)
        let wing = CGVector(dx: -dy / length * head * 0.5, dy: dx / length * head * 0.5)
        let path = CGMutablePath()
        path.move(to: tail)
        path.addLine(to: tip)
        path.move(to: CGPoint(x: back.x - wing.dx, y: back.y - wing.dy))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: back.x + wing.dx, y: back.y + wing.dy))
        return path
    }

    /// Average premultiplied RGBA from the *current* bitmap, including earlier annotations.
    /// Only pixels whose centres fall inside the selected rectangle participate or change.
    private func pixelate(_ selection: CGRect, in context: CGContext) throws {
        guard !selection.isEmpty else { return }
        context.flush()
        guard let data = context.data else { throw Failure.bitmap }
        if componentBits == 16 {
            averageCells(selection, in: context, pixels: data.assumingMemoryBound(to: UInt16.self))
        } else {
            averageCells(selection, in: context, pixels: data.assumingMemoryBound(to: UInt8.self))
        }
    }

    private func averageCells<T: FixedWidthInteger & UnsignedInteger>(_ selection: CGRect, in context: CGContext,
                                                                      pixels: UnsafeMutablePointer<T>) {
        let strideInComponents = context.bytesPerRow / MemoryLayout<T>.stride
        let x0 = max(0, Int(ceil(selection.minX - 0.5))), x1 = min(context.width, Int(ceil(selection.maxX - 0.5)))
        let y0 = max(0, Int(ceil(selection.minY - 0.5))), y1 = min(context.height, Int(ceil(selection.maxY - 0.5)))
        guard x0 < x1, y0 < y1 else { return }
        let side = Self.mosaicSide
        for cellY in stride(from: y0 / side * side, to: y1, by: side) {
            let rows = max(y0, cellY)..<min(y1, cellY + side)
            for cellX in stride(from: x0 / side * side, to: x1, by: side) {
                let columns = max(x0, cellX)..<min(x1, cellX + side)
                var sums = SIMD4<Int>(repeating: 0)
                for row in rows {
                    let start = pixels + row * strideInComponents
                    for column in columns {
                        let p = start + column * 4
                        sums &+= SIMD4(Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
                    }
                }
                let count = rows.count * columns.count
                let mean = (sums &+ count / 2) / count
                for row in rows {
                    let start = pixels + row * strideInComponents
                    for column in columns {
                        let p = start + column * 4
                        p[0] = T(mean.x)
                        p[1] = T(mean.y)
                        p[2] = T(mean.z)
                        p[3] = T(mean.w)
                    }
                }
            }
        }
    }

    static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let setter = textSetter(text, fontSize: fontSize, color: CGColor(gray: 0, alpha: 1))
        let unconstrained = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, unconstrained, nil)
        return CGSize(width: ceil(fit.width) + 4, height: ceil(fit.height) + 4)
    }

    private static func textSetter(_ text: String, fontSize: CGFloat, color: CGColor) -> CTFramesetter {
        let size = max(1, fontSize)
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    }

    private final class DecodedImage {
        let data: Data
        let image: CGImage
        let sourceSide: Int
        let decodedSide: Int

        init(_ data: Data, _ image: CGImage, sourceSide: Int, decodedSide: Int) {
            self.data = data
            self.image = image
            self.sourceSide = sourceSide
            self.decodedSide = decodedSide
        }
    }

    private func decodedImage(for layer: EditLayer) throws -> CGImage {
        guard let data = layer.imageData else { throw Failure.image }
        let key = layer.id as NSUUID
        let needed = max(1, max(layer.rect.width, layer.rect.height))
        let requestedSide = ceil(needed / 256) * 256
        if let cached = images.object(forKey: key), cached.data == data,
           cached.decodedSide == Int(min(CGFloat(cached.sourceSide), requestedSide)) {
            return cached.image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw Failure.image }
        // A photo inserted as a small sticker shouldn't decode at camera resolution
        // on every tile. Grow the cached raster in steps as the image is resized.
        let longest = max(width, height)
        let limit = Int(min(CGFloat(longest), requestedSide))
        let decoded: CGImage?
        if limit == longest {
            decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: limit,
                                            kCGImageSourceShouldCacheImmediately: true]
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image = decoded else { throw Failure.image }
        images.setObject(DecodedImage(data, image, sourceSide: longest, decodedSide: limit),
                         forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    private enum Failure: LocalizedError {
        case bitmap, image
        var errorDescription: String? {
            switch self {
            case .bitmap: return L("无法生成编辑画面。", "Could not render the edited image.")
            case .image: return L("无法读取图层中的图片。", "Could not read the image in this layer.")
            }
        }
    }
}
