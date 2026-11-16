import Foundation

/// A 4 x 4 matrix stored by columns, laid out like ARKit's `simd_float4x4`.
public struct Matrix4: Equatable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        columns = (c0, c1, c2, c3)
    }

    public static let identity = Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))

    public static func * (m: Matrix4, v: SIMD4<Float>) -> SIMD4<Float> {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z + m.columns.3 * v.w
    }

    public static func == (a: Matrix4, b: Matrix4) -> Bool {
        a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
    }
}

/// The few vector helpers the package needs, so it does not depend on `simd`.
public enum TableMath {
    public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d * d).sum().squareRoot()
    }

    /// `a` moved the fraction `t` of the way to `b`.
    public static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    /// Middle value (the upper of the two middle values for an even count); 0 for an empty list.
    public static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}

/// Maps a pixel of the full-resolution camera image to the point on the table it shows.
public struct TableProjector {
    /// Camera intrinsics in pixels of the full-resolution image.
    public let fx: Float, fy: Float, cx: Float, cy: Float
    /// Camera-to-world transform. Camera space: +x right, +y up, looking along -z.
    public let camera: Matrix4
    /// Height of the table surface in world space (world +y is up).
    public let tableY: Float

    public init(fx: Float, fy: Float, cx: Float, cy: Float, camera: Matrix4, tableY: Float) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.camera = camera
        self.tableY = tableY
    }

    /// The table point seen at pixel (`px`, `py`), or nil if that pixel does not look down at the table
    /// or the table is too far along the ray to measure (4 or more times the ray's unit depth).
    public func point(_ px: Float, _ py: Float) -> SIMD3<Float>? {
        point(px, py, height: 0)
    }

    /// The point seen at pixel (`px`, `py`) on the horizontal plane `height` metres above the table, or nil under the
    /// same conditions as `point(_:_:)`.
    public func point(_ px: Float, _ py: Float, height: Float) -> SIMD3<Float>? {
        // Image y grows downwards.
        let dir = camera * SIMD4<Float>((px - cx) / fx, -(py - cy) / fy, -1, 0)
        guard dir.y < -1e-4 else { return nil }
        let origin = camera.columns.3
        let planeY = tableY + height
        let t = (planeY - origin.y) / dir.y
        guard t > 0, t < 4 else { return nil }
        return SIMD3<Float>(origin.x + dir.x * t, planeY, origin.z + dir.z * t)
    }

    /// The world point seen at pixel (`px`, `py`) at `depth` metres along the camera's viewing axis (the distance
    /// ARKit's scene depth reports).
    public func unproject(_ px: Float, _ py: Float, depth: Float) -> SIMD3<Float> {
        let p = camera * SIMD4<Float>((px - cx) / fx * depth, -(py - cy) / fy * depth, -depth, 1)
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    /// Where a world point appears in the full-resolution image, and its distance along the viewing axis (metres);
    /// nil if it is behind the camera. The inverse of `unproject`.
    public func project(_ world: SIMD3<Float>) -> (pixel: SIMD2<Float>, depth: Float)? {
        let c = camera.columns
        let p = world - SIMD3<Float>(c.3.x, c.3.y, c.3.z)
        let right = SIMD3<Float>(c.0.x, c.0.y, c.0.z), up = SIMD3<Float>(c.1.x, c.1.y, c.1.z), back = SIMD3<Float>(c.2.x, c.2.y, c.2.z)
        let depth = -(p * back).sum()
        guard depth > 1e-4 else { return nil }
        return (SIMD2(cx + fx * (p * right).sum() / depth, cy - fy * (p * up).sum() / depth), depth)
    }

    /// Where the camera is in world space.
    public var cameraPosition: SIMD3<Float> {
        SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
    }

    /// Where a spot of the downsampled work image lies on the table, and the scale there.
    ///
    /// - Parameters:
    ///   - workX: position in work-image pixels.
    ///   - step: full-resolution pixels per work pixel.
    ///   - probe: work pixels stepped right and down to measure the scale.
    /// - Returns: the table point and millimetres per work pixel, or nil if any of the three rays misses the table.
    public func locate(workX: Float, workY: Float, step: Float, probe: Float = 12) -> (position: SIMD3<Float>, mmPerPixel: Float)? {
        let fullX = workX * step, fullY = workY * step
        guard let world = point(fullX, fullY),
              let right = point(fullX + probe * step, fullY),
              let down = point(fullX, fullY + probe * step) else { return nil }
        let mmPerPixel = (TableMath.distance(world, right) + TableMath.distance(world, down)) / 2 / probe * 1000
        return (world, mmPerPixel)
    }
}
