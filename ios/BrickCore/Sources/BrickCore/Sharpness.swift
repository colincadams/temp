import Foundation

// How ScanEngine should use this (in `process(frame:...)`, after `downsample` and before detection):
//
//     private var sharpness = SharpnessGate()                     // engine state; `sharpness.reset()` in reset()
//
//     let score = Sharpness.frameScore(rgba: work.rgba, width: work.width, height: work.height)
//     guard sharpness.admit(score) else { publish(hint: "Hold the phone steady."); return }
//     ...
//     for blob in blobs {
//         let region = Sharpness.regionScore(rgba: work.rgba, width: work.width, height: work.height, blob: blob)
//         let quality = PieceTracker.viewQuality(of: blob, frameWidth: work.width, frameHeight: work.height)
//             * sharpness.viewFactor(region)
//         ...   // the observation's quality, as now; thumbnail and server crop choice then prefer sharp views
//     }
//
// Skip the frame before `tracker.beginFrame()` and before the coverage map, as for the other gates: a rejected frame
// is not a processed frame. Costs, measured by brick-replay (release build, one core of a Linux server): the whole-frame
// score about 0.2 ms at 640 x 480, a region score about 8 microseconds per piece (2.4 ms for a crowded frame showing
// 300 pieces whole). The factor goes into the observation's quality, so it is computed for every detection, before
// matching; if that is too slow on a crowded table, pass 1 for the pieces after the first hundred.

/// A cheap measure of how sharp a frame, or a piece in it, is.
///
/// The score is a Laplacian variance of the luminance, taken one direction at a time: the variance of the second
/// difference along x, along y and along both diagonals, and the smallest of the four. Blur removes fine detail, and
/// second differences measure exactly that detail, so the score falls steeply with blur. The plain (isotropic)
/// Laplacian would not do for motion blur: a smear along x leaves edges that run along x sharp, so its variance cannot
/// fall much below half however long the smear; the second difference along the motion falls towards zero.
///
/// Two details keep it cheap and keep sensor noise from looking like detail:
/// - the luminance is first averaged over 2 x 2 pixels, and the differences take neighbours two pixels away, so they
///   respond to detail about 4 pixels across (a stud's edge, a piece's outline), not to single-pixel noise;
/// - it is evaluated only on every `sampleStep`-th pixel of every `sampleStep`-th row (8 for a whole frame: 4,800
///   places in a 640 x 480 frame; on the rendered sweeps every 4th pixel gives the same ratios at twice the cost).
///
/// The number depends on what is in view (a bare table scores low however sharp it is), so it is only meaningful
/// against other frames of the same scan: see `SharpnessGate`.
public enum Sharpness {
    /// Luminance (0...255 scaled by 4: the sum over a 2 x 2 block) at the block whose top-left pixel is (x, y).
    @inline(__always)
    private static func block(_ p: UnsafeBufferPointer<UInt8>, _ w: Int, _ x: Int, _ y: Int) -> Int32 {
        let a = (y * w + x) * 4, b = a + w * 4
        // Rec. 601 weights in 1/256ths: 77 R + 150 G + 29 B.
        let s0 = 77 * Int32(p[a]) + 150 * Int32(p[a + 1]) + 29 * Int32(p[a + 2])
        let s1 = 77 * Int32(p[a + 4]) + 150 * Int32(p[a + 5]) + 29 * Int32(p[a + 6])
        let s2 = 77 * Int32(p[b]) + 150 * Int32(p[b + 1]) + 29 * Int32(p[b + 2])
        let s3 = 77 * Int32(p[b + 4]) + 150 * Int32(p[b + 5]) + 29 * Int32(p[b + 6])
        return (s0 + s1 + s2 + s3) >> 8
    }

    /// Detail and contrast over a rectangle, in units of luminance (0...255) squared.
    public struct Measure: Equatable {
        /// The smallest of the four directional second-difference variances (see the type's description).
        public var laplacianVariance: Float
        /// Variance of the (2 x 2 averaged) luminance itself: the region's contrast.
        public var lumaVariance: Float
        public var samples: Int

        /// Detail relative to contrast: how fine the structure is, whatever the piece's colour against the table.
        /// About 0 for a smooth gradient; larger the sharper the edges.
        public var normalised: Float { lumaVariance > 1e-3 ? laplacianVariance / lumaVariance : 0 }
    }

