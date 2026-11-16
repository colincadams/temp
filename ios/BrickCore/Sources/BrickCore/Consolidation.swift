import Foundation

// How ScanEngine should use this:
//
//     private var observationLog = ObservationLog()               // engine state; `observationLog.reset()` in reset()
//
//     // in process(frame:...), right after matching:
//     let matchedPieces = tracker.observe(frame: ..., time: time)
//     observationLog.record(frame: matchedPieces.compactMap { $0?.id })
//     for id in tracker.endFrame(time: time) { observationLog.forget(id); ... }
//
//     // when the user taps Review (on the engine's queue), before building the review list:
//     let candidates = tracker.confirmed.filter { !visibility.isDoubtful($0.id) }
//     let result = TrackConsolidation.plan(pieces: candidates, log: observationLog)
//     TrackConsolidation.apply(result, to: candidates)            // the kept piece takes the sharper thumbnail
//     // then leave out every piece in `result.absorbed` from the count and the review list,
//     // and say "Merged \(result.merges.count) pieces counted twice" if any.
//
// The tracker itself is not changed: an absorbed piece stays in `PieceTracker.pieces` (there is no removal API), so
// keep `result.absorbed` and filter with it, or run the plan again, whenever the list is rebuilt.

/// Which tracked pieces were detected in which processed frames: the evidence that keeps two real pieces apart.
///
/// Frames are numbered by the log itself, one number per `record` call. Each piece's frames are kept as a sorted list,
/// a few hundred numbers at most for a long scan.
public struct ObservationLog {
    public private(set) var frames: [UUID: [Int]] = [:]
    /// Frames recorded so far.
    public private(set) var frameCount = 0

    public init() {}

    public mutating func reset() {
        frames.removeAll()
        frameCount = 0
    }

    /// Record one processed frame: the ids of the pieces a detection matched in it (new pieces included).
    public mutating func record(frame matched: [UUID]) {
        let n = frameCount
        frameCount += 1
        for id in Set(matched) { frames[id, default: []].append(n) }
    }

    /// Forget a piece the tracker dropped.
    public mutating func forget(_ id: UUID) { frames[id] = nil }

    /// Whether both pieces were detected in one frame: then they are certainly two pieces.
    public func seenTogether(_ a: UUID, _ b: UUID) -> Bool {
        TrackConsolidation.intersects(frames[a] ?? [], frames[b] ?? [])
    }
}

/// The clean-up at the end of a scan: merge pairs of tracks that are probably one piece counted twice.
///
/// A piece is counted twice when its detections drift further than the tracker's match radius (half its length, at
/// least 1 cm), which happens to tall pieces whose outline shifts with the viewing angle. The two tracks then lie close
/// together, look alike, and have never been detected in the same frame, because they are the same object.
///
/// Two tracks are merged when all of these hold:
/// - **never detected in the same frame** (a hard rule: two detections in one frame are two objects, so a merge can never
///   join two pieces that were seen side by side);
/// - **close**: centres within `distancePerLength` times the longer of the two lengths, at least `minDistance`. The
///   tracker already joins detections within half a length, so this reaches the drift it missed;
/// - **same colour**: measured colours within `maxColourDistance` (RGB, 0-255 per channel);
/// - **same size**: longer measured length at most `maxLengthRatio` times the shorter.
///
/// Pairs are taken closest first. Once two tracks are merged their frames are pooled, so a third track can join only if
/// it was never detected together with either of them. The track with more sightings is kept.
public enum TrackConsolidation {
    public struct Settings {
        /// Reach as a multiple of the longer measured length: 1.0 means the two centres are less than a piece
        /// length apart, so the two outlines would overlap if both were real and lay flat.
        public var distancePerLength: Float = 1.0
        /// Smallest reach in metres (1.5 cm: about two studs), for very small pieces.
        public var minDistance: Float = 0.015
        /// Colours count as the same when they are within this distance (RGB, 0-255 per channel), which covers the
        /// view-to-view noise of a dark piece, whose hue is too noisy to compare...
        public var maxColourDistance: Float = 60
        /// ...or when their hue is the same and only the brightness differs: one face of a tall piece lit and another
        /// in shade (the replays have an upright tan bar measured as b79f79 from one side and 7a684c from the other).
        /// Hue is compared as chromaticity, each channel over the sum of the three. 0.05 keeps apart red and dark red
        /// (0.08), orange and dark orange (0.08), yellow and tan (0.19), but, by design, not colours that differ only in
        /// brightness by less than `maxBrightnessRatio`: white and light grey, light and dark grey, tan and dark tan.
        /// Shading alone could make one look like the other, so only "never seen together" can keep those apart.
        public var maxChromaticityDistance: Float = 0.05
        /// Brightest over darkest of the two, for the hue test: a face in shade against one in light.
        public var maxBrightnessRatio: Float = 2
        /// One piece measured from different angles: an upright piece's apparent length changes with the view.
        public var maxLengthRatio: Float = 1.6

        public init() {}
    }

    /// One track, as the plan sees it.
    public struct Track {
        public var id: UUID
        public var position: SIMD2<Float>
        public var longMm: Float
        public var rgb: SIMD3<Float>
        public var sightings: Int
        /// Sorted numbers of the frames it was detected in.
        public var frames: [Int]

