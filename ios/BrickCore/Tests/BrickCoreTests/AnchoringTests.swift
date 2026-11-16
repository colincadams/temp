import XCTest
@testable import BrickCore

func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-5, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThan(TableMath.distance(a, b), accuracy, "\(a) vs \(b)", file: file, line: line)
}

final class AnchorMathTests: XCTestCase {
    let anchor = Matrix4.yaw(0.3, about: SIMD3(0.1, 0, 0.2), then: SIMD3(0.05, 0.7, -0.02))

    func testRigidInverseUndoesTheTransform() {
        let both = anchor * anchor.rigidInverse
        let p = SIMD3<Float>(0.3, -0.2, 0.9)
        assertClose(both.transformPoint(p), p)
        assertClose((anchor.rigidInverse * anchor).transformPoint(p), p)
        // A camera-like transform with a tilt, not only a yaw.
        let camera = lookingDown(from: SIMD3(0.1, 0.4, -0.3))
        assertClose((camera.rigidInverse * camera).transformPoint(p), p)
        XCTAssertEqual(Matrix4.identity.rotationAngle, 0, accuracy: 1e-3)
        XCTAssertEqual(Matrix4.yaw(0.2).rotationAngle, 0.2, accuracy: 1e-3)
    }

    func testYawTurnsAboutItsPivotThenShifts() {
        let m = Matrix4.yaw(Float.pi / 2, about: SIMD3(1, 0, 0), then: SIMD3(0, 0, 0.5))
        assertClose(m.transformPoint(SIMD3(1, 0, 0)), SIMD3(1, 0, 0.5))           // the pivot only shifts
        assertClose(m.transformPoint(SIMD3(2, 0, 0)), SIMD3(1, 0, -0.5))          // +x turns to -z, then shifts
        assertClose(m.transformVector(SIMD3(1, 0, 0)), SIMD3(0, 0, -1))           // vectors turn but do not shift
    }

    func testOffsetFromAnAnchorFollowsTheAnchor() {
        let p = SIMD3<Float>(0.12, 0.7, 0.31)
        let offset = AnchorMath.offset(of: p, from: anchor)
        assertClose(AnchorMath.point(offset: offset, in: anchor), p)
        // ARKit corrects its map: the anchor moves 2 cm and turns half a degree.
        let moved = Matrix4.yaw(0.5 * Float.pi / 180, about: anchor.translationPart, then: SIMD3(0.02, 0, -0.01)) * anchor
        let expressed = AnchorMath.point(offset: offset, in: moved)
        XCTAssertGreaterThan(TableMath.distance(expressed, p), 0.02)
        // One transform does the same for every point.
        assertClose(AnchorMath.motion(from: anchor, to: moved).transformPoint(p), expressed)
        // The piece keeps its place relative to the anchor.
        XCTAssertEqual(TableMath.distance(expressed, moved.translationPart), TableMath.distance(p, anchor.translationPart), accuracy: 1e-5)
    }

    func testNearestAnchorIsByDistanceOnTheTable() {
        let a = UUID(), b = UUID()
        let anchors = [a: Matrix4.translation(SIMD3(0, 0.7, 0)), b: Matrix4.translation(SIMD3(0.2, 0.0, 0))]
        // b is lower down, but nearer across the table.
        XCTAssertEqual(AnchorMath.nearest(to: SIMD3(0.15, 0.7, 0), among: anchors), b)
        XCTAssertEqual(AnchorMath.nearest(to: SIMD3(0.05, 0.7, 0.01), among: anchors), a)
        XCTAssertNil(AnchorMath.nearest(to: .zero, among: [:]))
    }
}

