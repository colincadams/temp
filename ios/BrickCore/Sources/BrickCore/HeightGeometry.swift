import Foundation

/// Where a piece that stands up off the table really is, and how big it really is.
///
/// The tracker places each detection where the ray through the middle of its outline meets the table. For a flat piece
/// that is right. For a tall one it is not: the outline takes in the piece's top and the side facing the camera, and
/// its middle sits roughly half-way up the piece, on the piece's vertical axis. Call that point's height above the table
/// the piece's **lift** (`e`, about half its height). The ray through it meets the table beyond the piece, pushed away
/// from the camera, and exactly (similar triangles, camera `C` at height `H` above the table, base `B`):
///
///     p = B + e * (p - C) / H        in table coordinates (x, z)
///
/// so the observed spot `p` slides as the camera moves. `(p - C) / H` is the detection's **lever**: known from the
/// detection and the camera alone. Given the lift, the base is `p - e * lever`; given a few views from different
/// places, the lift and the base follow from a straight-line fit of position against lever (`fitLift`).
///
/// The outline of a piece whose top is `h` above the table is also magnified: everything at height `h` is `(H - h) / H`
/// as far from the camera as the table along any ray, so the millimetres-per-pixel there is smaller by that factor.
public enum HeightGeometry {
    /// The detection's lever, `(p - C) / H` in table coordinates (x, z): how far its table spot moves per metre of lift.
    /// Nil if the camera is less than 5 cm above the spot (no sensible view of the table).
    public static func lever(position: SIMD3<Float>, camera: SIMD3<Float>) -> SIMD2<Float>? {
        let height = camera.y - position.y
        guard height > 0.05 else { return nil }
        return SIMD2<Float>(position.x - camera.x, position.z - camera.z) / height
    }

    /// The table point under a detection whose outline's middle is `lift` metres above the table: `p - lift * lever`.
    public static func base(position: SIMD3<Float>, lever: SIMD2<Float>, lift: Float) -> SIMD3<Float> {
        SIMD3<Float>(position.x - lift * lever.x, position.y, position.z - lift * lever.y)
    }

    /// What a length measured on the table plane really is for an outline `height` metres above the table, seen by a
    /// camera `cameraHeight` metres above the table: multiply by this, `(H - h) / H` (1 when either is unknown).
    public static func scale(cameraHeight: Float, height: Float) -> Float {
        guard cameraHeight > 0.05, height > 0 else { return 1 }
        return max(0.2, (cameraHeight - height) / cameraHeight)
    }

    public struct LiftFit: Equatable {
        /// Metres above the table of the outline's middle, clamped to 0...`maxLift`.
        public var lift: Float
        /// The table point under the piece (x, z).
        public var base: SIMD2<Float>
        /// Sum of squared lever differences from their mean: how much the views differ, and so how well the lift is pinned down.
        public var spread: Float
        public var count: Int
    }

    /// Fit the lift and base from views of one piece: least squares of `p_i = B + e * lever_i` over all views, with a
    /// small ridge penalty `ridge * e²` that keeps the lift at 0 when the views barely differ, and the lift clamped to
    /// 0...`maxLift` (a piece cannot be below the table).
    ///
    /// With centred values, `e = Σ (a_i - ā)·(p_i - p̄) / (Σ |a_i - ā|² + ridge)` and `B = p̄ - e ā`.
    /// - Returns: nil for no views.
    public static func fitLift(positions: [SIMD2<Float>], levers: [SIMD2<Float>], ridge: Float = 0.005,
                               maxLift: Float = 0.04) -> LiftFit? {
        let n = min(positions.count, levers.count)
        guard n > 0 else { return nil }
        var meanP = SIMD2<Float>(0, 0), meanA = SIMD2<Float>(0, 0)
        for i in 0..<n { meanP += positions[i]; meanA += levers[i] }
        meanP /= Float(n); meanA /= Float(n)
        var sxy: Float = 0, sxx: Float = 0
        for i in 0..<n {
            let da = levers[i] - meanA, dp = positions[i] - meanP
            sxy += (da * dp).sum()
            sxx += (da * da).sum()
        }
        let lift = min(maxLift, max(0, sxy / (sxx + ridge)))
        return LiftFit(lift: lift, base: meanP - lift * meanA, spread: sxx, count: n)
    }

    /// How far a tall-looking piece's detected spot can be from its base, from its outline alone: the side the camera
    /// sees adds to the outline's length what it moves its middle, twice over. So a detection whose long side is
    /// `longMm` while the piece's shortest-looking view was `shortestMm` is at most `(longMm - shortestMm) / 2` mm
    /// from where it would be seen from straight above. Returned in metres.
    public static func slideBound(longMm: Float, shortestMm: Float) -> Float {
        max(0, longMm - shortestMm) / 2 / 1000
    }
}
