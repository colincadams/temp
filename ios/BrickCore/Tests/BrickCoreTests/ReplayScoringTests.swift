import XCTest
@testable import BrickCore

/// Matching the pieces a replay counted with the pieces really on the table.
final class ReplayScoringTests: XCTestCase {
    func piece(_ id: Int, _ xMm: Float, _ zMm: Float, radius: Float = 9, long: Float? = 16, short: Float? = 8, rgb: String? = nil) -> ReplaySweep.Piece {
        ReplaySweep.Piece(id: id, partNum: "p\(id)", classId: id, x: xMm / 1000, z: zMm / 1000, radiusMm: radius,
                          longMm: long, shortMm: short, rgb: rgb)
    }

    func tracked(_ xMm: Float, _ zMm: Float, long: Float = 16, short: Float = 8, rgb: String = "808080") -> ReplayRunner.TrackedResult {
        ReplayRunner.TrackedResult(x: xMm / 1000, z: zMm / 1000, longMm: long, shortMm: short, rgb: rgb, sightings: 5, confirmed: true)
    }

    func run(_ tracked: [ReplayRunner.TrackedResult], wholeFrames: [Int: Int], unconfirmed: Int = 0) -> ReplayRunner.Run {
        let extra = (0..<unconfirmed).map { _ in
            ReplayRunner.TrackedResult(x: 5, z: 5, longMm: 10, shortMm: 5, rgb: "000000", sightings: 1, confirmed: false)
        }
        return ReplayRunner.Run(frames: [], tracked: tracked + extra, wholeFrames: wholeFrames, visibilityMethod: "piece maps",
                                matching: "one at a time")
    }

    func sweep(_ pieces: [ReplaySweep.Piece]) -> ReplaySweep {
        ReplaySweep(width: 640, height: 480, fx: 500, fy: 500, cx: 320, cy: 240, tableY: 0, frames: [], pieces: pieces)
    }

    func testEveryPieceFoundOnce() {
        let truth = [piece(0, 0, 0), piece(1, 50, 0), piece(2, 0, 50)]
        let report = ReplayScoring.report(sweep: sweep(truth),
                                          run: run([tracked(1, 1), tracked(51, -2), tracked(-1, 52)], wholeFrames: [0: 5, 1: 5, 2: 5], unconfirmed: 2),
                                          detector: .truth)
        XCTAssertEqual(report.piecesOnTable, 3)
        XCTAssertEqual(report.piecesCouldBeSeen, 3)
        XCTAssertEqual(report.piecesCounted, 3, "unconfirmed pieces are not counted")
        XCTAssertEqual(report.unconfirmedLeft, 2)
        XCTAssertEqual([report.found, report.missed, report.countedTwice, report.merged, report.phantom], [3, 0, 0, 0, 0])
        XCTAssertEqual(report.pieces.map { $0.tracked }, [0, 1, 2])
        XCTAssertEqual(report.positionError.count, 3)
        // Off by √2, √5 and √5 mm.
        XCTAssertEqual(report.positionError.median, Float(5).squareRoot(), accuracy: 0.01)
        XCTAssertEqual(report.positionError.mean, (Float(2).squareRoot() + 2 * Float(5).squareRoot()) / 3, accuracy: 0.01)
    }

    func testPairsAreOneToOneNearestFirst() {
        // Two true pieces 12 mm apart; the first counted piece is nearer the second true piece than the first.
        // Nearest first: it goes to the second, and the other counted piece takes the first.
        let truth = [piece(0, 0, 0), piece(1, 12, 0)]
        let (rows, counted) = ReplayScoring.score(truth: truth, tracked: [tracked(8, 0), tracked(3, 0)], wholeFrames: [0: 3, 1: 3])
        XCTAssertEqual(rows.map { $0.outcome }, [.found, .found])
        XCTAssertEqual(rows.map { $0.tracked }, [1, 0])
        XCTAssertEqual(counted.map { $0.verdict }, [.found, .found])
    }

    func testTwoCountedPiecesOnOneTruePieceIsCountedTwice() {
        let truth = [piece(0, 0, 0), piece(1, 60, 0)]
        let report = ReplayScoring.report(sweep: sweep(truth), run: run([tracked(1, 0), tracked(-4, 3), tracked(60, 0)], wholeFrames: [0: 4, 1: 4]),
                                          detector: .colour)
        XCTAssertEqual([report.found, report.missed, report.countedTwice, report.merged, report.phantom], [2, 0, 1, 0, 0])
        XCTAssertEqual(report.trackedPieces[1].verdict, .countedTwice)
        XCTAssertEqual(report.trackedPieces[1].truePieces, [0])
    }

    func testOneCountedPieceOverTwoTouchingPiecesIsMerged() {
        // Two 1 x 2 plates side by side, taken as one 32 mm blob between them.
        let truth = [piece(0, 0, 0), piece(1, 16, 0), piece(2, 100, 0)]
        let report = ReplayScoring.report(sweep: sweep(truth), run: run([tracked(8, 0, long: 32, short: 8), tracked(100, 0)], wholeFrames: [0: 3, 1: 3, 2: 3]),
                                          detector: .colour)
        XCTAssertEqual([report.found, report.missed, report.missedMergedIntoNeighbour, report.countedTwice, report.merged, report.phantom],
                       [2, 1, 1, 0, 1, 0])
        XCTAssertEqual(report.pieces.map { $0.outcome }, [.found, .merged, .found])
        XCTAssertEqual(report.trackedPieces[0].verdict, .merged)
        XCTAssertEqual(report.trackedPieces[0].truePieces, [0, 1])
        // A merged blob's length says nothing about either piece: only the clean find is measured.
        XCTAssertEqual(report.longError.count, 1)
    }

