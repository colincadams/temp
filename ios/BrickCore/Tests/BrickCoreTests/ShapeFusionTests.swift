import XCTest
@testable import BrickCore

final class ShapeFusionTests: XCTestCase {
    let plate1x2 = ShapeClass(partNum: "3023", name: "Plate 1 x 2", members: ["3023"], sizeMm: [16, 8, 4.9])
    let plate1x4 = ShapeClass(partNum: "3710", name: "Plate 1 x 4", members: ["3710"], sizeMm: [32, 8, 4.9])
    let brick2x4 = ShapeClass(partNum: "3001", name: "Brick 2 x 4", members: ["3001"], sizeMm: [32, 16, 11.3])

    func logs(_ probabilities: [Float]) -> [Float] { probabilities.map { log($0) } }

    func testLogSoftmax() {
        let out = ShapeFusion.logSoftmax([1, 2, 3])
        XCTAssertEqual(out.map { exp($0) }.reduce(0, +), 1, accuracy: 1e-5)
        XCTAssertEqual(out[2] - out[0], 2, accuracy: 1e-5)
        XCTAssertEqual(ShapeFusion.logSoftmax([]), [])
        // Large values must not overflow.
        let big = ShapeFusion.logSoftmax([1000, 1000])
        XCTAssertEqual(big[0], log(0.5), accuracy: 1e-3)
    }

    func testEqualImageScoresAreDecidedByMeasuredLength() {
        let classes = [plate1x2, plate1x4]
        let even = logs([0.5, 0.5])
        let short = ShapeFusion.fuse(logSum: even, views: 1, classes: classes, longMm: 16.5, shortMm: 8)
        XCTAssertEqual(short.first?.shape.partNum, "3023")
        XCTAssertGreaterThan(short.first?.probability ?? 0, 0.9)
        let long = ShapeFusion.fuse(logSum: even, views: 1, classes: classes, longMm: 31, shortMm: 8.5)
        XCTAssertEqual(long.first?.shape.partNum, "3710")
        XCTAssertGreaterThan(long.first?.probability ?? 0, 0.9)
        XCTAssertEqual(long.map { $0.probability }.reduce(0, +), 1, accuracy: 1e-5)
    }

    func testSizePrior() {
        let prior = ShapeFusion.sizeLogPrior(classes: [plate1x2, plate1x4, brick2x4], longMm: 16, shortMm: 8)
        XCTAssertEqual(prior[0], 0, accuracy: 1e-6)             // exact fit
        XCTAssertLessThan(prior[1], -3)
        XCTAssertEqual(prior[2], -0.25 * (3.3 * 3.3 / 9), accuracy: 1e-4)   // on its end, 16 x 11.3: right length, 3.3 mm too narrow
        // A piece on its side is matched by another pair of its extents.
        let side = ShapeFusion.sizeLogPrior(classes: [brick2x4], longMm: 32, shortMm: 11.3)
        XCTAssertEqual(side[0], 0, accuracy: 1e-6)
        // Size never rules a shape out completely.
        XCTAssertEqual(ShapeFusion.sizeLogPrior(classes: [plate1x2], longMm: 300, shortMm: 200), [-6])
        // No measurement, or a shape with no dimensions: no opinion.
        XCTAssertEqual(ShapeFusion.sizeLogPrior(classes: [plate1x2], longMm: 0, shortMm: 0), [0])
        let unsized = ShapeClass(partNum: "x", name: "x", members: [], sizeMm: [])
        XCTAssertEqual(ShapeFusion.sizeLogPrior(classes: [unsized], longMm: 16, shortMm: 8), [0])
    }

    func testViewsAreAveragedNotSummed() {
        // Shapes without dimensions, so only the views count.
        let classes = ["a", "b"].map { ShapeClass(partNum: $0, name: $0, members: [$0], sizeMm: []) }
        let view = logs([0.6, 0.4])
        let one = ShapeFusion.fuse(logSum: view, views: 1, classes: classes, longMm: 20, shortMm: 10)
        let five = ShapeFusion.fuse(logSum: view.map { $0 * 5 }, views: 5, classes: classes, longMm: 20, shortMm: 10)
        XCTAssertEqual(one.first?.probability ?? 0, 0.6, accuracy: 1e-5)
        XCTAssertEqual(five.first?.probability ?? 0, 0.6, accuracy: 1e-5, "identical views add no certainty")

        // Two disagreeing views: the geometric mean of the two, renormalised.
        let a = logs([0.9, 0.1]), b = logs([0.2, 0.8])
        let both = ShapeFusion.fuse(logSum: zip(a, b).map { $0 + $1 }, views: 2, classes: classes, longMm: 20, shortMm: 10)
        let pa = (0.9 * 0.2).squareRoot(), pb = (0.1 * 0.8).squareRoot()
        XCTAssertEqual(both.first?.shape.partNum, "a")
        XCTAssertEqual(both.first?.probability ?? 0, pa / (pa + pb), accuracy: 1e-5)
    }

