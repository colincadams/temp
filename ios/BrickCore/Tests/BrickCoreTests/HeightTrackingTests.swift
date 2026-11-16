import XCTest
@testable import BrickCore

/// `PieceTracker` with pieces that stand up off the table.
final class HeightTrackingTests: XCTestCase {
    struct Piece {
        var base: SIMD3<Float>
        /// Height of its top, metres.
        var height: Float
        /// Long and short side seen from straight above, mm.
        var longMm: Float
        var shortMm: Float
    }

    /// What the tracker gets for `piece` from `camera`: the spot where the ray through the middle of its outline (about
    /// half-way up) meets the table, and an outline magnified by its height and lengthened by the side the camera sees.
    func observation(_ piece: Piece, camera: SIMD3<Float>, random: inout HeightTestRandom, noiseMm: Float = 0.3,
                     depthHeightMm: Float? = nil) -> PieceObservation {
        var spot = HeightScene.spot(base: piece.base, lift: piece.height / 2, camera: camera)
        spot.x += random.gaussian() * noiseMm / 1000
        spot.z += random.gaussian() * noiseMm / 1000
        let magnify = camera.y / (camera.y - piece.height)
        let lever = HeightGeometry.lever(position: piece.base, camera: camera)!
        let side = piece.height * (lever * lever).sum().squareRoot() * 1000   // mm of side seen
        return PieceObservation(position: spot, longMm: piece.longMm * magnify + side, shortMm: piece.shortMm * magnify,
                                r: 200, g: 40, b: 40, quality: 1, cameraPosition: camera, depthHeightMm: depthHeightMm)
    }

    /// Sweep the camera in two rows that pass either side of the pieces, feeding the tracker every piece in view.
    @discardableResult
    func run(_ tracker: PieceTracker, _ pieces: [Piece], wholeFrame: Bool, seed: UInt64 = 1, withCamera: Bool = true,
             depthNoiseMm: Float? = nil) -> [PieceObservation] {
        var random = HeightTestRandom(seed: seed)
        var all: [PieceObservation] = []
        for (frame, camera) in HeightScene.sweep(rowsZ: [-0.09, 0.09]).enumerated() {
            let time = TimeInterval(frame) * 0.2
            tracker.beginFrame()
            var observations: [PieceObservation] = []
            for piece in pieces where HeightScene.inView(piece.base, camera: camera) {
                let depth = depthNoiseMm.map { piece.height * 1000 + random.gaussian() * $0 }
                var o = observation(piece, camera: camera, random: &random, depthHeightMm: depth)
                if !withCamera { o.cameraPosition = nil }
                observations.append(o)
            }
            if wholeFrame {
                tracker.observe(frame: observations, time: time)
            } else {
                for o in observations { tracker.observe(o, time: time) }
            }
            tracker.endFrame(time: time)
            all += observations
        }
        return all
    }

    let bar = Piece(base: SIMD3(0.01, 0, 0.005), height: 0.048, longMm: 4.8, shortMm: 4.8)    // a Bar 6L stood on end
    let tallBrick = Piece(base: SIMD3(-0.02, 0, 0.0), height: 0.0304, longMm: 16, shortMm: 16)   // a 2 x 2 x 3 brick

    func testTallPieceIsCountedOnceWhenHeightAware() {
        for wholeFrame in [false, true] {
            var plain = PieceTracker.Settings()
            plain.heightAware = false
            let before = PieceTracker(settings: plain)
            let observations = run(before, [bar], wholeFrame: wholeFrame)
            let xs = observations.map { $0.position.x }, zs = observations.map { $0.position.z }
            XCTAssertGreaterThan(max(xs.max()! - xs.min()!, zs.max()! - zs.min()!), 0.02, "the bar's spot slides by over 2 cm")
            XCTAssertGreaterThan(before.confirmed.count, 1, "without allowing for height the bar is counted more than once")

            let after = PieceTracker()
            run(after, [bar], wholeFrame: wholeFrame)
            XCTAssertEqual(after.confirmed.count, 1, "whole frame: \(wholeFrame)")
            let piece = after.confirmed[0]
            XCTAssertEqual(piece.heightSource, .views)
            XCTAssertEqual(piece.heightMm, 48, accuracy: 5)
            XCTAssertEqual(TableMath.distance(piece.position, bar.base), 0, accuracy: 0.0015)
        }
    }