final class AnchorSetTests: XCTestCase {
    func testNewPiecesShareRecentNearbyAnchorsOnly() {
        var set = AnchorSet()
        set.moveCamera(to: SIMD3(0, 0.3, 0))
        XCTAssertNil(set.anchor(for: SIMD3(0.01, 0, 0)), "no anchors yet")
        let first = UUID()
        let transform = set.anchorTransform(for: SIMD3(0.01, 0.02, 0), tableY: 0)
        XCTAssertEqual(transform.translationPart, SIMD3(0.01, 0, 0), "on the table, under the piece")
        set.register(first, at: transform)
        XCTAssertTrue(set.owns(first))
        XCTAssertEqual(set.anchor(for: SIMD3(0.08, 0, 0.05)), first, "8.6 cm away: within reach")
        XCTAssertNil(set.anchor(for: SIMD3(0.12, 0, 0)), "11 cm away: too far")
        // The camera moves on 10 cm: still recent.
        set.moveCamera(to: SIMD3(0.1, 0.3, 0))
        XCTAssertEqual(set.anchor(for: SIMD3(0.02, 0, 0)), first)
        // And 6 cm more: 16 cm of travel since the anchor was made, so the map it is tied to may have drifted since.
        set.moveCamera(to: SIMD3(0.1, 0.3, 0.06))
        XCTAssertEqual(set.travelled, 0.16, accuracy: 1e-5)
        XCTAssertNil(set.anchor(for: SIMD3(0.02, 0, 0)))
        // The nearest recent one wins.
        let second = UUID(), third = UUID()
        set.register(second, at: .translation(SIMD3(0.05, 0, 0)))
        set.register(third, at: .translation(SIMD3(0.0, 0, 0)))
        XCTAssertEqual(set.anchor(for: SIMD3(0.04, 0, 0)), second)
        set.reset()
        XCTAssertFalse(set.owns(second))
        XCTAssertEqual(set.travelled, 0)
    }
}

final class PieceAnchoringTests: XCTestCase {
    func testCorrectionsCarryTheBoundPiecesOnce() {
        var anchoring = PieceAnchoring()
        let a = UUID(), b = UUID(), p1 = UUID(), p2 = UUID(), p3 = UUID()
        let ta = Matrix4.translation(SIMD3(0, 0.7, 0)), tb = Matrix4.translation(SIMD3(0.2, 0.7, 0))
        anchoring.bind(piece: p1, to: a, transform: ta)
        anchoring.bind(piece: p2, to: a, transform: ta)
        anchoring.bind(piece: p3, to: b, transform: tb)
        XCTAssertTrue(anchoring.corrections(current: [a: ta, b: tb]).isEmpty, "nothing moved")
        // A nudge of a fifth of a millimetre builds up rather than being applied.
        let nudged = Matrix4.translation(SIMD3(0.0002, 0, 0)) * ta
        XCTAssertTrue(anchoring.corrections(current: [a: nudged]).isEmpty)
        // A 1 cm correction to a: both its pieces move, b's piece does not.
        let moved = Matrix4.translation(SIMD3(0.01, 0, 0)) * ta
        let corrections = anchoring.corrections(current: [a: moved, b: tb])
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(Set(corrections[0].pieces), [p1, p2])
        assertClose(corrections[0].motion.transformPoint(SIMD3(0.05, 0.7, 0.05)), SIMD3(0.06, 0.7, 0.05))
        XCTAssertTrue(anchoring.corrections(current: [a: moved, b: tb]).isEmpty, "applied once")
        // A turn alone counts too.
        let turned = Matrix4.yaw(0.01, about: tb.translationPart) * tb
        XCTAssertEqual(anchoring.corrections(current: [b: turned]).map { $0.pieces }, [[p3]])
        anchoring.forget(piece: p1)
        let again = Matrix4.translation(SIMD3(0, 0, 0.01)) * moved
        XCTAssertEqual(anchoring.corrections(current: [a: again]).map { $0.pieces }, [[p2]])
        XCTAssertNil(anchoring.anchorOf[p1])
    }

