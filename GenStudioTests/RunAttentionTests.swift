import XCTest
@testable import GenStudio

/// Long local renders (a 30-minute ad, an overnight batch) keep the Mac from idling to sleep, and say when
/// they are done if the owner has walked away from GenStudio.
@MainActor
final class RunAttentionTests: XCTestCase {
    func testTheWakeHoldIsTakenOnceAndReleasedOnce() {
        let guardian = RunWakeGuard()
        XCTAssertFalse(guardian.isHolding)
        guardian.hold(reason: "test"); guardian.hold(reason: "test again")
        XCTAssertTrue(guardian.isHolding)
        guardian.release(); guardian.release()
        XCTAssertFalse(guardian.isHolding)
    }

    func testOnlyLongWorkFinishedInTheBackgroundIsAnnounced() {
        XCTAssertTrue(RunBatchRecord.shouldNotify(elapsed: 120, appActive: false))
        XCTAssertFalse(RunBatchRecord.shouldNotify(elapsed: 120, appActive: true), "The owner is watching")
        XCTAssertFalse(RunBatchRecord.shouldNotify(elapsed: 20, appActive: false), "Quick runs need no notification")
    }

    func testTheNoticeSaysWhatFinishedAndHowItWent() {
        var one = RunBatchRecord(startedAt: Date(timeIntervalSince1970: 0))
        one.record(label: "Ad · 9:16 Export", outcome: .succeeded)
        XCTAssertEqual(one.notice(finishedAt: Date(timeIntervalSince1970: 31 * 60)).title, "Ad · 9:16 Export is ready")
        XCTAssertEqual(one.notice(finishedAt: Date(timeIntervalSince1970: 31 * 60)).body, "Finished after 31 min.")

        var batch = RunBatchRecord(startedAt: Date(timeIntervalSince1970: 0))
        for _ in 0..<7 { batch.record(label: "Shot 1 · Clip", outcome: .succeeded) }
        batch.record(label: "Shot 1 · Clip", outcome: .failed)
        let notice = batch.notice(finishedAt: Date(timeIntervalSince1970: 3_840))
        XCTAssertEqual(notice.title, "8 runs finished")
        XCTAssertEqual(notice.body, "7 done, 1 failed, after 1 h 4 min.")
    }
}
