import Foundation
import ImageIO
import XCTest
@testable import LivingScrollPDF

final class StitcherRejoinTests: XCTestCase {
    private let width = 200, height = 200
    private var rowBytes: Int { width * 4 }
    private let stitcher = Stitcher()
    private var time = 0.0

    private func makePage(seed: UInt64) -> [UInt8] {
        var rng = SplitMix(seed: seed)
        var page = [UInt8](repeating: 255, count: 3000 * rowBytes)
        for y in 0..<3000 {
            for x in 0..<width {
                let i = y * rowBytes + x * 4
                page[i] = UInt8(rng.next() % 210)
                page[i + 1] = UInt8(truncatingIfNeeded: (y / 50) * 31 + x)
                page[i + 2] = 255 - page[i]
            }
        }
        return page
    }

    private func shot(_ page: [UInt8], at y: Int) -> PixelFrame {
        PixelFrame(width: width, height: height, bytes: Array(page[y * rowBytes..<(y + height) * rowBytes]))
    }

    @discardableResult
    private func capture(_ page: [UInt8], at y: Int, wheel: Int? = nil, home: Bool = false) -> (Stitcher.Outcome, Stitcher.LocateVerdict) {
        defer { time += 1 }
        return stitcher.addOrRejoin(shot(page, at: y), wheelEstimate: wheel, keyboardEdge: home ? .start : nil, at: time)
    }

    private func scroll(_ page: [UInt8], from start: Int, to end: Int,
                        file: StaticString = #filePath, line: UInt = #line) {
        let step = start < end ? 100 : -100
        for y in stride(from: start + step, through: end, by: step) {
            XCTAssertEqual(capture(page, at: y).0, .shifted(step), "Offset \(y)", file: file, line: line)
        }
    }

    private func captureThrough(_ end: Int, on page: [UInt8],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(capture(page, at: 0).0, .first, file: file, line: line)
        scroll(page, from: 0, to: end, file: file, line: line)
    }

    private func assertExport(_ expected: ArraySlice<UInt8>,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let output = try XCTUnwrap(stitcher.finish().flatMap(PixelFrame.init(cgImage:)), file: file, line: line)
        XCTAssertEqual(output.width, width, file: file, line: line)
        XCTAssertEqual(output.height, expected.count / rowBytes, file: file, line: line)
        XCTAssertTrue(output.bytes.elementsEqual(expected), "Exported pixels differ from the source", file: file, line: line)
    }

    func testHomeThenDonePreservesTheWholePage() throws {
        let page = makePage(seed: 7)
        captureThrough(2000, on: page)
        let rows = stitcher.canvasRows
        XCTAssertEqual(capture(page, at: 0, home: true).1, .found(-2000))
        XCTAssertEqual(stitcher.canvasRows, rows)
        try assertExport(page.prefix(2200 * rowBytes))
    }

    func testHomeThenScrollingPastTheOldTailExtendsTheWholePage() throws {
        let page = makePage(seed: 7)
        captureThrough(2000, on: page)
        let rows = stitcher.canvasRows
        XCTAssertEqual(capture(page, at: 0, home: true).1, .found(-2000))
        for y in stride(from: 100, through: 2200, by: 100) {
            capture(page, at: y)
            XCTAssertGreaterThanOrEqual(stitcher.canvasRows, rows, "Lost the old tail at offset \(y)")
        }
        XCTAssertFalse(stitcher.needsRecovery)
        try assertExport(page.prefix(2400 * rowBytes))
    }

    func testEndAfterHomeRejoinsTheOriginalTailWithoutCutting() throws {
        let page = makePage(seed: 7)
        captureThrough(2000, on: page)
        XCTAssertEqual(capture(page, at: 0, home: true).1, .found(-2000))
        let end = stitcher.addOrRejoin(shot(page, at: 2000), keyboardEdge: .end, at: time)
        XCTAssertEqual(end.1, .found(2000))
        XCTAssertFalse(stitcher.needsRecovery)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        try assertExport(page.prefix(2200 * rowBytes))
    }

