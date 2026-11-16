import XCTest
@testable import BrickCore

/// The replay options for the three techniques, on the small synthetic sweep of `ReplayRunnerTests`.
final class ConsolidationReplayTests: XCTestCase {
    func testTechniquesLeaveACleanSweepAloneAndRemoveInjectedPhantoms() throws {
        let sweep = ReplayRunnerTests.sweep(cameras: ReplayRunnerTests.twoPositions)
        let folder = try ReplayFolder(url: try ReplayRunnerTests.writeSweep(sweep))
        defer { try? FileManager.default.removeItem(at: folder.url) }

        var settings = ReplayRunner.Settings()
        settings.sharpnessGate = true
        settings.sharpnessViews = true
        settings.negativeEvidence = true
        settings.consolidate = true
        let run = try ReplayRunner.run(folder: folder, detector: .truth, settings: settings)
        XCTAssertEqual(run.techniques, ["sharpness gate", "sharpness in view quality", "negative evidence", "consolidation"])
        XCTAssertFalse(run.frames.contains { $0.skipped == ReplayRunner.skippedBlurred }, "no frame of a still scene is blurred")
        XCTAssertEqual(run.consolidationMerges, 0)
        let report = ReplayScoring.report(sweep: folder.sweep, run: run, detector: .truth)
        XCTAssertEqual([report.found, report.missed, report.countedTwice, report.merged, report.phantom], [5, 0, 0, 0, 0])
        XCTAssertEqual(report.setAsideDoubtful, ReplayScoring.SetAside())
        XCTAssertEqual(report.framesRejectedBlurred, 0)
        XCTAssertNotNil(report.sharpnessFrameMs)
        XCTAssertNil(report.blurredFramesProcessed, "the sweep records no blur")

        // Phantoms at random free spots; only those whose spot some view shows well inside are ever reported.
        // On a sweep whose last camera position keeps looking at the reported one for 6 frames after its 3 hits, it is
        // set aside, and no real piece is.
        let long = ReplayRunnerTests.sweep(cameras: ReplayRunnerTests.twoPositions + (7..<13).map { (0.04, Double($0) * 0.2) })
        let longFolder = try ReplayFolder(url: try ReplayRunnerTests.writeSweep(long))
        defer { try? FileManager.default.removeItem(at: longFolder.url) }
        var phantoms = ReplayRunner.Settings()
        phantoms.phantoms = 6
        phantoms.phantomSeed = 3
        let plain = try ReplayRunner.run(folder: longFolder, detector: .truth, settings: phantoms)
        XCTAssertEqual(plain.phantomsPlaced, 6)
        XCTAssertEqual(plain.frames.map { $0.phantoms }, [0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0], "one is in view: three frames, then never")
        let plainReport = ReplayScoring.report(sweep: longFolder.sweep, run: plain, detector: .truth)
        XCTAssertEqual([plainReport.found, plainReport.phantom, plainReport.phantomsInjected], [5, 1, 6])

        phantoms.negativeEvidence = true
        let checked = try ReplayRunner.run(folder: longFolder, detector: .truth, settings: phantoms)
        let ghost = try XCTUnwrap(checked.tracked.first { $0.doubtful })
        XCTAssertEqual([ghost.hits, ghost.misses], [3, 6])
        let checkedReport = ReplayScoring.report(sweep: longFolder.sweep, run: checked, detector: .truth)
        XCTAssertEqual([checkedReport.found, checkedReport.phantom], [5, 0])
        XCTAssertEqual(checkedReport.setAsideDoubtful, ReplayScoring.SetAside(pieces: 1, duplicate: 0, phantom: 1, realPieceLost: 0))
        XCTAssertEqual(checkedReport.viewMissRate ?? 1, 0, accuracy: 1e-6)
    }
}