    /// The whole loop, as ScanEngine drives it: a piece seen in a drifted world, ARKit corrects the map, the piece is
    /// carried with its anchor, so the next detection in the corrected world matches it instead of starting a second one.
    func testAnchoredPieceIsNotCountedTwiceAfterAMapCorrection() {
        for anchored in [false, true] {
            let tracker = PieceTracker()
            var anchoring = PieceAnchoring()
            let drift = Matrix4.yaw(0.005, about: .zero, then: SIMD3(0.02, 0, 0.01))   // 2.2 cm and 0.3 degrees
            let truth = SIMD3<Float>(0.05, 0, 0.03)
            let camera = SIMD3<Float>(0.05, 0.3, 0.03)
            let anchorID = UUID()
            // The anchor is made in the drifted world, at the piece.
            let anchorTransform = Matrix4.translation(drift.transformPoint(truth))
            func observe(_ world: Matrix4, time: TimeInterval) {
                tracker.beginFrame()
                let seen = PieceObservation(position: world.transformPoint(truth), longMm: 16, shortMm: 8, r: 200, g: 30, b: 30,
                                            quality: 1, cameraPosition: world.transformPoint(camera))
                if let piece = tracker.observe(frame: [seen], time: time)[0], anchoring.anchorOf[piece.id] == nil {
                    anchoring.bind(piece: piece.id, to: anchorID, transform: anchorTransform)
                }
                tracker.endFrame(time: time)
            }
            for i in 0..<4 { observe(drift, time: Double(i) * 0.2) }
            XCTAssertEqual(tracker.pieces.count, 1)
            // ARKit corrects its map: the world drops back to the true one, and the anchor moves with it.
            if anchored {
                let corrected = drift.rigidInverse * anchorTransform
                for c in anchoring.corrections(current: [anchorID: corrected]) {
                    for id in c.pieces { tracker.move(tracker.piece(id: id)!, by: c.motion) }
                }
                XCTAssertLessThan(TableMath.distance(tracker.pieces[0].position, truth), 1e-4)
            }
            for i in 4..<8 { observe(.identity, time: Double(i) * 0.2) }
            XCTAssertEqual(tracker.confirmed.count, anchored ? 1 : 2, anchored ? "anchored" : "not anchored")
        }
    }

    func testMovingATallPieceMovesWhereItsViewsPlaceIt() {
        let tracker = PieceTracker()
        // A 20 mm tall piece seen from three cameras around it: its height is fitted from how its spot slides.
        let base = SIMD3<Float>(0, 0, 0)
        let lift: Float = 0.01
        for (i, c) in [SIMD3<Float>(-0.08, 0.3, 0), SIMD3<Float>(0.08, 0.3, 0), SIMD3<Float>(0, 0.3, 0.08)].enumerated() {
            tracker.beginFrame()
            let spot = base + (base - SIMD3(c.x, 0, c.z)) * (lift / (c.y - lift))
            tracker.observe(frame: [PieceObservation(position: spot, longMm: 16, shortMm: 8, r: 0, g: 0, b: 200, quality: 1,
                                                     cameraPosition: c)], time: Double(i) * 0.2)
        }
        let piece = tracker.pieces[0]
        XCTAssertEqual(piece.heightSource, .views)
        let motion = Matrix4.yaw(0.02, about: .zero, then: SIMD3(0.03, 0, 0))
        let expected = motion.transformPoint(piece.position)
        tracker.move(piece, by: motion)
        assertClose(piece.position, expected)
        // The next view, from the moved world, refits the piece at the moved base, not half-way back.
        let c = motion.transformPoint(SIMD3(0.05, 0.3, -0.05))
        let movedBase = motion.transformPoint(base)
        let spot = movedBase + (movedBase - SIMD3(c.x, 0, c.z)) * (lift / (c.y - lift))
        tracker.beginFrame()
        let matched = tracker.observe(frame: [PieceObservation(position: spot, longMm: 16, shortMm: 8, r: 0, g: 0, b: 200, quality: 1,
                                                               cameraPosition: c)], time: 0.8)
        XCTAssertTrue(matched[0] === piece)
        XCTAssertLessThan(TableMath.distance(piece.position, movedBase), 0.001)
    }
}

final class TrackerPassTests: XCTestCase {
    func observation(x: Float) -> PieceObservation {
        PieceObservation(position: SIMD3(x, 0, 0), longMm: 16, shortMm: 8, r: 200, g: 30, b: 30, quality: 1)
    }

