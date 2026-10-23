import CoreGraphics
import Foundation
import ImageIO

/// `LivingScrollPDF replay <dir> [--pairs | --scan] [--assume-still] [--out file.png]`: feeds PNG frames (e.g. a JZ_DUMP
/// folder) through the stitcher in file-name order and prints every outcome. With `--pairs`
/// each consecutive pair goes through a fresh stitcher, which isolates the matcher.
enum Replay {
    static func run(_ args: [String]) -> Int32 {
        guard let dir = args.first else { print("usage: replay <dir> [--pairs | --scan] [--assume-still] [--out file.png]"); return 2 }
        let pairs = args.contains("--pairs")
        let out = args.firstIndex(of: "--out").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let url = URL(fileURLWithPath: dir)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        func load(_ name: String) -> PixelFrame? {
            guard let src = CGImageSourceCreateWithURL(url.appendingPathComponent(name) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return PixelFrame(cgImage: img)
        }
        let frames = names.compactMap { n in load(n).map { (n, $0) } }
        if args.contains("--scan") {
            for (a, b) in zip(frames, frames.dropFirst()) {
                let st = Stitcher()
                print("\(a.0) -> \(b.0): accepted shifts \(st.verifiedShifts(a.1, b.1)) with a changed block \(st.verifiedShiftsWithChanges(a.1, b.1))")
            }
            return 0
        }
        if pairs {
            var placed = 0
            for (a, b) in zip(frames, frames.dropFirst()) {
                if a.1.reachesOutsideWindow || b.1.reachesOutsideWindow { print("\(a.0) -> \(b.0): skipped (outside the window)"); continue }
                let s = Stitcher()
                _ = s.add(a.1)
                let o = s.add(b.1)
                if case .shifted = o { placed += 1 }
                print("\(a.0) -> \(b.0): \(o)")
            }
            print("pairs placed: \(placed)/\(max(0, frames.count - 1))")
            return 0
        }
        let s = Stitcher()
        // input.tsv (written next to JZ_DUMP frames): per frame, whether wheel/key/drag input had been
        // seen. Without it, `--assume-still` treats the capture as not scrolled until a shift verifies;
        // that is an approximation of the live rule, which uses the real input events.
        var inputAfter: [String: Bool] = [:]
        if let log = try? String(contentsOf: url.appendingPathComponent("input.tsv"), encoding: .utf8) {
            for line in log.split(separator: "\n") {
                let f = line.split(separator: "\t")
                if f.count == 2 { inputAfter[String(f[0])] = f[1] == "1" }
            }
        }
        if !inputAfter.isEmpty || args.contains("--assume-still") { s.scrollStarted = false }
        var skipped = 0
        for (n, f) in frames {
            if inputAfter[n] == true { s.scrollStarted = true }
            // As in a live session: a capture that reached outside the window is not stitched at all.
            if f.reachesOutsideWindow { skipped += 1; print("\(n): skipped (outside the window)"); continue }
            print("\(n): \(s.add(f))")
        }
        if skipped > 0 { print("skipped=\(skipped)") }
        print("accepted=\(s.acceptedFrames) lost=\(s.lostFrames)")
        if let img = s.finish() {
            print("height=\(img.height)")
            if let out { try? Exporter.writePNG(img, to: URL(fileURLWithPath: out)) }
        }
        return 0
    }
}
