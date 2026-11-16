import Foundation

// How ScanEngine uses this (in `process(frame:...)`, right after matching and before `tracker.endFrame`):
//
//     private var visibility = VisibilityLedger()                 // engine state; `visibility.reset()` in reset()
//     // Without the trained detector (`instanceDetector == nil`) the colour threshold misses far more pieces:
//     //     var s = VisibilityLedger.Settings(); s.detectorMissRate = 0.6; visibility = VisibilityLedger(settings: s)
//
//     let matchedPieces = tracker.observe(frame: ..., time: time)
//     let resolution = frame.camera.imageResolution
//     // Only the current pass's pieces (`PieceTracker.currentPieces`) are in this world; pieces under the user's hand
//     // (`HandMasking.occluded`) were not looked at.
//     visibility.record(view: projector, imageWidth: Float(resolution.width), imageHeight: Float(resolution.height),
//                       inset: coverageInset, pieces: tracker.currentPieces, matched: Set(matchedPieces.compactMap { $0?.id }),
//                       occluded: occluded)
//     for id in tracker.endFrame(time: time) { visibility.forget(id); ... }
//
// and wherever the confirmed pieces are counted or shown (`publish`, the review list, the "looks complete" guess):
//
//     tracker.confirmed.filter { !visibility.isDoubtful($0.id) }
//
// A doubtful piece is not deleted: it comes back by itself if the camera sees it again.

/// Negative evidence: a piece the camera keeps looking at without finding is probably not there.
///
/// For each tracked piece the ledger keeps hits (processed frames in which a detection matched it), misses (processed
/// frames whose view showed its spot well inside the frame, yet no detection matched it), and a capped log-odds score
/// that the piece is real rather than a phantom (a shadow, a hand, a reflection that lasted a few frames).
///
/// The update is a log-likelihood ratio (a naive-Bayes filter, as in occupancy-grid mapping). With a detector that
/// misses a real piece in full view at rate m, and a phantom that turns up again at the same spot at rate p, a hit
/// multiplies the odds of "real" by (1 - m) / p and a miss by m / (1 - p). With the defaults m = p = 0.2 (the trained
/// detector finds 99% of pieces standing apart and 95% of touching ones) both factors are 4: +log 4 per hit and
/// -log 4 per miss, so the rule reads simply: a piece is doubtful once its misses outnumber its hits by 2 (odds of
/// 1 to 16 against it being real, from even odds). A detector that misses more often makes each miss count for less,
/// which is why `detectorMissRate` must match the detector in use.
///
/// The score is capped at `maxEvidence` and `minEvidence`, so the past cannot outweigh the present for ever. At the
/// default rates:
/// - a piece seen 50 times is still flagged after 7 misses in a row (about 1.4 s over that spot at 5 frames a second:
///   a long stretch for a real piece to go undetected while in plain view);
/// - a doubtful piece that is seen again is restored after 2 hits.
///
/// A value type with no locking: use it from one queue.
public struct VisibilityLedger {
    public struct Settings {
        /// Share of views in which the detector fails to report a real piece that lies whole and well inside the view.
        /// 0.2 suits the trained detector; the colour threshold, which merges touching pieces, misses far more often
        /// on a crowded table (about 0.6 in the replays: brick-replay reports the rate it saw).
        public var detectorMissRate: Float = 0.2
        /// Share of later views in which a phantom (shadow, hand, reflection) is reported again at the same spot.
        public var phantomRepeatRate: Float = 0.2
        /// Evidence (natural log of the odds real : phantom) added by a hit and taken away by a miss.
        public var hitWeight: Float { log((1 - detectorMissRate) / phantomRepeatRate) }
        public var missWeight: Float { log((1 - phantomRepeatRate) / detectorMissRate) }
        /// Bounds on the evidence: 5 and 3 views' worth at the default rates (log 4 each).
        public var maxEvidence: Float = 5 * log(4)
        public var minEvidence: Float = -3 * log(4)
        /// A piece is doubtful when its evidence is at most minus this (odds of 1 to 16 against it being real), and it
        /// has been missed at least `minMisses` times.
        public var doubtfulAt: Float = log(16)
        public var minMisses = 3
        /// Extra distance (metres) the piece's outline must keep from the edge of the view's inset footprint, on top
        /// of half its measured length: the detectors drop pieces cut by the frame edge, and a tall piece seen near
        /// the edge leans outwards. 5 mm.
        public var edgeMargin: Float = 0.005
        /// Views that see the spot further than this along the camera axis (metres) do not count, as in `CoverageMap`.
        public var maxDepth: Float = 1.0

