import XCTest
@testable import BrickCore

final class SharpnessTests: XCTestCase {
    static let w = 640, h = 480

    /// A table with pieces on it: light background, darker rectangles of several sizes, a little texture.
    static func scene(contrast: Float = 1) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var v: Float = 210 + Float((x * 7 + y * 13) % 5)
                let cellX = x / 40, cellY = y / 40
                if (cellX + cellY) % 3 == 0, x % 40 >= 8, x % 40 < 8 + 16 + (cellY % 3) * 6, y % 40 >= 10, y % 40 < 26 {
                    v = 210 - 150 * contrast
                }
                let p = (y * w + x) * 4
                rgba[p] = UInt8(max(0, min(255, v))); rgba[p + 1] = UInt8(max(0, min(255, v * 0.9))); rgba[p + 2] = UInt8(max(0, min(255, v * 0.8)))
            }
        }
        return rgba
    }

    /// A horizontal smear of `length` pixels: what the camera records while moving sideways during the exposure.
    static func smear(_ rgba: [UInt8], length: Int) -> [UInt8] {
        guard length > 1 else { return rgba }
        var out = rgba
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var sum = 0
                    for k in 0..<length { sum += Int(rgba[(y * w + min(w - 1, max(0, x + k - length / 2))) * 4 + c]) }
                    out[(y * w + x) * 4 + c] = UInt8(sum / length)
                }
            }
        }
        return out
    }

    func testScoreFallsSteeplyWithMotionBlur() {
        let sharp = Self.scene()
        let s0 = Sharpness.frameScore(rgba: sharp, width: Self.w, height: Self.h)
        XCTAssertGreaterThan(s0, 0)
        var previous = s0
        var ratios: [Int: Float] = [:]
        for length in [2, 4, 8] {
            let s = Sharpness.frameScore(rgba: Self.smear(sharp, length: length), width: Self.w, height: Self.h)
            XCTAssertLessThan(s, previous, "more blur, lower score")
            previous = s
            ratios[length] = s / s0
        }
        // The default gate (0.35 of the recent median) passes a 2-pixel smear and rejects an 8-pixel one.
        XCTAssertGreaterThan(ratios[2]!, 0.35)
        XCTAssertLessThan(ratios[8]!, 0.35)
    }

    func testFlatFrameScoresZeroAndBadInputIsSafe() {
        let flat = [UInt8](repeating: 128, count: Self.w * Self.h * 4)
        XCTAssertEqual(Sharpness.frameScore(rgba: flat, width: Self.w, height: Self.h), 0)
        XCTAssertEqual(Sharpness.frameScore(rgba: [], width: Self.w, height: Self.h), 0)
        XCTAssertEqual(Sharpness.measure(rgba: flat, width: 4, height: 4).samples, 0)
    }

    func testRegionScoreIgnoresContrastButNotBlur() {
        // The piece in cell (0, 0): x 8..<24, y 10..<26.
        let blob = DetectedBlob(minX: 8, minY: 10, maxX: 23, maxY: 25, area: 256, cx: 16, cy: 18, major: 16, minor: 16, r: 60, g: 54, b: 48)
        let strong = Sharpness.regionScore(rgba: Self.scene(contrast: 1), width: Self.w, height: Self.h, blob: blob)
        let faint = Sharpness.regionScore(rgba: Self.scene(contrast: 0.3), width: Self.w, height: Self.h, blob: blob)
        let blurred = Sharpness.regionScore(rgba: Self.smear(Self.scene(contrast: 1), length: 6), width: Self.w, height: Self.h, blob: blob)
        XCTAssertGreaterThan(strong, 0)
        XCTAssertEqual(faint / strong, 1, accuracy: 0.35, "a pale piece is as sharp as a dark one")
        XCTAssertLessThan(blurred, 0.5 * strong)
    }

    func testGateRejectsAFrameMuchWorseThanItsNeighbours() {
        var gate = SharpnessGate()
        XCTAssertTrue(gate.admit(5), "the first frame has nothing to be compared with")
        for score in [100, 110, 95, 105, 90] as [Float] { XCTAssertTrue(gate.admit(score)) }
        XCTAssertFalse(gate.admit(20), "a fifth of the typical sharpness: a jerk of the hand")
        XCTAssertTrue(gate.admit(40), "0.4 of typical passes")
        XCTAssertTrue(gate.admit(70), "a frame over an emptier part of the table passes")
        XCTAssertEqual(gate.rejected, 1)
        XCTAssertEqual(gate.scored, 9)
    }

    func testGateFollowsAScanThatIsBlurredThroughout() {
        var gate = SharpnessGate()
        for _ in 0..<10 { XCTAssertTrue(gate.admit(100)) }
        // The light drops and every frame from now on is blurred: some are rejected at first, then scanning carries on.
        var accepted: [Bool] = []
        for _ in 0..<15 { accepted.append(gate.admit(20)) }
        XCTAssertFalse(accepted[0])
        XCTAssertTrue(accepted.suffix(5).allSatisfy { $0 }, "the median follows the blurred frames")
        gate.reset()
        XCTAssertNil(gate.typical)
    }

    func testViewFactorPrefersTheSharpView() {
        var gate = SharpnessGate()
        XCTAssertEqual(gate.viewFactor(3), 1, "no reference yet")
        // Three sharp frames of many pieces, then a crowded blurred frame: one frame, one vote.
        for frame in 0..<4 {
            XCTAssertTrue(gate.admit(100))
            for _ in 0..<(frame == 3 ? 300 : 20) { _ = gate.viewFactor(frame == 3 ? 0.4 : 2) }
        }
        gate.startFrame()
        XCTAssertEqual(gate.viewFactor(2.5), 1, "sharper than typical: full quality")
        XCTAssertEqual(gate.viewFactor(1), 1, "half the typical detail still counts in full")
        XCTAssertEqual(gate.viewFactor(0.4), 0.4, accuracy: 1e-5, "a blurred view counts for less")
        XCTAssertEqual(gate.viewFactor(0), gate.settings.minFactor)
    }

    func testFrameScoreIsCheap() {
        let frame = Self.scene()
        let start = Date()
        for _ in 0..<20 { _ = Sharpness.frameScore(rgba: frame, width: Self.w, height: Self.h) }
        let ms = Date().timeIntervalSince(start) * 1000 / 20
        // Well under a millisecond in a release build (brick-replay prints it); debug builds are many times slower.
        XCTAssertLessThan(ms, 150)
    }
}