    func testFittedHeightPlacesATallBrickAndCorrectsItsLength() {
        let tracker = PieceTracker()
        run(tracker, [tallBrick], wholeFrame: true)
        XCTAssertEqual(tracker.confirmed.count, 1)
        let piece = tracker.confirmed[0]
        XCTAssertEqual(piece.heightMm, 30.4, accuracy: 3)
        XCTAssertEqual(TableMath.distance(piece.position, tallBrick.base), 0, accuracy: 0.001)
        // On the table plane it looks much longer. Measured at its top it is not magnified (the short side, which in
        // this model shows none of the side wall, comes back to 16 mm), and the long side is taken from the views
        // nearest straight above, which show the least wall.
        XCTAssertGreaterThan(piece.tableLongMm, 16 * 1.5)
        XCTAssertEqual(piece.shortMm, 16, accuracy: 16 * 0.03)
        XCTAssertLessThan(piece.longMm, piece.tableLongMm - 3)
        XCTAssertGreaterThan(piece.longMm, 16)
    }

    func testDepthHeightDecidesAndCorrects() {
        let tracker = PieceTracker()
        run(tracker, [tallBrick], wholeFrame: true, depthNoiseMm: 5)
        let piece = tracker.confirmed[0]
        XCTAssertEqual(piece.heightSource, .depth)
        XCTAssertEqual(piece.heightMm, 30.4, accuracy: 3)
        XCTAssertEqual(TableMath.distance(piece.position, tallBrick.base), 0, accuracy: 0.001)
        XCTAssertEqual(piece.shortMm, 16, accuracy: 16 * 0.03)
    }

    func testFlatPiecesStayFlatAndInPlace() {
        let plate = Piece(base: SIMD3(0.0, 0, 0.0), height: 0.0032, longMm: 16, shortMm: 8)
        for depthNoise: Float? in [nil, 4] {
            let tracker = PieceTracker()
            run(tracker, [plate], wholeFrame: true, depthNoiseMm: depthNoise)
            XCTAssertEqual(tracker.confirmed.count, 1)
            let piece = tracker.confirmed[0]
            XCTAssertEqual(piece.heightMm, 0, "a plate is flat (depth noise \(String(describing: depthNoise)))")
            XCTAssertEqual(piece.longMm, piece.tableLongMm)
            XCTAssertEqual(TableMath.distance(piece.position, plate.base), 0, accuracy: 0.0008)
        }
    }

    func testTwoCloseFlatPiecesAreNotMerged() {
        // Two 1 x 1 plates 11 mm apart, centre to centre (a 1 mm gap would be 9 mm): the match distance is 10 mm.
        let a = Piece(base: SIMD3(0.0, 0, 0.0), height: 0.0032, longMm: 8, shortMm: 8)
        let b = Piece(base: SIMD3(0.011, 0, 0.0), height: 0.0032, longMm: 8, shortMm: 8)
        for wholeFrame in [false, true] {
            for seed in 1...3 as ClosedRange<UInt64> {
                let tracker = PieceTracker()
                run(tracker, [a, b], wholeFrame: wholeFrame, seed: seed)
                XCTAssertEqual(tracker.confirmed.count, 2, "whole frame \(wholeFrame), seed \(seed)")
                XCTAssertTrue(tracker.confirmed.allSatisfy { $0.heightMm == 0 })
            }
        }
    }

    func testAFlatPieceBesideATallOneKeepsItsOwnTrack() {
        let brick = Piece(base: SIMD3(0.0, 0, 0.0), height: 0.0304, longMm: 16, shortMm: 16)
        let plate = Piece(base: SIMD3(0.019, 0, 0.0), height: 0.0032, longMm: 8, shortMm: 8)
        let tracker = PieceTracker()
        run(tracker, [brick, plate], wholeFrame: true)
        XCTAssertEqual(tracker.confirmed.count, 2)
        let heights = tracker.confirmed.map { $0.heightMm }.sorted()
        XCTAssertEqual(heights[0], 0)
        XCTAssertEqual(heights[1], 30.4, accuracy: 4)
    }

    func testWithoutCameraPositionsTheTrackerWorksAsBefore() {
        let tracker = PieceTracker()
        run(tracker, [tallBrick], wholeFrame: true, withCamera: false)
        XCTAssertFalse(tracker.confirmed.isEmpty)
        XCTAssertTrue(tracker.pieces.allSatisfy { $0.heightMm == 0 && $0.heightSource == .none })
    }
}