    func testMergedBlobBetweenPiecesThatMatchesNeitherIsStillMerged() {
        // Its middle is 15 mm from each piece, beyond their 9 mm tolerance, but its outline reaches both.
        let truth = [piece(0, 0, 0), piece(1, 30, 0)]
        let report = ReplayScoring.report(sweep: sweep(truth), run: run([tracked(15, 0, long: 46)], wholeFrames: [0: 3, 1: 3]), detector: .colour)
        XCTAssertEqual([report.found, report.missed, report.missedMergedIntoNeighbour, report.merged, report.phantom], [0, 2, 2, 1, 0])
    }

    func testCountedPieceAwayFromEverythingIsAPhantom() {
        let truth = [piece(0, 0, 0)]
        let report = ReplayScoring.report(sweep: sweep(truth), run: run([tracked(0, 0), tracked(80, 80)], wholeFrames: [0: 3]), detector: .colour)
        XCTAssertEqual([report.found, report.phantom, report.countedTwice], [1, 1, 0])
        // A short outline next to a single unpaired piece is not a merge either.
        let lone = ReplayScoring.report(sweep: sweep(truth), run: run([tracked(20, 0, long: 10)], wholeFrames: [0: 3]), detector: .colour)
        XCTAssertEqual([lone.found, lone.missed, lone.phantom, lone.merged], [0, 1, 1, 0])
    }

    func testOnlyPiecesSeenWholeOftenEnoughCountAgainstTheScan() {
        let truth = [piece(0, 0, 0), piece(1, 50, 0), piece(2, 100, 0)]
        // Piece 1 was seen whole twice, piece 2 never: neither is a miss. Piece 1 was still found.
        let report = ReplayScoring.report(sweep: sweep(truth), run: run([tracked(0, 0), tracked(50, 0)], wholeFrames: [0: 3, 1: 2]), detector: .truth)
        XCTAssertEqual(report.piecesCouldBeSeen, 1)
        XCTAssertEqual([report.found, report.missed, report.foundOutsideFairSet], [1, 0, 1])
        XCTAssertEqual(report.pieces.map { $0.couldBeSeen }, [true, false, false])
    }

    func testToleranceHasAFloorForSmallPieces() {
        // A 1 x 1 round plate has a 4.5 mm radius; the tolerance is at least 8 mm.
        let truth = [piece(0, 0, 0, radius: 4.5, long: 8, short: 8)]
        let (rows, _) = ReplayScoring.score(truth: truth, tracked: [tracked(0, 7, long: 8)], wholeFrames: [0: 3])
        XCTAssertEqual(rows[0].outcome, .found)
        let (far, _) = ReplayScoring.score(truth: truth, tracked: [tracked(0, 9, long: 8)], wholeFrames: [0: 3])
        XCTAssertEqual(far[0].outcome, .missed)
    }

    func testLengthAndColourErrors() {
        let truth = [piece(0, 0, 0, long: 16, short: 8, rgb: "c91a09"), piece(1, 50, 0, long: 32, short: 16, rgb: "0055bf")]
        let counted = [tracked(0, 0, long: 17, short: 8, rgb: "d91a09"), tracked(50, 0, long: 31, short: 18, rgb: "0055bf")]
        let report = ReplayScoring.report(sweep: sweep(truth), run: run(counted, wholeFrames: [0: 3, 1: 3]), detector: .truth)
        XCTAssertEqual(report.lengthSource, "footprint from the renderer")
        XCTAssertEqual(report.longError.count, 2)
        XCTAssertEqual(report.longError.mean, 0, accuracy: 1e-5)
        XCTAssertEqual(report.longError.meanAbsolute, 1, accuracy: 1e-5)
        XCTAssertEqual(report.shortError.mean, 1, accuracy: 1e-5)
        XCTAssertEqual(report.longRatio.median, 17.0 / 16, accuracy: 1e-5)   // the upper middle value
        XCTAssertEqual(report.colourDistance.mean, 8, accuracy: 1e-4)          // 16 apart in red, then 0
        XCTAssertEqual(report.colourBias ?? [], [8, 0, 0])
    }

    func testCatalogSizeIsUsedWhenTheSweepHasNoFootprint() {
        let truth = [piece(0, 0, 0, long: nil, short: nil)]
        let counted = [tracked(0, 0, long: 33, short: 15)]
        let none = ReplayScoring.report(sweep: sweep(truth), run: run(counted, wholeFrames: [0: 3]), detector: .colour)
        XCTAssertEqual(none.lengthSource, "none")
        XCTAssertEqual(none.longError.count, 0)
        XCTAssertEqual(none.measuredLong.median, 33)
        let catalog = ReplayScoring.report(sweep: sweep(truth), run: run(counted, wholeFrames: [0: 3]), detector: .colour,
                                           catalogSize: [0: [32, 16, 9.6]])
        XCTAssertTrue(catalog.lengthSource.hasPrefix("catalog size"))
        XCTAssertEqual(catalog.longError.mean, 1)
        XCTAssertEqual(catalog.shortError.mean, -1)
    }

    func testReportRoundTripsThroughJSONAndReadsPlainly() throws {
        let truth = [piece(0, 0, 0, rgb: "ffffff")]
        let report = ReplayScoring.report(sweep: sweep(truth), run: run([tracked(0, 0)], wholeFrames: [0: 3]), detector: .colour)
        let decoded = try JSONDecoder().decode(ReplayScoring.Report.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        let text = ReplayScoring.text(report, listPieces: true)
        XCTAssertTrue(text.contains("Pieces on the table:"))
        XCTAssertTrue(text.contains("a piece counted twice"))
        XCTAssertTrue(text.contains("p0"))
    }
}
