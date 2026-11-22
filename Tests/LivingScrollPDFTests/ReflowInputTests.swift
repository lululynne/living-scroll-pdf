import XCTest
@testable import LivingScrollPDF

final class ReflowInputTests: XCTestCase {
    private func search(_ verdict: Stitcher.LocateVerdict, at time: Double, tracker: ManualTracker? = nil,
                        auto: Bool = false, recovery: inout ReflowRecovery) {
        let shot = recovery.snapshot(at: time, tracker: tracker, auto: auto)
        recovery.observe(verdict, from: shot, tracker: tracker, firstLoss: false)
    }

    func testRepeatedKeysAndDragsKeepTheLossClock() {
        var tracker = ManualTracker(body: 400, pixelScale: 1)
        tracker.wheel(deltaY: -120, precise: true, at: 9)
        var recovery = ReflowRecovery()
        for time in [10.0, 10.5, 11.5, 12.9, 13.0] {
            tracker.invalidateWheel()
            recovery.invalidateWheel()
            search(.none, at: time, tracker: tracker, recovery: &recovery)
            XCTAssertEqual(recovery.pageReflowed, time >= 13)
        }
        XCTAssertFalse(recovery.seekingUnchangedArea)
    }

    func testOnlyActualConsecutiveMissesCanOfferASection() {
        var recovery = ReflowRecovery()
        search(.none, at: 1, recovery: &recovery)
        for time in [2.0, 3.0, 4.0, 5.0] { search(.skipped, at: time, recovery: &recovery) }
        search(.none, at: 5.2, recovery: &recovery)
        XCTAssertFalse(recovery.pageReflowed, "Only two searches ran")

        search(.found(0), at: 5.6, recovery: &recovery)
        for time in [6.0, 6.4, 6.8] { search(.none, at: time, recovery: &recovery) }
        XCTAssertFalse(recovery.pageReflowed, "The new loss is less than three seconds old")
        search(.skipped, at: 9.1, recovery: &recovery)
        XCTAssertFalse(recovery.pageReflowed)
        search(.none, at: 9.5, recovery: &recovery)
        XCTAssertTrue(recovery.pageReflowed)
    }

    func testWheelShotBeforeAKeyCannotBackdateTheKeyLoss() {
        var tracker = ManualTracker(body: 400, pixelScale: 1)
        tracker.wheel(deltaY: -400, precise: true, at: 0)
        var recovery = ReflowRecovery()
        for time in 0...5 { search(.none, at: Double(time), tracker: tracker, recovery: &recovery) }
        XCTAssertFalse(recovery.pageReflowed, "The wheel has not returned to the break")

        let beforeKey = recovery.snapshot(at: 6, tracker: tracker, auto: false)
        tracker.invalidateWheel()
        recovery.invalidateWheel()
        recovery.observe(.none, from: beforeKey, tracker: tracker, firstLoss: false)
        for time in [9.5, 9.9, 10.3] { search(.none, at: time, tracker: tracker, recovery: &recovery) }
        XCTAssertFalse(recovery.pageReflowed)
        search(.none, at: 12.5, tracker: tracker, recovery: &recovery)
        XCTAssertTrue(recovery.pageReflowed)
    }

    func testOnlyWheelReturnsAlreadyInTheShotCanCount() {
        var tracker = ManualTracker(body: 400, pixelScale: 1)
        tracker.wheel(deltaY: -400, precise: true, at: 0)
        var recovery = ReflowRecovery()
        let first = recovery.snapshot(at: 0, tracker: tracker, auto: false)
        recovery.observe(.none, from: first, tracker: tracker, firstLoss: true)
        let beforeReturn = recovery.snapshot(at: 0.4, tracker: tracker, auto: false)

        func move(_ delta: Double, at time: Double) {
            tracker.wheel(deltaY: delta, precise: true, at: time)
            recovery.wheel(at: tracker.wheelScreens)
        }
        move(360, at: 0.5)
        recovery.observe(.none, from: beforeReturn, tracker: tracker, firstLoss: false)
        move(-200, at: 0.6)
        move(200, at: 0.7)
        search(.none, at: 0.8, tracker: tracker, recovery: &recovery)
        XCTAssertFalse(recovery.pageReflowed, "Only the second return has been photographed")
        move(-200, at: 1.0)
        move(200, at: 1.1)
        search(.none, at: 1.2, tracker: tracker, recovery: &recovery)
        XCTAssertTrue(recovery.pageReflowed)
    }

    func testAutoPauseKeepsItsLossEvidenceWhenManualCaptureResumes() {
        var tracker = ManualTracker(body: 400, pixelScale: 1)
        tracker.wheel(deltaY: -240, precise: true, at: 19)
        var recovery = ReflowRecovery()
        var pacer = AutoPacer()
        var action = AutoPacer.Action.resample
        for time in [20.0, 20.4, 20.8, 21.2, 21.6, 22.0] {
            search(.none, at: time, tracker: tracker, auto: true, recovery: &recovery)
            action = pacer.next(after: .lost)
            if case .scroll(let fraction) = action { pacer.sent(fraction) }
        }
        XCTAssertEqual(action, .pause)
        XCTAssertFalse(recovery.pageReflowed)
        tracker.invalidateWheel()
        recovery.invalidateWheel()
        var hold = ManualTracker.HUDHold()
        hold.autoPausedUntil = 26
        var hud = ManualTracker.HUDInput(now: 22, recovering: true, frames: 8, shownPx: 1200)
        XCTAssertTrue(ManualTracker.hudLine(hud, hold: &hold).contains(L("自动已暂停", "auto-scroll paused")))

        search(.none, at: 23, tracker: tracker, recovery: &recovery)
        XCTAssertTrue(recovery.pageReflowed)
        hud.now = 23
        hud.pageReflowed = recovery.pageReflowed
        XCTAssertTrue(ManualTracker.hudLine(hud, hold: &hold).hasPrefix(L("接不回原处", "Can’t rejoin the original spot")))
    }

    func testAutoCanOfferASectionWhileItIsStillRetrying() {
        var recovery = ReflowRecovery()
        for time in [1.0, 2.5, 4.0] { search(.none, at: time, auto: true, recovery: &recovery) }
        var hold = ManualTracker.HUDHold()
        let hud = ManualTracker.HUDInput(now: 4, recovering: true, pageReflowed: recovery.pageReflowed,
                                         autoScroll: true, frames: 8, shownPx: 1200)
        XCTAssertTrue(ManualTracker.hudLine(hud, hold: &hold).contains(L("接着拼", "Continue Here")))
    }
}