    /// - Parameters:
    ///   - rgba: `width * height * 4` bytes, rows top to bottom (the working-resolution frame).
    ///   - minX...maxY: the rectangle, inclusive, in pixels; clipped to the frame.
    public static func measure(rgba: [UInt8], width w: Int, height h: Int,
                               minX: Int = 0, minY: Int = 0, maxX: Int = .max, maxY: Int = .max,
                               sampleStep: Int = 4) -> Measure {
        guard w >= 6, h >= 6, rgba.count >= w * h * 4 else { return Measure(laplacianVariance: 0, lumaVariance: 0, samples: 0) }
        // The Laplacian at (x, y) reads blocks two pixels away, each 2 x 2: x - 2 ... x + 3.
        let x0 = max(2, minX), y0 = max(2, minY)
        let x1 = min(w - 4, maxX), y1 = min(h - 4, maxY)
        guard x0 <= x1, y0 <= y1 else { return Measure(laplacianVariance: 0, lumaVariance: 0, samples: 0) }
        // Small regions are sampled more densely so a piece of 10 x 10 pixels still gets a few dozen samples.
        let span = min(x1 - x0, y1 - y0) + 1
        let step = max(1, min(sampleStep, span / 6))
        var n: Int64 = 0
        // Second differences along x, y and the two diagonals: sums and sums of squares.
        var s0: Int64 = 0, s1: Int64 = 0, s2: Int64 = 0, s3: Int64 = 0
        var q0: Int64 = 0, q1: Int64 = 0, q2: Int64 = 0, q3: Int64 = 0
        var sumY: Int64 = 0, sumYY: Int64 = 0
        rgba.withUnsafeBufferPointer { p in
            var y = y0
            while y <= y1 {
                var x = x0
                while x <= x1 {
                    let c = block(p, w, x, y)
                    let dx = Int64(block(p, w, x - 2, y) + block(p, w, x + 2, y) - 2 * c)
                    let dy = Int64(block(p, w, x, y - 2) + block(p, w, x, y + 2) - 2 * c)
                    let dd = Int64(block(p, w, x - 2, y - 2) + block(p, w, x + 2, y + 2) - 2 * c)
                    let da = Int64(block(p, w, x + 2, y - 2) + block(p, w, x - 2, y + 2) - 2 * c)
                    s0 += dx; q0 += dx * dx
                    s1 += dy; q1 += dy * dy
                    s2 += dd; q2 += dd * dd
                    s3 += da; q3 += da * da
                    sumY += Int64(c); sumYY += Int64(c) * Int64(c)
                    n += 1
                    x += step
                }
                y += step
            }
        }
        guard n > 1 else { return Measure(laplacianVariance: 0, lumaVariance: 0, samples: Int(n)) }
        let count = Double(n)
        // Block sums are 4 x luminance; divide the variances by 16 to get luminance units.
        func variance(_ s: Int64, _ ss: Int64) -> Double {
            let mean = Double(s) / count
            return max(0, Double(ss) / count - mean * mean) / 16
        }
        let directional = [variance(s0, q0), variance(s1, q1), variance(s2, q2), variance(s3, q3)]
        let lumaVar = variance(sumY, sumYY)
        return Measure(laplacianVariance: Float(directional.min()!), lumaVariance: Float(lumaVar), samples: Int(n))
    }

    /// Sharpness of a whole frame: the directional Laplacian variance (see `measure`).
    public static func frameScore(rgba: [UInt8], width: Int, height: Int, sampleStep: Int = 8) -> Float {
        measure(rgba: rgba, width: width, height: height, sampleStep: sampleStep).laplacianVariance
    }

    /// About 10 x 10 samples whatever the piece's size (every pixel for a piece under 10 pixels across).
    static func regionSampleStep(_ blob: DetectedBlob, margin: Int) -> Int {
        max(1, (min(blob.maxX - blob.minX, blob.maxY - blob.minY) + 1 + 2 * margin) / 10)
    }

    /// Sharpness of one piece: `Measure.normalised` over its bounding box widened by `margin` pixels so the outline
    /// against the table is included. Comparable between pieces, unlike the raw Laplacian variance, because it is
    /// divided by the region's own contrast.
    public static func regionScore(rgba: [UInt8], width: Int, height: Int, blob: DetectedBlob, margin: Int = 3) -> Float {
        measure(rgba: rgba, width: width, height: height, minX: blob.minX - margin, minY: blob.minY - margin,
                maxX: blob.maxX + margin, maxY: blob.maxY + margin, sampleStep: regionSampleStep(blob, margin: margin)).normalised
    }
}

