import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LivingScrollPDF

final class EditRendererTests: XCTestCase {
    private let red = InkColor(red: 1, green: 0, blue: 0)
    private let blue = InkColor(red: 0, green: 0, blue: 1)

    private func bitmap(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ frame: PixelFrame, _ x: Int, _ y: Int) -> [UInt8] {
        let offset = 4 * (y * frame.width + x)
        return Array(frame.bytes[offset..<(offset + 4)])
    }

    private func png(_ image: CGImage) throws -> Data {
        let result = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return result as Data
    }

    func testInkShapesAndHighlighterCompositeInOrderAcrossTileBoundary() throws {
        let source = try bitmap(560, 100)
        let before = try XCTUnwrap(PixelFrame(cgImage: source))
        let renderer = EditRenderer(original: source)
        let path = [CGPoint(x: 470, y: 18), CGPoint(x: 540, y: 18)]
        let pen = EditLayer(kind: .pen, rect: CGRect(x: 470, y: 18, width: 70, height: 0), points: path, color: red, width: 7)
        let highlighter = EditLayer(kind: .highlighter, rect: CGRect(x: 512, y: 4, width: 0, height: 32),
                                    points: [CGPoint(x: 512, y: 4), CGPoint(x: 512, y: 36)], color: blue, width: 8)
        let dot = EditLayer(kind: .pen, rect: CGRect(x: 36, y: 62, width: 0, height: 0),
                            points: [CGPoint(x: 36, y: 62)], color: blue, width: 6)
        let rect = EditLayer(kind: .rectangle, rect: CGRect(x: 60, y: 52, width: 30, height: 20), color: red, width: 4)
        let oval = EditLayer(kind: .ellipse, rect: CGRect(x: 112, y: 48, width: 32, height: 24), color: red, width: 4)
        let arrow = EditLayer(kind: .arrow, rect: CGRect(x: 170, y: 60, width: 70, height: 0),
                              points: [CGPoint(x: 240, y: 60), CGPoint(x: 170, y: 60)], color: red, width: 4)
        let layers = [pen, highlighter, dot, rect, oval, arrow]
        let composite = try renderer.flattened(layers: layers)
        let output = try XCTUnwrap(PixelFrame(cgImage: composite))
        XCTAssertEqual(pixel(output, 485, 18), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, 36, 62), [0, 0, 255, 255])
        XCTAssertEqual(pixel(output, 75, 52), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, 75, 62), [255, 255, 255, 255])
        XCTAssertEqual(pixel(output, 128, 48), [255, 0, 0, 255])
        XCTAssertEqual(pixel(output, 128, 59), [255, 255, 255, 255])
        XCTAssertEqual(pixel(output, 171, 60), [255, 0, 0, 255])
        XCTAssertTrue((170..<194).contains { x in (52..<58).contains { pixel(output, x, $0)[1] < 160 } })
        let overlap = pixel(output, 512, 18)
        XCTAssertTrue(overlap[0] > 0 && overlap[0] < 255 && overlap[2] > 0 && overlap[2] < 255)
        XCTAssertEqual(overlap[1], 0)
        for tile in renderer.tiles(in: CGRect(x: 480, y: 10, width: 60, height: 50)) {
            let screen = try XCTUnwrap(PixelFrame(cgImage: renderer.tile(tile, layers: layers)))
            let saved = try XCTUnwrap(PixelFrame(cgImage: XCTUnwrap(composite.cropping(to: tile))))
            XCTAssertEqual(screen.bytes, saved.bytes)
        }
        XCTAssertEqual(PixelFrame(cgImage: source)?.bytes, before.bytes)
    }

    func testMosaicRedactsPreviousInkAndLeavesEveryPixelOutsideSelectionAlone() throws {
        let source = try bitmap(548, 48) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in stride(from: 0, to: 548, by: 2) {
                context.fill(CGRect(x: x, y: 0, width: 1, height: 48))
            }
        }
        let renderer = EditRenderer(original: source)
        let pen = EditLayer(kind: .pen, rect: CGRect(x: 510, y: 4, width: 0, height: 30),
                            points: [CGPoint(x: 510, y: 4), CGPoint(x: 510, y: 34)], color: blue, width: 3)
        let selection = CGRect(x: 493.4, y: 4.6, width: 36.2, height: 32)
        let mosaic = EditLayer(kind: .mosaic, rect: selection)
        let before = try XCTUnwrap(PixelFrame(cgImage: renderer.flattened(layers: [pen])))
        let image = try renderer.flattened(layers: [pen, mosaic])
        let after = try XCTUnwrap(PixelFrame(cgImage: image))
        for y in 0..<after.height {
            for x in 0..<after.width where !selection.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                if pixel(after, x, y) != pixel(before, x, y) {
                    XCTFail("A pixel outside the mosaic changed at (\(x), \(y))")
                    return
                }
            }
        }
        for x in 496..<512 {
            XCTAssertEqual(pixel(after, x, 23), pixel(after, 505, 23))
        }
        XCTAssertNotEqual(pixel(before, 510, 23), pixel(after, 510, 23))
        let color = pixel(after, 510, 23)
        XCTAssertGreaterThan(color[2], color[0], "Mosaic cells must include the blue ink below them")
        let crop = CGRect(x: 505, y: 11, width: 21, height: 18)
        let cropped = try XCTUnwrap(PixelFrame(cgImage: renderer.tile(crop, layers: [pen, mosaic])))
        XCTAssertEqual(cropped.bytes, PixelFrame(cgImage: try XCTUnwrap(image.cropping(to: crop)))?.bytes)
    }

    func testEmbeddedImageOrientationAndMultilineText() throws {
        let stamp = try bitmap(2, 2) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 1, width: 2, height: 1))
        }
        let renderer = EditRenderer(original: try bitmap(200, 140))
        let image = EditLayer(kind: .image, rect: CGRect(x: 8, y: 8, width: 32, height: 24), imageData: try png(stamp))
        let text = "One\n第二行"
        let size = EditRenderer.textSize(text, fontSize: 22)
        XCTAssertGreaterThan(size.height, EditRenderer.textSize("One", fontSize: 22).height)
        let frame = CGRect(origin: CGPoint(x: 50, y: 34), size: size)
        let label = EditLayer(kind: .text, rect: frame, color: blue, fontSize: 22, text: text)
        let output = try XCTUnwrap(PixelFrame(cgImage: renderer.flattened(layers: [image, label])))
        XCTAssertGreaterThan(pixel(output, 16, 10)[0], 220)
        XCTAssertGreaterThan(pixel(output, 16, 30)[2], 220)
        let hasText: (Range<Int>) -> Bool = { rows in
            rows.contains { y in (Int(frame.minX)..<Int(frame.maxX)).contains { self.pixel(output, $0, y)[0] < 160 } }
        }
        XCTAssertTrue(hasText(Int(frame.minY)..<Int(frame.midY)))
        XCTAssertTrue(hasText(Int(frame.midY)..<Int(frame.maxY)))
        XCTAssertEqual(pixel(output, 48, 33), [255, 255, 255, 255])
    }

    func testInsertedPhotoRendersIdenticallyAfterResizingBack() throws {
        let photo = try bitmap(800, 600) { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in stride(from: 0, to: 800, by: 3) {
                context.fill(CGRect(x: x, y: 0, width: 1, height: 600))
            }
        }
        let renderer = EditRenderer(original: try bitmap(600, 440))
        let small = EditLayer(kind: .image, rect: CGRect(x: 10, y: 10, width: 96, height: 72), imageData: try png(photo))
        let before = try XCTUnwrap(PixelFrame(cgImage: renderer.tile(small.rect, layers: [small])))
        var grown = small
        grown.rect.size = CGSize(width: 560, height: 420)
        let larger = try XCTUnwrap(PixelFrame(cgImage: renderer.tile(CGRect(x: 500, y: 90, width: 40, height: 10),
                                                                     layers: [grown])))
        XCTAssertTrue(larger.bytes.contains { $0 < 195 })
        let restored = try XCTUnwrap(PixelFrame(cgImage: renderer.tile(small.rect, layers: [small])))
        XCTAssertEqual(before.bytes, restored.bytes)
    }

    func testTallViewportRendersOnlyIntersectingTilesDownToTheLastRow() throws {
        let width = 1_152, height = 24_617
        let source = try bitmap(width, height) { context in
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            for y in stride(from: 18, to: height, by: 32) {
                context.fill(CGRect(x: 42, y: y, width: 700 + y % 300, height: 4))
            }
        }
        let renderer = EditRenderer(original: source)
        let viewport = CGRect(x: 0, y: height - 600, width: width, height: 600)
        let tiles = renderer.tiles(in: viewport)
        XCTAssertLessThanOrEqual(tiles.count, 9)
        XCTAssertTrue(tiles.allSatisfy { $0.intersects(viewport) && $0.height <= 512 && $0.width <= 512 })
        XCTAssertEqual(tiles.last?.maxY, CGFloat(height))
        XCTAssertTrue(renderer.tiles(in: viewport.offsetBy(dx: CGFloat(width), dy: 0)).isEmpty)
        let location = CGPoint(x: width - 5, y: height - 2)
        let dot = EditLayer(kind: .pen, rect: CGRect(origin: location, size: .zero), points: [location], color: red, width: 5)
        let last = try XCTUnwrap(tiles.last)
        let bitmap = try XCTUnwrap(PixelFrame(cgImage: renderer.tile(last, layers: [dot])))
        XCTAssertEqual(bitmap.height, Int(last.height))
        XCTAssertEqual(pixel(bitmap, bitmap.width - 5, bitmap.height - 2), [255, 0, 0, 255])

        // Exercise the uncached path at several magnifications and scroll positions;
        // the time is diagnostic, while bounded tile count is deterministic.
        let view = CGSize(width: 720, height: 540)
        let surface = try XCTUnwrap(CGContext(data: nil, width: Int(view.width), height: Int(view.height),
                                              bitsPerComponent: 8, bytesPerRow: 0, space: Stitcher.colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let scales: [CGFloat] = [0.625, 1, 1.5]
        var totalTiles = 0
        var elapsed: [Double] = []
        for i in 0..<12 {
            let scale = scales[i % scales.count]
            let y = (CGFloat(height) - view.height / scale) * CGFloat(i) / 11
            let visible = CGRect(x: 0, y: y, width: view.width / scale, height: view.height / scale)
            let mosaic = EditLayer(kind: .mosaic, rect: CGRect(x: 80, y: y + 92, width: 300, height: 42))
            let began = CFAbsoluteTimeGetCurrent()
            let parts = renderer.tiles(in: visible)
            XCTAssertLessThanOrEqual(parts.count, 9)
            for part in parts {
                let tile = try renderer.tile(part, layers: [dot, mosaic])
                let onScreen = CGRect(x: part.minX * scale, y: view.height - (part.maxY - y) * scale,
                                      width: part.width * scale, height: part.height * scale)
                surface.draw(tile, in: onScreen)
            }
            surface.flush()
            totalTiles += parts.count
            elapsed.append((CFAbsoluteTimeGetCurrent() - began) * 1_000)
        }
        print(String(format: "Editor viewport %d × %d, 12 uncached views, %d tiles, median %.2f ms, max %.2f ms",
                     width, height, totalTiles, elapsed.sorted()[elapsed.count / 2], elapsed.max() ?? 0))
    }
}
