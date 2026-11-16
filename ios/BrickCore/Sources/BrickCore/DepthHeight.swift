import Foundation

/// A depth map as a LiDAR iPhone's ARKit gives it (`ARFrame.sceneDepth` / `smoothedSceneDepth`), copied out of its
/// pixel buffers: 256 x 192 on current phones, the same orientation and field of view as the camera image.
public struct DepthMap {
    public let width: Int
    public let height: Int
    /// Metres along the camera's viewing axis, rows top to bottom.
    public let depth: [Float]
    /// ARConfidenceLevel per pixel (0 low, 1 medium, 2 high), or nil if the map came without one (taken as all high).
    public let confidence: [UInt8]?

    /// Nil if the arrays do not hold `width * height` values.
    public init?(width: Int, height: Int, depth: [Float], confidence: [UInt8]?) {
        guard width > 0, height > 0, depth.count == width * height,
              confidence.map({ $0.count == width * height }) ?? true else { return nil }
        self.width = width; self.height = height
        self.depth = depth; self.confidence = confidence
    }
}

/// A piece's height above the table from LiDAR depth.
///
/// The depth map is coarse (one depth pixel is about 1.4 mm of table at 30 cm) and noisy (about a centimetre at 30 cm),
/// while studs are 1.7 mm and plates 3.2 mm tall. So only high-confidence pixels are used, only those under the middle
/// of the piece's outline (a disc of `coreFraction` of its short side, which stays clear of the edges where depth
/// mixes piece and table), and the height is their median. Too few pixels (a thin bar, a piece far away) gives no
/// answer, and the caller falls back to working without depth. Single frames stay noisy; `PieceTracker` takes the
/// median over a piece's frames and treats anything under `PieceTracker.Settings.flatBelowMm` as flat.
public enum DepthHeight {
    public struct Settings {
        /// Lowest ARConfidenceLevel used (2 = high only).
        public var minConfidence: UInt8 = 2
        /// Fewest usable depth pixels for an answer.
        public var minSamples = 5
        /// Radius of the disc read, as a share of the blob's short side.
        public var coreFraction: Float = 0.35

        public init() {}
    }

    /// One depth pixel: where it is in the full-resolution camera image, and its depth in metres.
    public struct Sample: Equatable {
        public var x: Float
        public var y: Float
        public var depth: Float

        public init(x: Float, y: Float, depth: Float) {
            self.x = x; self.y = y; self.depth = depth
        }
    }

    /// The usable depth pixels under the middle of a blob.
    ///
    /// Depth pixel (u, v) covers the same share of the image as image pixel ((u + 0.5) * imageWidth / width - 0.5, ...).
    /// - Parameters:
    ///   - step: full-resolution pixels per work pixel (the blob is in work pixels).
    ///   - imageWidth, imageHeight: the full-resolution camera image the intrinsics belong to.
    public static func samples(in map: DepthMap, blob: DetectedBlob, step: Float, imageWidth: Float, imageHeight: Float,
                               settings: Settings = Settings()) -> [Sample] {
        let sx = imageWidth / Float(map.width), sy = imageHeight / Float(map.height)
        let centreX = blob.cx * step, centreY = blob.cy * step
        let radius = settings.coreFraction * blob.minor * step
        guard radius > 0, sx > 0, sy > 0 else { return [] }
        let u0 = max(0, Int(((centreX - radius + 0.5) / sx - 0.5).rounded(.down)))
        let u1 = min(map.width - 1, Int(((centreX + radius + 0.5) / sx - 0.5).rounded(.up)))
        let v0 = max(0, Int(((centreY - radius + 0.5) / sy - 0.5).rounded(.down)))
        let v1 = min(map.height - 1, Int(((centreY + radius + 0.5) / sy - 0.5).rounded(.up)))
        guard u0 <= u1, v0 <= v1 else { return [] }
        var result: [Sample] = []
        for v in v0...v1 {
            let y = (Float(v) + 0.5) * sy - 0.5
            for u in u0...u1 {
                let x = (Float(u) + 0.5) * sx - 0.5
                let dx = x - centreX, dy = y - centreY
                guard dx * dx + dy * dy <= radius * radius else { continue }
                let i = v * map.width + u
                if let confidence = map.confidence, confidence[i] < settings.minConfidence { continue }
                let d = map.depth[i]
                guard d.isFinite, d > 0.02 else { continue }
                result.append(Sample(x: x, y: y, depth: d))
            }
        }
        return result
    }

    /// Height above the table of each sample's surface point, millimetres.
    public static func heightsMm(_ samples: [Sample], projector: TableProjector) -> [Float] {
        samples.map { (projector.unproject($0.x, $0.y, depth: $0.depth).y - projector.tableY) * 1000 }
    }

    /// Median height above the table of the samples' surface points (mm), or nil with fewer than `minSamples`.
    public static func heightMm(_ samples: [Sample], projector: TableProjector, settings: Settings = Settings()) -> Float? {
        guard samples.count >= settings.minSamples else { return nil }
        return TableMath.median(heightsMm(samples, projector: projector))
    }

    /// A blob's height above the table from a depth map (mm), or nil when too few depth pixels are usable.
    public static func heightMm(map: DepthMap, blob: DetectedBlob, step: Float, imageWidth: Float, imageHeight: Float,
                                projector: TableProjector, settings: Settings = Settings()) -> Float? {
        heightMm(samples(in: map, blob: blob, step: step, imageWidth: imageWidth, imageHeight: imageHeight, settings: settings),
                 projector: projector, settings: settings)
    }

    /// The table point under a piece's top: the outline's middle pixel un-projected at the median depth of the samples
    /// and dropped straight down onto the table. Nil with too few samples.
    ///
    /// `PieceTracker` places by the equivalent `HeightGeometry.base` with the lift its settings choose instead, from
    /// the piece's height over all its frames, which is steadier than one frame's depth.
    public static func topCentreBase(_ samples: [Sample], pixelX: Float, pixelY: Float, projector: TableProjector,
                                     settings: Settings = Settings()) -> SIMD3<Float>? {
        guard samples.count >= settings.minSamples else { return nil }
        let depth = TableMath.median(samples.map { $0.depth })
        let top = projector.unproject(pixelX, pixelY, depth: depth)
        return SIMD3<Float>(top.x, projector.tableY, top.z)
    }
}
