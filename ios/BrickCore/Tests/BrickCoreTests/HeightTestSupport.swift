import Foundation
@testable import BrickCore

/// Repeatable random numbers for the height tests (a small linear congruential generator and Box-Muller).
struct HeightTestRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func uniform() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u1 = max(uniform(), 1e-7), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Float.pi * u2)
    }
}

/// A phone 32 cm above a table at y = 0, looking straight down, with the replay's intrinsics (640 x 480 image).
enum HeightScene {
    static let fx: Float = 522, fy: Float = 522, cx: Float = 320, cy: Float = 240
    static let width: Float = 640, height: Float = 480
    static let cameraHeight: Float = 0.32

    static func projector(cameraAt position: SIMD3<Float>) -> TableProjector {
        TableProjector(fx: fx, fy: fy, cx: cx, cy: cy, camera: lookingDown(from: position), tableY: 0)
    }

    /// Pixel and depth (along the viewing axis) at which the camera sees world point `p`.
    static func project(_ p: SIMD3<Float>, from projector: TableProjector) -> (x: Float, y: Float, depth: Float) {
        let c = projector.camera.columns
        let d = p - projector.cameraPosition
        let right = SIMD3<Float>(c.0.x, c.0.y, c.0.z), up = SIMD3<Float>(c.1.x, c.1.y, c.1.z), back = SIMD3<Float>(c.2.x, c.2.y, c.2.z)
        let depth = -(d * back).sum()
        return (projector.cx + projector.fx * (d * right).sum() / depth, projector.cy - projector.fy * (d * up).sum() / depth, depth)
    }

    /// A zig-zag sweep: rows of camera positions 30 mm apart, as `ml/render_sweep.py` makes.
    static func sweep(rowsZ: [Float], fromX: Float = -0.15, toX: Float = 0.15, step: Float = 0.03) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for (i, z) in rowsZ.enumerated() {
            let count = Int(((toX - fromX) / step).rounded())
            for k in 0...count {
                let t = Float(k) * step
                result.append(SIMD3(i % 2 == 0 ? fromX + t : toX - t, cameraHeight, z))
            }
        }
        return result
    }

    /// Where the tracker would see a piece standing on `base` whose outline's middle is `lift` above the table,
    /// from a camera at `camera`: the ray through that point meets the table here.
    static func spot(base: SIMD3<Float>, lift: Float, camera: SIMD3<Float>) -> SIMD3<Float> {
        let axis = SIMD3<Float>(base.x, base.y + lift, base.z)
        let t = camera.y / (camera.y - axis.y)
        return SIMD3<Float>(camera.x + (axis.x - camera.x) * t, 0, camera.z + (axis.z - camera.z) * t)
    }

    /// Whether the camera shows a point of the table well inside its frame.
    static func inView(_ p: SIMD3<Float>, camera: SIMD3<Float>) -> Bool {
        let q = project(p, from: projector(cameraAt: camera))
        return q.x > 40 && q.x < width - 40 && q.y > 40 && q.y < height - 40
    }
}
