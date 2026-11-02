import Foundation

/// Synthetic lines, period 16. The body repeats. A narrow column on the left is
/// unique per row, except six planted rows that also occur 960px lower.
///
/// Those six rows are the false displacement. For a 384px view they vote shift
/// 132, and the periodic body verifies there, even though the two frames share
/// no rows. Removing the plants makes the old matcher reject the pair, which is
/// not this regression. The pixels are generated here. No capture file is read.
enum NearDuplicateFixture {
    static let width = 400
    static let height = 2880
    static let period = 16
    static let hole = 63 * period
    /// Last frame a 384px wheel sequence places before the over-screen jump.
    static let placedY = hole + 192
    /// Frame after that sequence jumps +900 from hole+384.
    static let jumpedY = hole + 1284
    /// Offsets inside the jumped frame. Each one is also painted 132 rows
    /// further down the placed frame, which is the false shift.
    static let plantOffsets = [70, 90, 110, 130, 150, 170]

    static func make() -> PixelFrame {
        var plantAt: [Int: Int] = [:]
        for (k, offset) in plantOffsets.enumerated() {
            plantAt[placedY + 132 + offset] = k
            plantAt[jumpedY + offset] = k
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let plant = plantAt[y]
            for x in 0..<width {
                let rgb = color(y: y, x: x, plant: plant)
                let i = (y * width + x) * 4
                bytes[i] = rgb.0
                bytes[i + 1] = rgb.1
                bytes[i + 2] = rgb.2
                bytes[i + 3] = 255
            }
        }
        return PixelFrame(width: width, height: height, bytes: bytes)
    }

    static func slice(_ doc: PixelFrame, _ y: Int, _ h: Int) -> PixelFrame {
        let rb = doc.width * 4
        var bytes = [UInt8](repeating: 255, count: h * rb)
        for row in 0..<h {
            bytes.replaceSubrange(row * rb..<(row + 1) * rb, with: doc.bytes[(y + row) * rb..<(y + row + 1) * rb])
        }
        return PixelFrame(width: doc.width, height: h, bytes: bytes)
    }

    private static func color(y: Int, x: Int, plant: Int?) -> (UInt8, UInt8, UInt8) {
        // The whole unique column, including on a planted row. A plant that
        // left the row-index bits in place would not match its twin.
        if let k = plant, (4..<52).contains(x) {
            let v = UInt8(40 + k * 25)
            let alt = UInt8(255) &- v
            switch (x + k) % 3 {
            case 0: return (v, alt, UInt8(80 + k * 10))
            case 1: return (alt, v, UInt8(30 + k * 8))
            default: return (v, v, alt)
            }
        }
        // The row identity is spread across the whole column. A binary index
        // only flips a few bits when two frames are exactly one view apart,
        // and that sliver is narrower than the change-span floor, so the pair
        // looks unchanged. Every distinct row also has to differ by more than
        // a couple of pixels, or the moving band collapses and the wheel
        // sequence places a different frame than the one this fixture builds
        // the false shift against.
        if (4..<52).contains(x) {
            let n = (UInt64(y) &* 1_103_515_245) &+ (UInt64(x) &* 12_345)
            let mixed = n &* 2_654_435_761
            let v = UInt8(30 + (mixed % 190))
            let alt = UInt8(25 + ((mixed >> 8) % 180))
            return (v, alt, UInt8(255) &- v)
        }
        if x >= 64 {
            let phase = y % period
            if phase < 4 || phase >= 12 { return (255, 255, 255) }
            let v: UInt8 = ((x * 17 + phase * 3) % 9) < 4 ? 20 : 235
            return (v, v, v)
        }
        return (255, 255, 255)
    }
}
