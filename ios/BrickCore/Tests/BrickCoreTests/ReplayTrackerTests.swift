import XCTest
@testable import BrickCore

/// Tracking problems the replay harness found, and `PieceTracker.observe(frame:time:)`, which fixes the first.
final class ReplayTrackerTests: XCTestCase {
    func observation(_ xMm: Float, _ zMm: Float, long: Float) -> PieceObservation {
        PieceObservation(position: SIMD3(xMm / 1000, 0, zMm / 1000), longMm: long, shortMm: long / 2, r: 0, g: 0, b: 0, quality: 1)
    }

    /// Found on a rendered sweep: a 1 x 2 plate (A) is tracked; then a 1 x 8 tile (B) lying 25 mm away comes fully
    /// into view. B's 62 mm length gives it a 31 mm match radius, so when its detection is handled first it takes over
    /// A's track, and A's own detection, finding its track taken, starts a second one. A ends up counted twice.
    func testANewPieceDetectedFirstTakesOverItsNeighboursTrack() {
        let tracker = PieceTracker()
        for frame in 0..<3 {
            tracker.beginFrame()
            tracker.observe(observation(0, 0, long: 25), time: Double(frame) * 0.2)
            tracker.endFrame(time: Double(frame) * 0.2)
        }
        XCTAssertEqual(tracker.confirmed.count, 1)
        let a = tracker.pieces[0]

        tracker.beginFrame()
        let forB = tracker.observe(observation(21, -16, long: 62), time: 0.6)   // B, first in the list
        let forA = tracker.observe(observation(-0.8, 0.5, long: 25), time: 0.6)
        tracker.endFrame(time: 0.6)
        XCTAssertTrue(forB === a, "B took A's track")
        XCTAssertFalse(forA === a, "A started a second track")
        XCTAssertEqual(tracker.pieces.count, 2)
    }

    func testMatchingAWholeFrameAtOnceKeepsEachTrackWithItsNearestDetection() {
        for order in [[0, 1], [1, 0]] {
            let tracker = PieceTracker()
            for frame in 0..<3 {
                tracker.beginFrame()
                tracker.observe(frame: [observation(0, 0, long: 25)], time: Double(frame) * 0.2)
                tracker.endFrame(time: Double(frame) * 0.2)
            }
            let a = tracker.pieces[0]
            let detections = [observation(21, -16, long: 62), observation(-0.8, 0.5, long: 25)]
            tracker.beginFrame()
            let result = tracker.observe(frame: order.map { detections[$0] }, time: 0.6)
            tracker.endFrame(time: 0.6)
            let forA = result[order.firstIndex(of: 1)!], forB = result[order.firstIndex(of: 0)!]
            XCTAssertTrue(forA === a, "A keeps its track, order \(order)")
            XCTAssertNotNil(forB)
            XCTAssertFalse(forB === a, "B starts its own, order \(order)")
            XCTAssertEqual(a.sightings, 4)
            XCTAssertEqual(tracker.pieces.count, 2)
        }
    }

    func testMatchingAWholeFrameBehavesLikeOneAtATimeOtherwise() {
        let tracker = PieceTracker()
        tracker.beginFrame()
        let first = tracker.observe(frame: [observation(0, 0, long: 16), observation(100, 0, long: 16), observation(0, 0, long: 1)], time: 0)
        tracker.endFrame(time: 0)
        XCTAssertNotNil(first[0])
        XCTAssertNotNil(first[1])
        XCTAssertNil(first[2], "too small to be a piece")
        XCTAssertEqual(tracker.pieces.count, 2)

        // Two detections near one piece in the same frame: the nearer one gets it, the other starts a new piece.
        tracker.beginFrame()
        let second = tracker.observe(frame: [observation(6, 0, long: 16), observation(2, 0, long: 16)], time: 0.2)
        tracker.endFrame(time: 0.2)
        XCTAssertTrue(second[1] === first[0])
        XCTAssertFalse(second[0] === first[0])
        XCTAssertEqual(tracker.pieces.count, 3)
        // Position blends a quarter of the way to the new detection, as with one at a time.
        XCTAssertEqual(first[0]!.position.x, 0.0005, accuracy: 1e-6)
        XCTAssertEqual(first[0]!.sightings, 2)
        XCTAssertEqual(first[0]!.longSamples, [16, 16])
    }
}