        public init() {}
    }

    public struct Entry: Equatable {
        public var hits = 0
        public var misses = 0
        public var evidence: Float = 0
    }

    public let settings: Settings
    public private(set) var entries: [UUID: Entry] = [:]

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public mutating func reset() { entries.removeAll() }

    /// Forget a piece the tracker dropped.
    public mutating func forget(_ id: UUID) { entries[id] = nil }

    public func entry(_ id: UUID) -> Entry { entries[id] ?? Entry() }

    /// Whether the camera has looked at this piece's spot without finding it clearly more often than it found it.
    public func isDoubtful(_ id: UUID) -> Bool {
        guard let e = entries[id] else { return false }
        // A hair of slack so that exactly 2 more misses than hits counts despite rounding.
        return e.evidence <= -settings.doubtfulAt + 1e-4 && e.misses >= settings.minMisses
    }

    /// Record one processed frame.
    ///
    /// - Parameters:
    ///   - projector: the view, with intrinsics in pixels of an `imageWidth` by `imageHeight` image.
    ///   - inset: share of each image edge left out, as for `CoverageMap.add(view:...)`.
    ///   - pieces: every tracked piece (`PieceTracker.pieces`).
    ///   - matched: ids of the pieces a detection matched in this frame (new pieces included).
    ///   - occluded: pieces this frame cannot have seen although their spot is in view (a hand over them, `PersonMask`):
    ///     no miss for them.
    public mutating func record(view projector: TableProjector, imageWidth: Float, imageHeight: Float, inset: Float = 0.05,
                                pieces: [TrackedPiece], matched: Set<UUID>, occluded: Set<UUID> = []) {
        let footprint = CoverageMap.footprint(of: projector, imageWidth: imageWidth, imageHeight: imageHeight,
                                              inset: inset, maxDepth: settings.maxDepth)
        for piece in pieces {
            if matched.contains(piece.id) {
                hit(piece.id)
            } else if !occluded.contains(piece.id) {
                let margin = piece.longMm / 2000 + settings.edgeMargin
                if VisibilityLedger.contains(footprint, SIMD2(piece.position.x, piece.position.z), margin: margin) {
                    miss(piece.id)
                }
            }
        }
    }

    /// Add a hit or a miss directly.
    public mutating func hit(_ id: UUID) {
        var e = entries[id] ?? Entry()
        e.hits += 1
        e.evidence = min(settings.maxEvidence, e.evidence + settings.hitWeight)
        entries[id] = e
    }

    public mutating func miss(_ id: UUID) {
        var e = entries[id] ?? Entry()
        e.misses += 1
        e.evidence = max(settings.minEvidence, e.evidence - settings.missWeight)
        entries[id] = e
    }

    /// Whether a point lies inside a convex polygon (corners in either order) and at least `margin` from every edge.
    public static func contains(_ polygon: [SIMD2<Float>], _ point: SIMD2<Float>, margin: Float = 0) -> Bool {
        guard polygon.count >= 3 else { return false }
        // Orientation from the signed area.
        var area: Float = 0
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            area += a.x * b.y - b.x * a.y
        }
        guard abs(area) > 1e-12 else { return false }
        let sign: Float = area > 0 ? 1 : -1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let edge = b - a
            let length = (edge * edge).sum().squareRoot()
            guard length > 1e-9 else { continue }
            // Distance of the point to the left of the edge (inside for a counter-clockwise polygon).
            let side = sign * (edge.x * (point.y - a.y) - edge.y * (point.x - a.x)) / length
            if side < margin { return false }
        }
        return true
    }
}
