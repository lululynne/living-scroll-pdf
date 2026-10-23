// Renders the Living Scroll PDF app icon.
// Usage: swift tools/render-icon.swift <palette: ink|lion|paper> <size> <out.png>
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Palette {
    var bgTop: CGColor, bgBottom: CGColor
    var paper: CGColor, paperShade: CGColor
    var rod: CGColor, cap: CGColor
    var bubble: CGColor, accentBubble: CGColor
    var seal: CGColor, sealText: CGColor
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let palettes: [String: Palette] = [
    "ink": Palette(bgTop: rgb(0x2E3B5E), bgBottom: rgb(0x161D33), paper: rgb(0xF7F0E1), paperShade: rgb(0xE3D6BC),
                   rod: rgb(0x5A3522), cap: rgb(0xD9A441), bubble: rgb(0x3D4660, 0.22), accentBubble: rgb(0xD8402F, 0.85),
                   seal: rgb(0xD8402F), sealText: rgb(0xF7F0E1)),
    "lion": Palette(bgTop: rgb(0xE2452F), bgBottom: rgb(0xA8161F), paper: rgb(0xFBF3E2), paperShade: rgb(0xEAD9B6),
                    rod: rgb(0x3A1F14), cap: rgb(0xF2BE4A), bubble: rgb(0x5B2A20, 0.20), accentBubble: rgb(0xE9A23B, 0.95),
                    seal: rgb(0xC21F26), sealText: rgb(0xFBF3E2)),
    "paper": Palette(bgTop: rgb(0xFBF5E8), bgBottom: rgb(0xEADFC6), paper: rgb(0xFFFDF7), paperShade: rgb(0xE9DEC8),
                     rod: rgb(0x2E3B5E), cap: rgb(0xC9962F), bubble: rgb(0x2E3B5E, 0.18), accentBubble: rgb(0x2E3B5E, 0.75),
                     seal: rgb(0xD8402F), sealText: rgb(0xFFFDF7)),
]

let args = CommandLine.arguments
let p = palettes[args[1]]!
let size = Int(args[2])!
let out = URL(fileURLWithPath: args[3])
let s = CGFloat(size) / 1024

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: s, y: s)
ctx.setShouldAntialias(true)

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// Squircle background (macOS icon grid: 824pt body inside 1024).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.28))
ctx.addPath(rounded(body, 185)); ctx.setFillColor(p.bgBottom); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(body, 185)); ctx.clip()
let grad = CGGradient(colorsSpace: nil, colors: [p.bgTop, p.bgBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Paper unrolled between two rods.
let paper = CGRect(x: 296, y: 236, width: 432, height: 532)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x000000, 0.25))
ctx.setFillColor(p.paper); ctx.fill(paper)
ctx.restoreGState()
// Curl shading just above the bottom rod and below the top rod.
let curl = CGGradient(colorsSpace: nil, colors: [p.paperShade, p.paper] as CFArray, locations: [0, 1])!
ctx.saveGState(); ctx.clip(to: CGRect(x: paper.minX, y: paper.minY, width: paper.width, height: 60))
ctx.drawLinearGradient(curl, start: CGPoint(x: 0, y: paper.minY), end: CGPoint(x: 0, y: paper.minY + 60), options: []); ctx.restoreGState()
ctx.saveGState(); ctx.clip(to: CGRect(x: paper.minX, y: paper.maxY - 40, width: paper.width, height: 40))
ctx.drawLinearGradient(curl, start: CGPoint(x: 0, y: paper.maxY), end: CGPoint(x: 0, y: paper.maxY - 40), options: []); ctx.restoreGState()

// Chat bubbles: the conversation being kept.
func bubble(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: CGColor) {
    ctx.addPath(rounded(CGRect(x: x, y: y, width: w, height: 46), 23)); ctx.setFillColor(c); ctx.fillPath()
}
bubble(330, 670, 250, p.bubble)
bubble(450, 600, 244, p.accentBubble)
bubble(330, 530, 300, p.bubble)
bubble(520, 460, 174, p.accentBubble)
bubble(330, 390, 200, p.bubble)

// Rods with gilded caps.
func rod(_ y: CGFloat) {
    let r = CGRect(x: 262, y: y, width: 500, height: 52)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x000000, 0.35))
    ctx.addPath(rounded(r, 26)); ctx.setFillColor(p.rod); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(rounded(CGRect(x: r.minX + 40, y: y + 34, width: r.width - 80, height: 8), 4))
    ctx.setFillColor(rgb(0xFFFFFF, 0.14)); ctx.fillPath()
    for cx in [r.minX - 6, r.maxX - 34] {
        ctx.addPath(rounded(CGRect(x: cx, y: y - 4, width: 40, height: 60), 14)); ctx.setFillColor(p.cap); ctx.fillPath()
    }
}
rod(768)
rod(196)

// Seal: proof this is the original record.
ctx.saveGState()
ctx.translateBy(x: 650, y: 300)
ctx.rotate(by: -0.07)
let seal = CGRect(x: -62, y: -62, width: 124, height: 124)
ctx.addPath(rounded(seal, 14)); ctx.setFillColor(p.seal); ctx.fillPath()
ctx.addPath(rounded(seal.insetBy(dx: 9, dy: 9), 8)); ctx.setStrokeColor(p.sealText); ctx.setLineWidth(5); ctx.strokePath()
let font = CTFontCreateWithName("STSongti-SC-Black" as CFString, 84, nil)
let attr = NSAttributedString(string: "卷", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): p.sealText,
])
let line = CTLineCreateWithAttributedString(attr)
let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(x: -b.midX, y: -b.midY)
CTLineDraw(line, ctx)
ctx.restoreGState()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
