import XCTest
@testable import BrickCore

final class VisibilityTests: XCTestCase {
    // A 640 x 480 camera 30 cm over the table looking straight down: about 0.47 mm per pixel, a view 30 x 22 cm.
    let width: Float = 640, height: Float = 480, f: Float = 640

    func projector(x: Float, z: Float = 0) -> TableProjector {
        TableProjector(fx: f, fy: f, cx: width / 2, cy: height / 2, camera: lookingDown(from: SIMD3(x, 0.3, z)), tableY: 0)
    }

    func observation(x: Float, z: Float, long: Float = 16) -> PieceObservation {
        PieceObservation(position: SIMD3(x, 0, z), longMm: long, shortMm: 8, r: 200, g: 40, b: 30, quality: 1)
    }

    /// One processed frame, driven the way ScanEngine should: match, record visibility, end the frame.
    func frame(_ tracker: PieceTracker, _ ledger: inout VisibilityLedger, camera: TableProjector,
               detections: [PieceObservation], time: TimeInterval) {
        tracker.beginFrame()
        let matched = tracker.observe(frame: detections, time: time)
        ledger.record(view: camera, imageWidth: width, imageHeight: height, pieces: tracker.pieces,
                      matched: Set(matched.compactMap { $0?.id }))
        for id in tracker.endFrame(time: time) { ledger.forget(id) }
    }

    func testPhantomSeenForThreeFramesIsSetAsideWhileTheCameraKeepsLookingAtIt() {
        let tracker = PieceTracker()
        var ledger = VisibilityLedger()
        let real = observation(x: 0.05, z: 0.02)
        let phantom = observation(x: -0.03, z: -0.01, long: 30)   // a shadow, say
        var time: TimeInterval = 0
        // The camera drifts slowly; both spots stay well inside every view.
        for i in 0..<15 {
            let detections = i < 3 ? [real, phantom] : [real]
            frame(tracker, &ledger, camera: projector(x: Float(i) * 0.002), detections: detections, time: time)
            time += 0.2
        }
        XCTAssertEqual(tracker.confirmed.count, 2, "the tracker alone keeps the phantom for ever")
        let ghost = tracker.confirmed.first { $0.longMm > 20 }!
        let piece = tracker.confirmed.first { $0.longMm < 20 }!
        XCTAssertTrue(ledger.isDoubtful(ghost.id))
        XCTAssertFalse(ledger.isDoubtful(piece.id))
        XCTAssertEqual(ledger.entry(ghost.id).hits, 3)
        XCTAssertEqual(ledger.entry(ghost.id).misses, 12)
        XCTAssertEqual(tracker.confirmed.filter { !ledger.isDoubtful($0.id) }.map { $0.id }, [piece.id])

        // 3 hits then misses: doubtful from the fifth miss (2 more misses than hits), not before.
        var fresh = VisibilityLedger()
        let id = UUID()
        for _ in 0..<3 { fresh.hit(id) }
        for n in 1...5 {
            fresh.miss(id)
            XCTAssertEqual(fresh.isDoubtful(id), n == 5, "after \(n) misses")
        }
    }

    func testRealPieceMissedNowAndThenSurvives() {
        let tracker = PieceTracker()
        var ledger = VisibilityLedger()
        let real = observation(x: 0.01, z: 0.0)
        for i in 0..<40 {
            // Missed in one frame in four, and twice in a row now and then: the detector's ordinary misses.
            let missed = i % 4 == 3 || i == 20 || i == 21
            frame(tracker, &ledger, camera: projector(x: 0), detections: missed ? [] : [real], time: Double(i) * 0.2)
        }
        let piece = tracker.confirmed[0]
        XCTAssertGreaterThan(ledger.entry(piece.id).misses, 8)
        XCTAssertFalse(ledger.isDoubtful(piece.id))
    }

    func testOnlyViewsThatShowTheSpotWellCountAsMisses() {
        let tracker = PieceTracker()
        var ledger = VisibilityLedger()
        let piece = observation(x: 0, z: 0)
        for i in 0..<3 { frame(tracker, &ledger, camera: projector(x: 0), detections: [piece], time: Double(i) * 0.2) }
        let id = tracker.confirmed[0].id
        // The view's half-width on the table is 15 cm; with the 5% inset and the piece's own size, a camera 14 cm
        // away puts the piece too near the edge to count, and one 40 cm away does not see it at all.
        for (i, x) in [Float(0.14), -0.14, 0.4, 0.4, 0.4, 0.4].enumerated() {
            frame(tracker, &ledger, camera: projector(x: x), detections: [], time: 0.6 + Double(i) * 0.2)
        }
        XCTAssertEqual(ledger.entry(id).misses, 0)
        frame(tracker, &ledger, camera: projector(x: 0.10), detections: [], time: 2)
        XCTAssertEqual(ledger.entry(id).misses, 1, "10 cm away it is still well inside")
    }

    func testDoubtfulPieceSeenAgainIsRestored() {
        var ledger = VisibilityLedger()
        let id = UUID()
        for _ in 0..<3 { ledger.hit(id) }
        for _ in 0..<20 { ledger.miss(id) }
        XCTAssertTrue(ledger.isDoubtful(id))
        XCTAssertEqual(ledger.entry(id).evidence, ledger.settings.minEvidence, accuracy: 1e-5, "capped")
        ledger.hit(id)
        XCTAssertTrue(ledger.isDoubtful(id))
        ledger.hit(id)
        XCTAssertFalse(ledger.isDoubtful(id), "two sightings bring it back")
        ledger.forget(id)
        XCTAssertEqual(ledger.entry(id), VisibilityLedger.Entry())
    }

    func testLongSeenPieceIsFlaggedAfterSevenMissesInARow() {
        var ledger = VisibilityLedger()
        let id = UUID()
        for _ in 0..<50 { ledger.hit(id) }
        for _ in 0..<6 { ledger.miss(id) }
        XCTAssertFalse(ledger.isDoubtful(id))
        ledger.miss(id)
        XCTAssertTrue(ledger.isDoubtful(id), "the cap keeps old sightings from outweighing a piece that has gone")
    }

    func testAnUnreliableDetectorNeedsMoreMisses() {
        var settings = VisibilityLedger.Settings()
        settings.detectorMissRate = 0.6
        XCTAssertEqual(settings.hitWeight, log(2), accuracy: 1e-5)
        XCTAssertEqual(settings.missWeight, log(0.8 / 0.6), accuracy: 1e-5)
        var ledger = VisibilityLedger(settings: settings)
        let id = UUID()
        for _ in 0..<3 { ledger.hit(id) }
        for _ in 0..<5 { ledger.miss(id) }
        XCTAssertFalse(ledger.isDoubtful(id), "5 misses prove little when the detector misses 60% of the time")
        for _ in 0..<12 { ledger.miss(id) }
        XCTAssertTrue(ledger.isDoubtful(id))
    }

    func testPolygonContainment() {
        let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        for polygon in [square, square.reversed()] {
            XCTAssertTrue(VisibilityLedger.contains(polygon, SIMD2(0.5, 0.5)))
            XCTAssertTrue(VisibilityLedger.contains(polygon, SIMD2(0.5, 0.5), margin: 0.45))
            XCTAssertFalse(VisibilityLedger.contains(polygon, SIMD2(0.5, 0.5), margin: 0.55))
            XCTAssertFalse(VisibilityLedger.contains(polygon, SIMD2(1.2, 0.5)))
        }
        XCTAssertFalse(VisibilityLedger.contains([], SIMD2(0, 0)))
    }
}
