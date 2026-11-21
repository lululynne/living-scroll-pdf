import CoreGraphics
import Foundation

struct InkColor: Codable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let coral = InkColor(red: 0.9, green: 0.18, blue: 0.16)
    static let yellow = InkColor(red: 1, green: 0.83, blue: 0.09)
}

enum EditLayerKind: String, Codable {
    case pen, highlighter, rectangle, ellipse, arrow, mosaic, text, image
}

/// Stored coordinates are original-image pixels measured from its top left,
/// independent of display scale, scroll position and editor magnification.
struct EditLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: EditLayerKind
    var rect: CGRect
    var points: [CGPoint] = []
    var color: InkColor = .coral
    var width: CGFloat = 6
    var fontSize: CGFloat = 32
    var text = ""
    var imageData: Data?

    var paintBounds: CGRect {
        let margin: CGFloat
        switch kind {
        case .image, .mosaic, .text: margin = 1
        case .arrow: margin = max(12, width * 4) + 2
        default: margin = width / 2 + 2
        }
        return rect.standardized.insetBy(dx: -margin, dy: -margin)
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Self {
        var moved = self
        moved.rect = rect.offsetBy(dx: dx, dy: dy)
        moved.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return moved
    }
}

struct EditDocument: Codable {
    var id = UUID()
    var version = 1
    var name: String
    var record: CaptureRecord
    var layers: [EditLayer] = []
    var revision: UUID?
}
