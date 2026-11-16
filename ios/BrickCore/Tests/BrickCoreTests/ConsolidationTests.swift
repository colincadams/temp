import XCTest
@testable import BrickCore

final class ConsolidationTests: XCTestCase {
    func track(_ xMm: Float, _ zMm: Float, long: Float = 20, rgb: SIMD3<Float> = SIMD3(200, 40, 30), sightings: Int = 5,
               frames: [Int]) -> TrackConsolidation.Track {
        TrackConsolidation.Track(id: UUID(), position: SIMD2(xMm / 1000, zMm / 1000), longMm: long, rgb: rgb,
                                 sightings: sightings, frames: frames)
    }

    func testMergesAPieceCountedTwiceAndKeepsTheBetterSeenTrack() {
        let early = track(0, 0, sightings: 8, frames: Array(0..<8))
        let late = track(13, 2, sightings: 5, frames: Array(8..<13))
        let result = TrackConsolidation.plan(tracks: [late, early])
        XCTAssertEqual(result.merges.count, 1)
        XCTAssertEqual(result.merges[0].kept, early.id)
        XCTAssertEqual(result.merges[0].absorbed, late.id)
        XCTAssertEqual(result.absorbed, [late.id])
        XCTAssertEqual(result.keptFor[late.id], early.id)
        XCTAssertEqual(result.merges[0].distance, Float(173).squareRoot() / 1000, accuracy: 1e-6)
    }

    func testNeverMergesTwoTracksDetectedInTheSameFrame() {
        // Everything else says "one piece", but frame 7 had both.
        let a = track(0, 0, frames: Array(0..<8))
        let b = track(5, 0, frames: [7, 8, 9, 10])
        XCTAssertTrue(TrackConsolidation.plan(tracks: [a, b]).merges.isEmpty)
    }

    func testPooledFramesStopAChainOfMerges() {
        // a-b and b-c could each merge, but a and c were seen together: only the closer pair merges.
        let a = track(0, 0, frames: [0, 1, 2])
        let b = track(8, 0, frames: [3, 4])
        let c = track(16, 0, frames: [2, 5])
        let result = TrackConsolidation.plan(tracks: [a, b, c])
        XCTAssertEqual(result.merges.count, 1)
        let merged = Set([result.merges[0].kept, result.merges[0].absorbed])
        XCTAssertTrue(merged == [a.id, b.id] || merged == [b.id, c.id])
        XCTAssertFalse(merged == [a.id, c.id])
    }

    func testKeepsApartTracksThatDifferInPlaceSizeOrColour() {
        let a = track(0, 0, frames: [0, 1, 2])
        XCTAssertTrue(TrackConsolidation.plan(tracks: [a, track(25, 0, frames: [5, 6])]).merges.isEmpty, "more than a length apart")
        XCTAssertTrue(TrackConsolidation.plan(tracks: [a, track(8, 0, long: 40, frames: [5, 6])]).merges.isEmpty, "twice the size")
        XCTAssertTrue(TrackConsolidation.plan(tracks: [a, track(8, 0, rgb: SIMD3(30, 60, 200), frames: [5, 6])]).merges.isEmpty, "red and blue")
        XCTAssertTrue(TrackConsolidation.plan(tracks: [a, track(8, 0, rgb: SIMD3(254, 138, 24), frames: [5, 6])]).merges.isEmpty, "red and orange")
        // Small pieces still reach 1.5 cm.
        XCTAssertEqual(TrackConsolidation.plan(tracks: [track(0, 0, long: 8, frames: [0]), track(14, 0, long: 8, frames: [1])]).merges.count, 1)
    }

    func testShadingIsNotADifferentColour() {
        // An upright tan bar measured from its lit side and from its shaded side (from the replay of sweep s2).
        let lit = SIMD3<Float>(0xb7, 0x9f, 0x79), shaded = SIMD3<Float>(0x7a, 0x68, 0x4c)
        XCTAssertTrue(TrackConsolidation.sameColour(lit, shaded))
        XCTAssertFalse(TrackConsolidation.sameColour(SIMD3(0xc9, 0x1a, 0x09), SIMD3(0x72, 0x0e, 0x0f)), "red and dark red")
        XCTAssertFalse(TrackConsolidation.sameColour(SIMD3(0xf2, 0xcd, 0x37), SIMD3(0xe4, 0xcd, 0x9e)), "yellow and tan")
        XCTAssertTrue(TrackConsolidation.sameColour(SIMD3(0x2e, 0x30, 0x31), SIMD3(0x23, 0x26, 0x27)), "black, measured twice")
    }

    /// The whole path the app takes: a tracker, the observation log, the plan at Review.
    func testTrackerDoubleCountIsMergedButNeighboursAreNot() {
        let tracker = PieceTracker()
        var log = ObservationLog()
        func frame(_ observations: [PieceObservation], _ time: TimeInterval) {
            tracker.beginFrame()
            let matched = tracker.observe(frame: observations, time: time)
            log.record(frame: matched.compactMap { $0?.id })
            for id in tracker.endFrame(time: time) { log.forget(id) }
        }
        func seen(_ xMm: Float, _ zMm: Float, rgb: (UInt8, UInt8, UInt8) = (200, 40, 30)) -> PieceObservation {
            PieceObservation(position: SIMD3(xMm / 1000, 0, zMm / 1000), longMm: 16, shortMm: 8, r: rgb.0, g: rgb.1, b: rgb.2, quality: 1)
        }
        // A tall piece whose outline jumps 12 mm as the camera passes (past the tracker's 1 cm radius), next to two
        // flat neighbours of the same colour 12 mm apart that are always seen together.
        for i in 0..<6 { frame([seen(0, 0), seen(50, 0), seen(62, 0)], Double(i) * 0.2) }
        for i in 6..<12 { frame([seen(12, 0), seen(50, 0), seen(62, 0)], Double(i) * 0.2) }
        XCTAssertEqual(tracker.confirmed.count, 4, "counted twice by the tracker")
        let result = TrackConsolidation.plan(pieces: tracker.confirmed, log: log)
        XCTAssertEqual(result.merges.count, 1)
        let kept = tracker.piece(id: result.merges[0].kept)!, gone = tracker.piece(id: result.merges[0].absorbed)!
        XCTAssertEqual(Set([kept.position.x, gone.position.x].map { ($0 * 1000).rounded() }), [0, 12])
        XCTAssertEqual(tracker.confirmed.filter { !result.absorbed.contains($0.id) }.count, 3)
        XCTAssertTrue(log.seenTogether(tracker.confirmed[1].id, tracker.confirmed[2].id))
        XCTAssertEqual(log.frameCount, 12)

        // The kept piece takes the better thumbnail.
        gone.thumbnail = Data([1]); gone.thumbnailQuality = 9
        kept.thumbnail = Data([2]); kept.thumbnailQuality = 3
        TrackConsolidation.apply(result, to: tracker.confirmed)
        XCTAssertEqual(kept.thumbnail, Data([1]))
        XCTAssertEqual(kept.thumbnailQuality, 9)
    }

    func testSortedListHelpers() {
        XCTAssertTrue(TrackConsolidation.intersects([1, 4, 9], [2, 9]))
        XCTAssertFalse(TrackConsolidation.intersects([1, 4, 9], [2, 5, 10]))
        XCTAssertFalse(TrackConsolidation.intersects([], [1]))
        XCTAssertEqual(TrackConsolidation.union([1, 4, 9], [2, 4, 10]), [1, 2, 4, 9, 10])
    }
}