    func testAFreshPassKeepsConfirmedPiecesButNeverMatchesThem() {
        let tracker = PieceTracker()
        for i in 0..<3 {
            tracker.beginFrame()
            tracker.observe(frame: [observation(x: 0), i == 0 ? observation(x: 0.1) : nil].compactMap { $0 }, time: Double(i) * 0.2)
            tracker.endFrame(time: Double(i) * 0.2)
        }
        XCTAssertEqual(tracker.pieces.count, 2)
        XCTAssertEqual(tracker.confirmed.count, 1)
        let old = tracker.confirmed[0]
        let dropped = tracker.startNewPass()
        XCTAssertEqual(dropped.count, 1, "the unconfirmed blob goes")
        XCTAssertEqual(tracker.currentPass, 1)
        XCTAssertTrue(tracker.currentPieces.isEmpty)
        // The same spot in the new world is a new piece: the old world's coordinates mean nothing now.
        for i in 3..<6 {
            tracker.beginFrame()
            let matched = tracker.observe(frame: [observation(x: 0)], time: Double(i) * 0.2)
            XCTAssertFalse(matched[0] === old)
            tracker.endFrame(time: Double(i) * 0.2)
        }
        XCTAssertEqual(tracker.confirmed.count, 2, "both passes are counted")
        XCTAssertEqual(tracker.currentConfirmed.count, 1)
        XCTAssertEqual(old.pass, 0)
        XCTAssertEqual(old.sightings, 3, "never matched again")
        // Old pieces are not pruned however long they go unseen.
        tracker.endFrame(time: 100)
        XCTAssertEqual(tracker.confirmed.count, 2)
        tracker.reset()
        XCTAssertEqual(tracker.currentPass, 0)
    }
}

final class DriftReplayTests: XCTestCase {
    /// The camera holds still over the tiny sweep's pieces. The reported world starts 2 cm off and is corrected at
    /// frame 3: without anchors every piece it sees gets a second track; with them none does.
    func testAnchorsKeepAMapCorrectionFromCountingPiecesTwice() throws {
        let cameras: [(x: Float, time: Double)] = (0..<7).map { (-0.03, Double($0) * 0.2) }
        let sweep = ReplayRunnerTests.sweep(cameras: cameras)
        let images = sweep.frames.map { ReplayRunnerTests.render(sweep, frame: $0) }
        var settings = ReplayRunner.Settings()
        settings.matchWholeFrame = true
        var drift = DriftSimulation.Settings()
        drift.initialDrift = 0.02
        drift.correctionFrame = 3
        settings.drift = drift
        var counts: [Bool: (twice: Int, counted: Int)] = [:]
        for anchored in [false, true] {
            settings.anchoring = anchored
            let run = try ReplayRunner.run(sweep: sweep, detector: .truth, settings: settings) { index in
                ReplayFrameData(rgba: images[index].rgba, ids: images[index].ids)
            }
            XCTAssertEqual(run.driftCorrectionFrame, 3)
            XCTAssertTrue(run.frames.allSatisfy { $0.skipped == nil }, "a 2 cm jump in 0.2 s is not too fast")
            let report = ReplayScoring.report(sweep: sweep, run: run, detector: .truth)
            counts[anchored] = (report.countedTwice + report.phantom, report.piecesCounted)
            if anchored {
                XCTAssertGreaterThan(run.anchorsMade, 0)
                XCTAssertGreaterThan(run.anchorMoves, 0)
            }
        }
        let seen = 4   // the pieces camera A shows whole
        XCTAssertEqual(counts[true]!.counted, seen)
        XCTAssertEqual(counts[true]!.twice, 0)
        // Without anchors the pieces are counted again in the corrected world: all but the 32 mm one, whose match radius
        // (half its length, 16 mm) nearly reaches across the 2 cm.
        XCTAssertGreaterThanOrEqual(counts[false]!.counted, 2 * seen - 1)
        XCTAssertGreaterThanOrEqual(counts[false]!.twice, seen - 1)
    }
}