    func testFixedSidebarOnAnUnchangedPageCannotCutTheTailAtADifferentScrollStep() throws {
        let page = makePage(seed: 8)
        func withSidebar(_ y: Int) -> PixelFrame {
            var frame = shot(page, at: y).bytes
            for row in 0..<height {
                let start = row * rowBytes
                frame.replaceSubrange(start..<(start + 44 * 4), with: page[start..<(start + 44 * 4)])
            }
            return PixelFrame(width: width, height: height, bytes: frame)
        }
        let control = Stitcher()
        for y in stride(from: 0, through: 1200, by: 100) {
            let frame = withSidebar(y)
            _ = control.add(frame)
            _ = stitcher.add(frame)
        }
        let retained = stitcher.canvasRows
        XCTAssertEqual(stitcher.addOrRejoin(withSidebar(0), wheelEstimate: -1200, at: 0).1, .found(-1200))
        XCTAssertEqual(stitcher.addOrRejoin(withSidebar(75), at: 1).0, .shifted(75))
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        XCTAssertEqual(stitcher.canvasRows, retained)
        let expected = try XCTUnwrap(control.finish().flatMap(PixelFrame.init(cgImage:)))
        try assertExport(expected.bytes[...])
    }

    func testRepeatedBannerBeyondTheCanvasCannotReplaceOrExtendTheCapturedPage() throws {
        var page = makePage(seed: 9)
        page.replaceSubrange(1700 * rowBytes..<1960 * rowBytes, with: page[300 * rowBytes..<560 * rowBytes])
        captureThrough(1200, on: page)
        let rows = stitcher.canvasRows
        // The entire viewport at 1730 is identical to 330. The following frames reveal the
        // second banner's real neighbours. None of them can bridge the gap from 1200.
        for y in stride(from: 1730, through: 2330, by: 100) {
            let (outcome, _) = capture(page, at: y)
            XCTAssertEqual(outcome, .lost, "Accepted the out-of-canvas banner at offset \(y)")
            XCTAssertEqual(stitcher.canvasRows, rows)
        }
        XCTAssertTrue(stitcher.needsRecovery)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testUnlocatedFrameBeforeRepeatedBannerDoesNotProveAReturnToTheTail() throws {
        var page = makePage(seed: 9)
        page.replaceSubrange(1700 * rowBytes..<1960 * rowBytes, with: page[300 * rowBytes..<560 * rowBytes])
        captureThrough(1200, on: page)
        XCTAssertEqual(capture(page, at: 1500).0, .lost)
        for y in [1730, 1730, 1830, 1930, 2030] {
            XCTAssertEqual(capture(page, at: y).0, .lost)
        }
        XCTAssertEqual(stitcher.contentOrigin, 1200)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        XCTAssertTrue(stitcher.needsRecovery)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testRepeatedSectionStartIsNotAHomeKey() throws {
        var page = makePage(seed: 37)
        page.replaceSubrange(1700 * rowBytes..<1970 * rowBytes, with: page[0..<270 * rowBytes])
        captureThrough(1200, on: page)
        XCTAssertEqual(capture(page, at: 1700).0, .lost)
        XCTAssertTrue(stitcher.needsRecovery)
        XCTAssertEqual(stitcher.contentOrigin, 1200)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testSeveralCopiedViewportsCannotAuthorizeAppendingPastTheOriginalTail() throws {
        var page = makePage(seed: 39)
        page.replaceSubrange(1700 * rowBytes..<2200 * rowBytes, with: page[900 * rowBytes..<1400 * rowBytes])
        captureThrough(1200, on: page)
        for y in stride(from: 1730, through: 2330, by: 100) {
            XCTAssertEqual(capture(page, at: y).0, .lost)
            XCTAssertEqual(stitcher.contentOrigin, 1200)
        }
        XCTAssertTrue(stitcher.needsRecovery)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testSparseTailLandmarksCannotAuthorizeCuttingAtTheNextBanner() throws {
        var page = makePage(seed: 8)
        page.replaceSubrange(2000 * rowBytes..<2260 * rowBytes, with: page[300 * rowBytes..<560 * rowBytes])
        captureThrough(1200, on: page)
        XCTAssertEqual(capture(page, at: 1500).0, .lost)
        var form = shot(page, at: 1700).bytes
        let oldTail = shot(page, at: 1200)
        for k in 0..<16 {
            let y = height / 5 + k * (height * 3 / 5) / 16
            let line = y * rowBytes..<(y + 1) * rowBytes
            form.replaceSubrange(line, with: oldTail.bytes[line])
        }
        let bait = PixelFrame(width: width, height: height, bytes: form)
        XCTAssertEqual(stitcher.addOrRejoin(bait, keyboardEdge: .end, at: time).0, .lost)
        time += 1
        for y in [2030, 2130, 2230, 2330] { XCTAssertEqual(capture(page, at: y).0, .lost) }
        XCTAssertTrue(stitcher.needsRecovery)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testEndAtTheRealDocumentBottomDoesNotProveAReturnToTheCapturedTail() throws {
        var page = makePage(seed: 8)
        page.replaceSubrange(2840 * rowBytes..<2960 * rowBytes, with: page[1240 * rowBytes..<1360 * rowBytes])
        page.replaceSubrange(2000 * rowBytes..<2260 * rowBytes, with: page[300 * rowBytes..<560 * rowBytes])
        captureThrough(1200, on: page)
        XCTAssertEqual(capture(page, at: 1500).0, .lost)
        let bottom = stitcher.addOrRejoin(shot(page, at: 2800), keyboardEdge: .end, at: time)
        XCTAssertEqual(bottom.0, .lost)
        time += 1
        for y in [2030, 2130, 2230, 2330] { XCTAssertEqual(capture(page, at: y).0, .lost) }
        XCTAssertTrue(stitcher.needsRecovery)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testLookalikeCentreCannotReplaceHeldBackRowsWithAZeroShift() throws {
        let page = makePage(seed: 8)
        captureThrough(1200, on: page)
        var bait = shot(page, at: 1700).bytes
        let previous = shot(page, at: 1200).bytes
        let centre = 45 * rowBytes..<160 * rowBytes
        bait.replaceSubrange(centre, with: previous[centre])
        XCTAssertEqual(stitcher.addOrRejoin(PixelFrame(width: width, height: height, bytes: bait), at: time).0, .lost)
        XCTAssertTrue(stitcher.needsRecovery)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testFinishDuringThrottledPairMatchingKeepsTheLastAcceptedFrameAndGap() throws {
        let page = makePage(seed: 41)
        captureThrough(1200, on: page)
        let atLoss = time
        XCTAssertEqual(capture(page, at: 2500).0, .lost)
        let rows = stitcher.canvasRows, count = stitcher.acceptedFrames
        var checks = 0
        let result = stitcher.addOrRejoin(shot(page, at: 1300), at: atLoss + 0.01) {
            checks += 1
            return checks <= 3 // Close after search/fallback dispatch, before the pair commits.
        }
        XCTAssertEqual(result.0, .lost)
        XCTAssertEqual(result.1, .skipped)
        XCTAssertEqual(stitcher.canvasRows, rows)
        XCTAssertEqual(stitcher.acceptedFrames, count)
        XCTAssertTrue(stitcher.needsRecovery)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testWheelDirectionAndDistanceMustBothFitTheUniquePosition() throws {
        let page = makePage(seed: 17)
        captureThrough(1200, on: page)
        XCTAssertEqual(capture(page, at: 330, wheel: 530).0, .lost)
        XCTAssertEqual(capture(page, at: 330, wheel: -600).0, .lost)
        XCTAssertEqual(stitcher.contentOrigin, 1200)
        XCTAssertEqual(capture(page, at: 330, wheel: -890).1, .found(-870))
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testWheelCannotSelectBetweenTwoVerifiedLocationsInTheSection() throws {
        var page = makePage(seed: 19)
        page.replaceSubrange(900 * rowBytes..<1160 * rowBytes, with: page[300 * rowBytes..<560 * rowBytes])
        captureThrough(1500, on: page)
        XCTAssertEqual(capture(page, at: 330, wheel: -1170).0, .lost)
        XCTAssertEqual(stitcher.contentOrigin, 1500)
        try assertExport(page.prefix(1700 * rowBytes))
    }

    func testWheelOvershootCannotUseAShortReverseOverlapWithTheFirstBanner() throws {
        var page = makePage(seed: 18)
        page.replaceSubrange(1700 * rowBytes..<1960 * rowBytes, with: page[1100 * rowBytes..<1360 * rowBytes])
        captureThrough(1200, on: page)
        // 1730 looks exactly like 1130, only 70 rows behind the previous frame.
        XCTAssertEqual(capture(page, at: 1730, wheel: 530).0, .lost)
        XCTAssertEqual(stitcher.contentOrigin, 1200)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testTolerantRivalOutsideTheHashBucketStillVetoesTheRejoin() throws {
        var page = makePage(seed: 21)
        var twin = Array(page[300 * rowBytes..<560 * rowBytes])
        for i in stride(from: 0, to: twin.count, by: 4) where twin[i] % 32 == 31 { twin[i] += 1 }
        page.replaceSubrange(900 * rowBytes..<1160 * rowBytes, with: twin)
        captureThrough(1500, on: page)
        XCTAssertEqual(stitcher.locate(shot(page, at: 330)), -1170)
        XCTAssertEqual(capture(page, at: 330, wheel: -1170).0, .lost)
        try assertExport(page.prefix(1700 * rowBytes))
    }

    func testMatchingCentreAndWheelCannotOverrideDifferentScrollingEdges() throws {
        let page = makePage(seed: 23), other = makePage(seed: 24)
        captureThrough(1200, on: page)
        var lookalike = page
        for range in [330..<368, 491..<530] {
            let bytes = range.lowerBound * rowBytes..<range.upperBound * rowBytes
            lookalike.replaceSubrange(bytes, with: other[bytes])
        }
        XCTAssertEqual(stitcher.locate(shot(lookalike, at: 330)), -870)
        XCTAssertEqual(capture(lookalike, at: 330, wheel: -870).0, .lost)
        XCTAssertEqual(stitcher.contentOrigin, 1200)
        try assertExport(page.prefix(1400 * rowBytes))
    }

    func testOnlyAnObservedDivergenceCutsAndIsRecordedInTheExport() throws {
        let page = makePage(seed: 27), other = makePage(seed: 28)
        captureThrough(1500, on: page)
        let retained = stitcher.canvasRows
        var changed = page
        changed.replaceSubrange(350 * rowBytes..<page.count, with: other[(350 * rowBytes)...])
        XCTAssertEqual(capture(changed, at: 0, wheel: -1500).1, .found(-1500))
        XCTAssertEqual(capture(changed, at: 100).0, .shifted(100))
        XCTAssertEqual(stitcher.canvasRows, retained)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        XCTAssertEqual(capture(changed, at: 200).0, .shifted(100))
        XCTAssertLessThan(stitcher.canvasRows, retained)
        XCTAssertEqual(stitcher.rejoinTruncations, 1)
        let image = try XCTUnwrap(stitcher.finish())
        XCTAssertTrue(try XCTUnwrap(PixelFrame(cgImage: image)).bytes.elementsEqual(changed.prefix(400 * rowBytes)))
        let record = CaptureRecord(appName: "Reader", windowTitle: "", startedAt: Date(), endedAt: Date(),
                                   framesStitched: stitcher.acceptedFrames, rejoinTruncations: stitcher.rejoinTruncations,
                                   droppedFrames: stitcher.lostFrames, pixelWidth: image.width, pixelHeight: image.height, pointScale: 1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Exporter.export(image, record: record, folder: dir)
        let data = try Data(contentsOf: pdf.deletingPathExtension().appendingPathExtension("json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json.removeValue(forKey: "rejoinTruncations") as? Int, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(CaptureRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.rejoinTruncations)
    }

    func testForwardRejoinWithinTheCanvasPreservesTheFurthestTail() throws {
        let page = makePage(seed: 11)
        captureThrough(1500, on: page)
        let rows = stitcher.canvasRows
        scroll(page, from: 1500, to: 600)
        let (_, location) = capture(page, at: 1000, wheel: 400)
        XCTAssertEqual(location, .found(400))
        XCTAssertEqual(stitcher.contentOrigin, 1000)
        XCTAssertEqual(stitcher.canvasRows, rows)
        try assertExport(page.prefix(1700 * rowBytes))
    }

    func testUnmeasuredForwardJumpAlsoPreservesTheFurthestTail() throws {
        let page = makePage(seed: 11)
        captureThrough(1500, on: page)
        scroll(page, from: 1500, to: 600)
        let retained = stitcher.canvasRows
        _ = capture(page, at: 1000)
        XCTAssertEqual(stitcher.canvasRows, retained)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        try assertExport(page.prefix(1700 * rowBytes))
    }

    func testForwardRejoinCannotCutEvenIfTheFollowingContentDiffers() throws {
        let page = makePage(seed: 31), other = makePage(seed: 32)
        captureThrough(1500, on: page)
        let retained = stitcher.canvasRows
        scroll(page, from: 1500, to: 600)
        var changed = page
        changed.replaceSubrange(1200 * rowBytes..<page.count, with: other[(1200 * rowBytes)...])
        XCTAssertEqual(capture(changed, at: 1000, wheel: 400).1, .found(400))
        XCTAssertEqual(capture(changed, at: 1100).0, .lost)
        XCTAssertEqual(stitcher.canvasRows, retained)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        try assertExport(page.prefix(1700 * rowBytes))
    }

    func testHomeWithoutEvidenceOfAFailedTailReturnCannotAuthorizeACut() throws {
        let page = makePage(seed: 33), other = makePage(seed: 34)
        captureThrough(1500, on: page)
        var changed = page
        changed.replaceSubrange(250 * rowBytes..<page.count, with: other[(250 * rowBytes)...])
        XCTAssertEqual(capture(changed, at: 0, home: true).1, .found(-1500))
        for y in [100, 200, 300, 400] { capture(changed, at: y) }
        XCTAssertTrue(stitcher.needsRecovery)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        try assertExport(page.prefix(1700 * rowBytes))
    }

    func testStationarySectionCannotLocateUsingItsFixedHeader() throws {
        let page = makePage(seed: 35), other = makePage(seed: 36)
        let seed = shot(page, at: 0)
        var repaint = seed.bytes
        for y in [20, 179] {
            let bytes = y * rowBytes..<(y + 1) * rowBytes
            repaint.replaceSubrange(bytes, with: other[bytes])
        }
        let stationary = PixelFrame(width: width, height: height, bytes: repaint)
        XCTAssertEqual(stitcher.add(seed), .first)
        XCTAssertEqual(stitcher.add(stationary), .shifted(0))
        let retained = stitcher.canvasRows
        XCTAssertGreaterThan(retained, 0)
        XCTAssertEqual(capture(other, at: 2000).0, .lost)
        // Returning to the exact seed is allowed through ordinary add. Its header
        // cannot serve as a global rejoin or get pasted into the middle of the section.
        let (_, location) = stitcher.addOrRejoin(stationary, at: 10)
        XCTAssertEqual(location, .none)
        XCTAssertEqual(stitcher.canvasRows, retained)
        XCTAssertEqual(stitcher.rejoinTruncations, 0)
        let saved = try XCTUnwrap(stitcher.finish().flatMap(PixelFrame.init(cgImage:)))
        XCTAssertEqual(saved.height, height)
        XCTAssertTrue(saved.bytes.prefix(20 * rowBytes).elementsEqual(seed.bytes.prefix(20 * rowBytes)))
    }

    func testSecondSegmentRejoinsOnlyItsOwnContentAndPreservesBothSections() throws {
        try checkSecondSegment(withWheel: true)
    }

    func testUnmeasuredSecondSegmentReturnPreservesBothSectionsWhileUncertain() throws {
        try checkSecondSegment(withWheel: false)
    }

    private func checkSecondSegment(withWheel: Bool) throws {
        let first = makePage(seed: 13), second = makePage(seed: 14)
        captureThrough(800, on: first)
        XCTAssertEqual(capture(second, at: 2500).0, .lost)
        XCTAssertTrue(stitcher.startNewSegment(with: shot(second, at: 0), after: stitcher.segmentStart))
        let secondStart = stitcher.segmentStart
        scroll(second, from: 0, to: 1500)
        let rows = stitcher.canvasRows
        XCTAssertEqual(capture(first, at: 2500).0, .lost)
        let returned = capture(second, at: 600, wheel: withWheel ? -900 : nil)
        XCTAssertEqual(returned.1, withWheel ? .found(-900) : .none)
        let reference = secondStart + (withWheel ? 600 : 1500)
        XCTAssertEqual(stitcher.contentOrigin, reference)
        XCTAssertEqual(stitcher.canvasRows, rows)

        XCTAssertEqual(capture(first, at: 2600).0, .lost)
        let (outcome, location) = capture(first, at: 300)
        XCTAssertEqual(outcome, .lost)
        XCTAssertEqual(location, .none)
        XCTAssertTrue(stitcher.needsRecovery)
        XCTAssertEqual(stitcher.contentOrigin, reference)
        XCTAssertEqual(stitcher.canvasRows, rows)
        // The first return to the active section can also be placed by a canvas search.
        for y in stride(from: 700, through: 1400, by: 100) { capture(second, at: y) }
        XCTAssertEqual(stitcher.needsRecovery, !withWheel)

        var expected = Array(first.prefix(1000 * rowBytes))
        let padding = [UInt8](repeating: 255, count: 12 * rowBytes)
        expected += padding
        for _ in 0..<width { expected += [216, 216, 216, 255] }
        expected += padding
        expected += second.prefix(1700 * rowBytes)
        try assertExport(expected[...])
    }

    func testRealChromeRejoinsAtFrameNineAndKeepsTheFollowingViewportsAligned() throws {
        guard let path = ProcessInfo.processInfo.environment["LSP_REJOIN_FIXTURE_DIR"] else {
            throw XCTSkip("Set LSP_REJOIN_FIXTURE_DIR to the directory containing f00.png through f14.png.")
        }
        let base = URL(fileURLWithPath: path, isDirectory: true)
        let seq = base.appendingPathComponent("seq", isDirectory: true)
        let directory = FileManager.default.fileExists(atPath: seq.path) ? seq : base
        let bytesPerRow = 2400 * 4
        var strips: [(row: Int, pixels: [UInt8])] = []
        stitcher.pixelScale = 2
        for i in 0..<15 {
            let name = String(format: "f%02d.png", i)
            let url = directory.appendingPathComponent(name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), name)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), name)
            let frame = try XCTUnwrap(PixelFrame(cgImage: image), name)
            guard frame.width == 2400, frame.height == 1600 else { return XCTFail("Unexpected dimensions for \(name)") }
            let (outcome, location) = stitcher.addOrRejoin(frame, at: Double(i))
            if i == 9 {
                XCTAssertEqual(location, .found(-200), name)
                XCTAssertFalse(stitcher.needsRecovery, name)
            } else if i > 9 {
                XCTAssertEqual(outcome, .shifted(400), name)
            }
            if i >= 9 {
                // This strip is clear of the fixed header and floating controls in every viewport.
                let origin = (i - 9) * 400
                strips.append((origin + 1000, Array(frame.bytes[1000 * bytesPerRow..<1064 * bytesPerRow])))
                if i == 14 { strips.append((origin + 1536, Array(frame.bytes.suffix(64 * bytesPerRow)))) }
            }
        }
        let output = try XCTUnwrap(stitcher.finish().flatMap(PixelFrame.init(cgImage:)))
        XCTAssertEqual(output.width, 2400)
        XCTAssertEqual(output.height, 3600)
        for (y, pixels) in strips {
            let start = y * bytesPerRow
            XCTAssertTrue(output.bytes.dropFirst(start).prefix(pixels.count).elementsEqual(pixels), "Chrome output at y=\(y)")
        }
    }
}
