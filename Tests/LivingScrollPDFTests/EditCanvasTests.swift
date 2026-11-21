import AppKit
import XCTest
@testable import LivingScrollPDF

final class EditCanvasTests: XCTestCase {
    private func image(width: Int = 200, height: Int = 240) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor func testStrokeAndUndoRedoBranch() async throws {
        let canvas = EditCanvas(original: try image(), layers: [])
        let start = CGPoint(x: 10, y: 80), end = CGPoint(x: 10, y: 145)
        canvas.tool = .pen
        canvas.beginInteraction(at: start)
        canvas.endInteraction(at: end)
        let pen = try XCTUnwrap(canvas.layers.first)
        XCTAssertEqual(pen.points, [start, end])
        XCTAssertTrue(EditCanvas.hits(pen, at: CGPoint(x: 12, y: 110), tolerance: 1))
        XCTAssertFalse(EditCanvas.hits(pen, at: CGPoint(x: 25, y: 110), tolerance: 1))
        canvas.undoEdit()
        XCTAssertTrue(canvas.layers.isEmpty)
        canvas.redoEdit()
        XCTAssertEqual(canvas.layers, [pen])
        canvas.undoEdit()

        canvas.tool = .highlighter
        canvas.beginInteraction(at: end)
        canvas.endInteraction(at: end)
        XCTAssertEqual(canvas.layers.first?.points, [end])
        XCTAssertEqual(canvas.layers.first?.kind, .highlighter)
        XCTAssertFalse(canvas.canRedo)
    }

    @MainActor func testSelectThroughOutlineDragTextRestyleAndDelete() async throws {
        let text = EditLayer(kind: .text, rect: CGRect(x: 50, y: 60, width: 70, height: 30),
                             fontSize: 20, text: "一行字")
        let circle = EditLayer(kind: .ellipse, rect: CGRect(x: 20, y: 20, width: 160, height: 160))
        let canvas = EditCanvas(original: try image(), layers: [text, circle])
        canvas.beginInteraction(at: CGPoint(x: 75, y: 70))
        XCTAssertEqual(canvas.selection?.id, text.id)
        canvas.endInteraction(at: CGPoint(x: 87, y: 77))
        XCTAssertEqual(canvas.selection?.rect.origin, CGPoint(x: 62, y: 67))
        XCTAssertEqual(canvas.layers.last, circle)

        canvas.textSize = 32
        canvas.ink = .yellow
        canvas.applyStyleToSelection()
        XCTAssertEqual(canvas.selection?.color, .yellow)
        XCTAssertEqual(canvas.selection?.rect.size, EditRenderer.textSize(text.text, fontSize: 32))
        canvas.deleteSelection()
        XCTAssertEqual(canvas.layers, [circle])
        canvas.undoEdit()
        XCTAssertEqual(canvas.layers.first?.id, text.id)
        canvas.undoEdit()
        XCTAssertEqual(canvas.layers.first?.fontSize, 20)
        canvas.undoEdit()
        XCTAssertEqual(canvas.layers, [text, circle])
    }

    @MainActor func testInlineTextCommitsAtClickAndReopensForEditing() async throws {
        let canvas = EditCanvas(original: try image(), layers: [])
        let anchor = CGPoint(x: 55, y: 90)
        canvas.tool = .text
        canvas.beginInteraction(at: anchor)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        field.string = "记号\nNote"
        canvas.textSize = 24
        canvas.ink = .yellow
        canvas.finishTextEditing()
        let added = try XCTUnwrap(canvas.layers.first)
        XCTAssertEqual(added.rect.origin, anchor)
        XCTAssertEqual(added.text, "记号\nNote")
        XCTAssertEqual(added.fontSize, 24)
        XCTAssertEqual(added.color, .yellow)

        canvas.tool = nil
        canvas.beginInteraction(at: CGPoint(x: anchor.x + 5, y: anchor.y + 5), clickCount: 2)
        let editing = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(editing.string, added.text)
        editing.string = "修改"
        canvas.finishTextEditing()
        XCTAssertEqual(canvas.layers.map(\.id), [added.id])
        XCTAssertEqual(canvas.layers.first?.text, "修改")
        canvas.undoEdit()
        XCTAssertEqual(canvas.layers, [added])
    }

    @MainActor func testInsertedImageMovesAndResizesWithItsAspectRatio() async throws {
        let canvas = EditCanvas(original: try image(), layers: [])
        try canvas.insertImage(try image(width: 48, height: 24))
        let initial = try XCTUnwrap(canvas.selection)
        XCTAssertFalse(try XCTUnwrap(initial.imageData).isEmpty)
        let center = CGPoint(x: initial.rect.midX, y: initial.rect.midY)
        canvas.beginInteraction(at: center)
        canvas.endInteraction(at: CGPoint(x: center.x - 8, y: center.y + 16))
        let moved = try XCTUnwrap(canvas.selection)
        XCTAssertEqual(moved.rect, initial.rect.offsetBy(dx: -8, dy: 16))
        let knob = CGPoint(x: moved.rect.maxX - 3, y: moved.rect.maxY - 3)
        canvas.beginInteraction(at: knob)
        canvas.endInteraction(at: CGPoint(x: knob.x + 24, y: knob.y + 12))
        let resized = try XCTUnwrap(canvas.selection)
        XCTAssertEqual(resized.rect.origin, moved.rect.origin)
        XCTAssertEqual(resized.rect.size, CGSize(width: 72, height: 36))
        canvas.undoEdit()
        XCTAssertEqual(canvas.selection, moved)
        canvas.undoEdit()
        XCTAssertEqual(canvas.selection, initial)
        canvas.undoEdit()
        XCTAssertTrue(canvas.layers.isEmpty)
    }
}