        public init(id: UUID, position: SIMD2<Float>, longMm: Float, rgb: SIMD3<Float>, sightings: Int, frames: [Int]) {
            self.id = id; self.position = position; self.longMm = longMm; self.rgb = rgb
            self.sightings = sightings; self.frames = frames
        }
    }

    public struct Merge: Equatable {
        public var kept: UUID
        public var absorbed: UUID
        /// Distance between the two tracks' centres, metres.
        public var distance: Float
    }

    public struct Result: Equatable {
        public var merges: [Merge] = []
        /// Every track merged into another; leave these out of the count.
        public var absorbed: Set<UUID> = []
        /// For each absorbed track, the track it now belongs to.
        public var keptFor: [UUID: UUID] = [:]
    }

    /// Plan the merges for the app's pieces.
    public static func plan(pieces: [TrackedPiece], log: ObservationLog, settings: Settings = Settings()) -> Result {
        plan(tracks: pieces.map { piece in
            Track(id: piece.id, position: SIMD2(piece.position.x, piece.position.z), longMm: piece.longMm,
                  rgb: SIMD3(TableMath.median(piece.rSamples), TableMath.median(piece.gSamples), TableMath.median(piece.bSamples)),
                  sightings: piece.sightings, frames: log.frames[piece.id] ?? [])
        }, settings: settings)
    }

    /// Plan the merges for any tracks.
    public static func plan(tracks: [Track], settings: Settings = Settings()) -> Result {
        var candidates: [(a: Int, b: Int, d: Float)] = []
        for a in tracks.indices {
            for b in tracks.indices where b > a {
                let ta = tracks[a], tb = tracks[b]
                let delta = ta.position - tb.position
                let d = (delta * delta).sum().squareRoot()
                let reach = max(settings.minDistance, settings.distancePerLength * max(ta.longMm, tb.longMm) / 1000)
                guard d <= reach else { continue }
                guard sameColour(ta.rgb, tb.rgb, settings: settings) else { continue }
                let shorter = min(ta.longMm, tb.longMm), longer = max(ta.longMm, tb.longMm)
                guard shorter > 0, longer <= settings.maxLengthRatio * shorter else { continue }
                guard !intersects(ta.frames, tb.frames) else { continue }
                candidates.append((a, b, d))
            }
        }
        candidates.sort { ($0.d, $0.a, $0.b) < ($1.d, $1.a, $1.b) }

        // Groups of merged tracks: a representative per track, and each group's pooled frames.
        var group = Array(tracks.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while group[i] != i { i = group[i] }
            return i
        }
        var pooled = tracks.map { $0.frames }
        for candidate in candidates {
            let ra = root(candidate.a), rb = root(candidate.b)
            guard ra != rb, !intersects(pooled[ra], pooled[rb]) else { continue }
            // The group whose best track has more sightings absorbs the other.
            let (keep, drop) = tracks[ra].sightings >= tracks[rb].sightings ? (ra, rb) : (rb, ra)
            group[drop] = keep
            pooled[keep] = union(pooled[keep], pooled[drop])
            pooled[drop] = []
        }

        var result = Result()
        for i in tracks.indices where root(i) != i {
            let kept = root(i)
            let delta = tracks[i].position - tracks[kept].position
            result.merges.append(Merge(kept: tracks[kept].id, absorbed: tracks[i].id, distance: (delta * delta).sum().squareRoot()))
            result.absorbed.insert(tracks[i].id)
            result.keptFor[tracks[i].id] = tracks[kept].id
        }
        return result
    }

    /// Give each kept piece the better thumbnail of its group. Recognition views are not moved: the kept piece is the
    /// one with more sightings, and so normally with more views too.
    public static func apply(_ result: Result, to pieces: [TrackedPiece]) {
        let byID = Dictionary(pieces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for merge in result.merges {
            guard let kept = byID[merge.kept], let absorbed = byID[merge.absorbed] else { continue }
            if let thumbnail = absorbed.thumbnail, absorbed.thumbnailQuality > kept.thumbnailQuality {
                kept.thumbnail = thumbnail
                kept.thumbnailQuality = absorbed.thumbnailQuality
            }
        }
    }

    /// Whether two measured colours (RGB, 0-255) could be one piece: close outright, or the same hue at a brightness
    /// that differs by shading only.
    public static func sameColour(_ a: SIMD3<Float>, _ b: SIMD3<Float>, settings: Settings = Settings()) -> Bool {
        let d = a - b
        if (d * d).sum().squareRoot() <= settings.maxColourDistance { return true }
        let sa = a.sum(), sb = b.sum()
        guard sa > 0, sb > 0, max(sa, sb) <= settings.maxBrightnessRatio * min(sa, sb) else { return false }
        let c = a / sa - b / sb
        return (c * c).sum().squareRoot() <= settings.maxChromaticityDistance
    }

    /// Whether two sorted lists share a value.
    static func intersects(_ a: [Int], _ b: [Int]) -> Bool {
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { return true }
            if a[i] < b[j] { i += 1 } else { j += 1 }
        }
        return false
    }

    static func union(_ a: [Int], _ b: [Int]) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j >= b.count || (i < a.count && a[i] < b[j]) { out.append(a[i]); i += 1 }
            else if i >= a.count || b[j] < a[i] { out.append(b[j]); j += 1 }
            else { out.append(a[i]); i += 1; j += 1 }
        }
        return out
    }
}