    func testTopKOrdering() {
        let classes = (0..<6).map { ShapeClass(partNum: "p\($0)", name: "", members: [], sizeMm: []) }
        let view = logs([0.05, 0.3, 0.1, 0.4, 0.05, 0.1])
        let top = ShapeFusion.fuse(logSum: view, views: 1, classes: classes, longMm: 20, shortMm: 10)
        XCTAssertEqual(top.map { $0.shape.partNum }, ["p3", "p1", "p2", "p5"], "best first; ties in class order")
        XCTAssertEqual(top.map { $0.index }, [3, 1, 2, 5])
        XCTAssertEqual(top.map { $0.probability }, top.map { $0.probability }.sorted(by: >))
        XCTAssertEqual(top[0].probability, 0.4, accuracy: 1e-5)
        XCTAssertEqual(ShapeFusion.fuse(logSum: view, views: 1, classes: classes, longMm: 20, shortMm: 10, limit: 2).count, 2)
        XCTAssertEqual(ShapeFusion.fuse(logSum: view, views: 1, classes: classes, longMm: 20, shortMm: 10, limit: 10).count, 6)
    }

    func testNothingToFuse() {
        let classes = [plate1x2, plate1x4]
        XCTAssertTrue(ShapeFusion.fuse(logSum: [0, 0], views: 0, classes: classes, longMm: 16, shortMm: 8).isEmpty)
        XCTAssertTrue(ShapeFusion.fuse(logSum: [0], views: 1, classes: classes, longMm: 16, shortMm: 8).isEmpty)
        XCTAssertTrue(ShapeFusion.fuse(logSum: [], views: 1, classes: [], longMm: 16, shortMm: 8).isEmpty)
    }

    func testShapeClassDecodesTheExportedFile() throws {
        let json = #"{"partNum":"3023","name":"Plate 1 x 2","members":["3023","3023pr1"],"sizeMm":[16,8,4.9]}"#
        let shape = try JSONDecoder().decode(ShapeClass.self, from: Data(json.utf8))
        XCTAssertEqual(shape.members, ["3023", "3023pr1"])
        XCTAssertEqual(shape.sizeMm, [16, 8, 4.9])
    }
}

final class SecondOpinionTests: XCTestCase {
    func testAsksOnlyWhenUnsureAfterEnoughViews() {
        XCTAssertTrue(SecondOpinion.shouldRequest(topProbability: 0.3, views: 3, alreadyRequested: false))
        XCTAssertTrue(SecondOpinion.shouldRequest(topProbability: 0.49, views: 8, alreadyRequested: false))
        XCTAssertFalse(SecondOpinion.shouldRequest(topProbability: 0.3, views: 2, alreadyRequested: false), "too few views")
        XCTAssertFalse(SecondOpinion.shouldRequest(topProbability: 0.5, views: 3, alreadyRequested: false), "at the threshold is sure enough")
        XCTAssertFalse(SecondOpinion.shouldRequest(topProbability: 0.9, views: 8, alreadyRequested: false))
        XCTAssertFalse(SecondOpinion.shouldRequest(topProbability: 0.1, views: 8, alreadyRequested: true), "at most once per piece")
        XCTAssertTrue(SecondOpinion.shouldRequest(topProbability: nil, views: 3, alreadyRequested: false), "no on-device answer at all")
        XCTAssertTrue(SecondOpinion.shouldRequest(topProbability: 0.6, views: 1, alreadyRequested: false, threshold: 0.7, minViews: 1))
    }

    func testServerWinsOnlyWhenConfidentAndBetter() {
        XCTAssertEqual(SecondOpinion.choose(deviceTop: 0.4, serverTop: 0.8), .server)
        XCTAssertEqual(SecondOpinion.choose(deviceTop: 0.4, serverTop: 0.5), .server, "0.5 is enough")
        XCTAssertEqual(SecondOpinion.choose(deviceTop: 0.4, serverTop: 0.45), .device, "better but not confident")
        XCTAssertEqual(SecondOpinion.choose(deviceTop: 0.2, serverTop: 0.49), .device)
        XCTAssertEqual(SecondOpinion.choose(deviceTop: 0.7, serverTop: 0.6), .device, "confident but not better")
        XCTAssertEqual(SecondOpinion.choose(deviceTop: 0.6, serverTop: 0.6), .device, "a tie stays on the phone")
        XCTAssertEqual(SecondOpinion.choose(deviceTop: 0.4, serverTop: nil), .device, "server not asked, or found nothing")
        XCTAssertEqual(SecondOpinion.choose(deviceTop: nil, serverTop: nil), .device)
        XCTAssertEqual(SecondOpinion.choose(deviceTop: nil, serverTop: 0.2), .server, "nothing to show from the phone")
        XCTAssertEqual(SecondOpinion.choose(deviceTop: 0.4, serverTop: 0.6, threshold: 0.7), .device)
    }
}