/// Decides which frames are too blurred to use, and how much a blurred view of a piece counts.
///
/// A frame is rejected when its score is below `rejectBelow` times the median score of the last `window` frames
/// scored (rejected ones included). The median of recent frames stands for "how sharp this scan's frames over this
/// part of the table usually are": consecutive frames overlap by about 90%, so they show nearly the same content.
/// Rejected frames are kept in the history on purpose: if every frame is blurred (dim light, long exposures), the
/// median falls with them and scanning carries on instead of stalling; the gate only removes frames that are much
/// worse than their neighbours, such as a jerk of the hand.
///
/// `viewFactor` turns a piece's region score into a factor between `minFactor` and 1 for `PieceTracker.viewQuality`:
/// its score over `fullQualityAbove` times the typical region score of recent frames, capped at 1. The typical score is
/// taken per frame (the median over the last `window` frames of each frame's median), so a crowded frame of 300 pieces
/// counts once, like any other. Most frames are sharp, so the typical score is a sharp view's.
///
/// A value type with no locking: use it from one queue.
public struct SharpnessGate {
    public struct Settings {
        /// Frames whose score is below this share of the recent median are rejected. Measured on a rendered sweep
        /// (ml/README.md): a smear of 2 working pixels leaves 0.34-0.61 of a frame's score, 3-5 pixels 0.12-0.44
        /// (typically 0.18), 6-10 pixels about 0.06. Sharp frames vary only down to about 0.65 of the median as the
        /// view moves over fuller or emptier parts of the table. So 0.35 passes every sharp frame and rejects smears of
        /// about 3 working pixels or more: at 32 cm over the table, 1.8 mm, enough to lengthen a 1 x 2 plate's
        /// outline by a tenth and to run neighbours 2 mm apart together.
        public var rejectBelow: Float = 0.35
        /// Frames in the history: 15 frames are 3 s of sweeping at 5 frames a second.
        public var window = 15
        /// Frames scored before any is rejected (and frames with pieces before `viewFactor` judges any). Consecutive
        /// frames overlap by about 90%, so even the one before is a fair reference; a frame would have to hold three
        /// times less detail than the one before it to be rejected wrongly.
        public var warmUp = 1
        /// A view keeps its full quality while its region score is at least this share of the typical one, so views
        /// that are merely a little less detailed (a plainer piece, a slightly smaller view) are not ranked by
        /// sharpness at all; below it the quality falls in proportion. A smear of 3 working pixels or more leaves a
        /// region about 0.2 of the typical score or less, so such views count 2.5 times less or worse.
        public var fullQualityAbove: Float = 0.5
        /// Smallest factor a view can get, so even a blurred view's size and centring still rank it.
        public var minFactor: Float = 0.05

        public init() {}
    }

    public let settings: Settings
    private var recent: [Float] = []
    /// Region scores of the frame in progress, and the median region score of each recent frame.
    private var frameRegions: [Float] = []
    private var regionMedians: [Float] = []
    private var regionReference: Float?
    /// Frames scored and frames rejected so far.
    public private(set) var scored = 0
    public private(set) var rejected = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public mutating func reset() {
        recent.removeAll()
        frameRegions.removeAll()
        regionMedians.removeAll()
        regionReference = nil
        scored = 0
        rejected = 0
    }

    /// The median of the recent frame scores, or nil during warm-up.
    public var typical: Float? {
        recent.count >= settings.warmUp ? TableMath.median(recent) : nil
    }

    /// Record a frame's `Sharpness.frameScore`; false if the frame is too blurred to use. Starts a new frame.
    public mutating func admit(_ score: Float) -> Bool {
        startFrame()
        let reference = typical
        recent.append(score)
        if recent.count > settings.window { recent.removeFirst() }
        scored += 1
        guard let reference, reference > 0 else { return true }
        if score < settings.rejectBelow * reference {
            rejected += 1
            return false
        }
        return true
    }

    /// Start a new frame for `viewFactor`. `admit` does this itself; call it only when using `viewFactor` without `admit`.
    public mutating func startFrame() {
        guard !frameRegions.isEmpty else { return }
        regionMedians.append(TableMath.median(frameRegions))
        if regionMedians.count > settings.window { regionMedians.removeFirst() }
        frameRegions.removeAll(keepingCapacity: true)
        regionReference = regionMedians.count >= settings.warmUp ? TableMath.median(regionMedians) : nil
    }

    /// Record a piece's `Sharpness.regionScore` in this frame and return the factor its view quality is multiplied by:
    /// its score over the typical region score of recent frames (the median over the last `window` frames of each
    /// frame's median; see `Settings.fullQualityAbove`), capped at 1. 1 until `warmUp` frames have had pieces.
    public mutating func viewFactor(_ regionScore: Float) -> Float {
        frameRegions.append(regionScore)
        guard let reference = regionReference, reference > 0 else { return 1 }
        return max(settings.minFactor, min(1, regionScore / (settings.fullQualityAbove * reference)))
    }
}
