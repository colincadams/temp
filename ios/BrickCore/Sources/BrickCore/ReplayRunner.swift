import Foundation

/// Which detector finds the pieces in each replayed frame.
public enum ReplayDetector: String, CaseIterable, Codable {
    /// `PieceDetector`, the colour threshold the app uses without a trained model.
    case colour
    /// Perfect detection from the per-frame piece-number maps: separates tracking errors from detection errors.
    case truth
    /// Precomputed network output per frame (`NNNN.maps`, `ml/sweep_maps.py`), grouped by `InstanceGrouping`
    /// exactly as the app's `InstanceDetector` does.
    case maps
}

/// Pieces read straight from a piece-number map: what a perfect detector would report.
public enum ReplayTruthDetector {
    /// - Parameters:
    ///   - ids: `width * height` piece numbers, rows top to bottom: 0 = table, `Piece.id + 1` = that piece.
    ///   - rgba: the frame, for each piece's median colour.
    /// - Returns: each fully visible piece's id and blob. Pieces cut by the frame edge are dropped, as the app does.
    public static func blobs(ids: [UInt16], rgba: [UInt8], width w: Int, height h: Int) -> [(id: Int, blob: DetectedBlob)] {
        guard w > 0, h > 0, ids.count >= w * h, rgba.count >= w * h * 4 else { return [] }
        struct Stats {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, area = 0
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            var r: [UInt8] = [], g: [UInt8] = [], b: [UInt8] = []
        }
        var stats: [Int: Stats] = [:]
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                let n = Int(ids[p])
                if n == 0 { continue }
                var s = stats[n] ?? Stats()
                s.area += 1
                s.minX = min(s.minX, x); s.maxX = max(s.maxX, x); s.minY = min(s.minY, y); s.maxY = max(s.maxY, y)
                let fx = Double(x), fy = Double(y)
                s.sx += fx; s.sy += fy; s.sxx += fx * fx; s.syy += fy * fy; s.sxy += fx * fy
                s.r.append(rgba[p * 4]); s.g.append(rgba[p * 4 + 1]); s.b.append(rgba[p * 4 + 2])
                stats[n] = s
            }
        }
        var result: [(id: Int, blob: DetectedBlob)] = []
        for (n, s) in stats.sorted(by: { $0.key < $1.key }) {
            if s.minX <= 0 || s.minY <= 0 || s.maxX >= w - 1 || s.maxY >= h - 1 { continue }
            let count = Double(s.area)
            let mx = s.sx / count, my = s.sy / count
            let vxx = max(0, s.sxx / count - mx * mx), vyy = max(0, s.syy / count - my * my)
            let vxy = s.sxy / count - mx * my
            let half = (vxx + vyy) / 2
            let root = max(0, half * half - (vxx * vyy - vxy * vxy)).squareRoot()
            // Same measure as PieceDetector: a filled rectangle of side L has variance L²/12 along that side.
            let major = Float((12 * (half + root)).squareRoot())
            let minor = Float((12 * max(0, half - root)).squareRoot())
            let mid = s.area / 2
            result.append((n - 1, DetectedBlob(minX: s.minX, minY: s.minY, maxX: s.maxX, maxY: s.maxY, area: s.area,
                                               cx: Float(mx), cy: Float(my), major: max(major, 1), minor: max(minor, 1),
                                               r: s.r.sorted()[mid], g: s.g.sorted()[mid], b: s.b.sorted()[mid])))
        }
        return result
    }

    /// Ids of the pieces shown whole (not cut by the frame edge) in a piece-number map.
    public static func wholePieces(ids: [UInt16], width w: Int, height h: Int) -> Set<Int> {
        var present = Set<Int>(), cut = Set<Int>()
        for y in 0..<h {
            for x in 0..<w {
                let n = Int(ids[y * w + x])
                if n == 0 { continue }
                present.insert(n - 1)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { cut.insert(n - 1) }
            }
        }
        return present.subtracting(cut)
    }
}

/// Plays a sweep through the scan pipeline the way `ScanEngine` drives it on the phone.
public enum ReplayRunner {
    /// The app's gating, from `ScanEngine`'s tuning constants.
    public struct Settings {
        public var frameInterval: TimeInterval = 0.2
        public var maxSpeed: Float = 0.30
        public var minDownwardTilt: Float = 0.80
        /// The app gets about 60 frames a second, so "at least 0.2 s since the last processed frame" costs it at most
        /// one sixtieth of a second. A sweep has exactly one frame every 0.2 s, and rounding (0.6 - 0.4 < 0.2 in
        /// floating point) would make the same test skip whole frames, so the replay allows this much slack.
        public var intervalSlack: TimeInterval = 0.001
        public var tracker = PieceTracker.Settings()
        /// Match each frame's detections all at once (`PieceTracker.observe(frame:time:)`) instead of one at a time
        /// as ScanEngine currently does, to measure the difference.
        public var matchWholeFrame = false
        /// The app's `InstanceDetector`: network input size, output stride and grouping thresholds.
        public var mapsInputWidth = 640, mapsInputHeight = 480, mapsStride = 2
        public var pieceThreshold: Float = 0.5, peakThreshold: Float = 0.3, mapsMinArea = 6
        /// Read each frame's LiDAR depth map (`NNNN.depth`, `NNNN.conf`; `ml/render_sweep.py --depth`) and measure
        /// each piece's height from it (`DepthHeight`), as the app does on a phone with LiDAR.
        public var useDepth = false
        public var depth = DepthHeight.Settings()

        // Techniques measured with the replay before they are wired into the app (each off by default).

        /// Skip frames much less sharp than the recent ones (`SharpnessGate.admit`).
        public var sharpnessGate = false
        /// Fold each piece's region sharpness into its view quality (`SharpnessGate.viewFactor`).
        public var sharpnessViews = false
        public var sharpness = SharpnessGate.Settings()
        /// Set aside pieces the camera keeps looking at without finding (`VisibilityLedger`).
        public var negativeEvidence = false
        public var visibility = VisibilityLedger.Settings()
        /// The share of each image edge the app leaves out of coverage (`ScanEngine.coverageInset`).
        public var coverageInset: Float = 0.05
        /// Merge tracks that are probably one piece when the scan ends (`TrackConsolidation`).
        public var consolidate = false
        public var consolidation = TrackConsolidation.Settings()
        /// Inject this many phantom detections: each a blob at a random free spot of the table, reported in the first
        /// `phantomFrames` processed frames that show its spot well inside the view, and never again.
        public var phantoms = 0
        public var phantomFrames = 3
        public var phantomSeed: UInt64 = 1
        /// Motion blur of each frame in working pixels, from sweep.json's `blurPx` (render_sweep.py --motion-blur);
        /// read by `run(folder:)` when nil. Only reported, never used by the pipeline.
        public var frameBlurPx: [Float]?

        public init() {}
    }

    public struct FrameResult: Codable, Equatable {
        public var file: String
        public var time: Double
        /// Nil if the frame was processed; otherwise why it was skipped.
        public var skipped: String?
        public var detections: Int
        /// Detections that became observations (projected onto the table and of plausible size).
        public var observations: Int
        /// Ids of the true pieces shown whole in this frame (processed frames only).
        public var wholePieces: [Int]
        /// `Sharpness.frameScore`, when the sharpness gate is on.
        public var sharpness: Float?
        /// Motion blur in working pixels, if the sweep records it.
        public var blurPx: Float?
        /// Phantom detections injected into this frame.
        public var phantoms = 0
    }

    public struct TrackedResult: Codable, Equatable {
        public var x: Float
        public var z: Float
        public var longMm: Float
        public var shortMm: Float
        public var rgb: String
        public var sightings: Int
        public var confirmed: Bool
        /// The tracker's estimate of the piece's height (mm, 0 = flat or unknown) and where it came from.
        public var heightMm: Float?
        public var heightSource: HeightSource?
        /// Set aside by negative evidence (`VisibilityLedger.isDoubtful`): not counted.
        public var doubtful = false
        /// Merged into another track at the end (`TrackConsolidation`): not counted.
        public var absorbed = false
        /// Visibility bookkeeping, when negative evidence is on.
        public var hits: Int?
        public var misses: Int?
        /// Motion blur (working pixels) of the frame that gave this piece's best view, if the sweep records blur.
        public var bestViewBlurPx: Float?

        public init(x: Float, z: Float, longMm: Float, shortMm: Float, rgb: String, sightings: Int, confirmed: Bool,
                    heightMm: Float? = nil, heightSource: HeightSource? = nil, doubtful: Bool = false, absorbed: Bool = false) {
            self.x = x; self.z = z; self.longMm = longMm; self.shortMm = shortMm; self.rgb = rgb
            self.sightings = sightings; self.confirmed = confirmed
            self.heightMm = heightMm; self.heightSource = heightSource
            self.doubtful = doubtful; self.absorbed = absorbed
        }

        /// Counted by the scan: confirmed, and neither set aside nor merged into another.
        public var counted: Bool { confirmed && !doubtful && !absorbed }
    }

    public struct Run {
        public var frames: [FrameResult]
        /// Every piece the tracker holds at the end, confirmed or not, oldest first.
        public var tracked: [TrackedResult]
        /// For each true piece id: processed frames that showed it whole.
        public var wholeFrames: [Int: Int]
        /// "piece maps" when the per-frame piece-number maps decide what was in view, else "geometry".
        public var visibilityMethod: String
        /// How detections were matched to known pieces: "one at a time" (as the app does) or "whole frame".
        public var matching: String
        /// The techniques switched on, in words (empty: none).
        public var techniques: [String] = []
        /// Average milliseconds per processed frame spent on sharpness: the frame score, and all region scores.
        public var sharpnessFrameMs: Double?
        public var sharpnessRegionsMs: Double?
        /// Phantom detections asked for and actually placed (a crowded table may leave no free spot).
        public var phantomsPlaced = 0
        /// Merges made by the end-of-scan consolidation.
        public var consolidationMerges = 0
    }

    public static let skippedTooSoon = "less than the frame interval after the last processed frame"
    public static let skippedTilted = "phone not facing down"
    public static let skippedFast = "moving too fast"
    public static let skippedNoPose = "no camera pose"
    public static let skippedBlurred = "blurred (sharpness gate)"

    /// Replay a sweep folder.
    public static func run(folder: ReplayFolder, detector: ReplayDetector, settings: Settings = Settings()) throws -> Run {
        let useIDs = folder.hasPieceMaps
        if detector == .truth && !useIDs {
            throw ReplayError("the truth detector needs piece-number maps; render the sweep with --ids")
        }
        let depthFiles = settings.useDepth ? try DepthReplayFiles(folder: folder) : nil
        var settings = settings
        if settings.frameBlurPx == nil { settings.frameBlurPx = blurLengths(folder: folder) }
        return try run(sweep: folder.sweep, detector: detector, settings: settings, load: { index in
            try folder.load(frame: index, ids: useIDs, maps: detector == .maps)
        }, depth: depthFiles.map { files in { index in try files.load(frame: index) } })
    }

    /// Replay a sweep whose frames come from `load` (by frame index).
    /// - Parameter depth: each frame's depth map by frame index, read when `settings.useDepth`.
    public static func run(sweep: ReplaySweep, detector: ReplayDetector, settings: Settings = Settings(),
                           load: (Int) throws -> ReplayFrameData, depth: ((Int) throws -> DepthMap)? = nil) throws -> Run {
        let work = sweep.work
        let tracker = PieceTracker(settings: settings.tracker)
        var frames: [FrameResult] = []
        var wholeFrames: [Int: Int] = [:]
        var usedMaps = true
        var lastProcessed = -TimeInterval.infinity
        var lastPosition: SIMD3<Float>?
        var lastTime: TimeInterval = 0

        var gate = SharpnessGate(settings: settings.sharpness)
        var ledger = VisibilityLedger(settings: settings.visibility)
        var log = ObservationLog()
        var phantoms = placePhantoms(sweep: sweep, settings: settings)
        /// Each piece's best view so far: its quality and the frame it came from.
        var bestView: [UUID: (quality: Float, frame: Int)] = [:]
        var frameSeconds = 0.0, regionSeconds = 0.0, timedFrames = 0

        for (index, frame) in sweep.frames.enumerated() {
            var result = FrameResult(file: frame.file, time: frame.time, skipped: nil, detections: 0, observations: 0, wholePieces: [])
            result.blurPx = settings.frameBlurPx.flatMap { index < $0.count ? $0[index] : nil }
            guard let projector = sweep.projector(frame) else {
                result.skipped = skippedNoPose
                frames.append(result)
                continue
            }
            let camera = projector.camera
            let position = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
            let time = frame.time

            // Gating, in ScanEngine.session(_:didUpdate:)'s order. Speed is measured on every frame.
            var speed: Float = 0
            if let lastPosition, time > lastTime {
                speed = TableMath.distance(position, lastPosition) / Float(time - lastTime)
            }
            lastPosition = position
            lastTime = time
            guard time - lastProcessed >= settings.frameInterval - settings.intervalSlack else {
                result.skipped = skippedTooSoon
                frames.append(result)
                continue
            }
            lastProcessed = time
            // ARKit's tracking state and the table plane are always good in a render.
            let forward = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
            guard forward.y < -settings.minDownwardTilt else {
                result.skipped = skippedTilted
                frames.append(result)
                continue
            }
            guard speed <= settings.maxSpeed else {
                result.skipped = skippedFast
                frames.append(result)
                continue
            }

            // ScanEngine.process(frame:...)
            let data = try load(index)
            guard data.rgba.count >= work.width * work.height * 4 else {
                throw ReplayError("frame \(frame.file) has too few pixels")
            }
            if settings.sharpnessGate {
                let started = Date()
                let score = Sharpness.frameScore(rgba: data.rgba, width: work.width, height: work.height)
                frameSeconds += Date().timeIntervalSince(started)
                timedFrames += 1
                result.sharpness = score
                guard gate.admit(score) else {
                    result.skipped = skippedBlurred
                    frames.append(result)
                    continue
                }
            }
            var blobs: [DetectedBlob]
            switch detector {
            case .colour:
                blobs = PieceDetector.detect(rgba: data.rgba, width: work.width, height: work.height)
            case .truth:
                guard let ids = data.ids else { throw ReplayError("frame \(frame.file) has no piece-number map") }
                blobs = ReplayTruthDetector.blobs(ids: ids, rgba: data.rgba, width: work.width, height: work.height).map { $0.blob }
            case .maps:
                blobs = try groupMaps(data, frame: frame, work: work, settings: settings)
            }
            if !phantoms.isEmpty {
                let injected = phantomBlobs(&phantoms, projector: projector, sweep: sweep, settings: settings)
                result.phantoms = injected.count
                blobs += injected
            }

            let step = Float(work.step)
            let depthMap = settings.useDepth ? try depth?(index) : nil
            tracker.beginFrame()
            var observations: [PieceObservation] = []
            var matched: [TrackedPiece?] = []
            var qualities: [Float] = []
            if settings.sharpnessViews && !settings.sharpnessGate { gate.startFrame() }   // admit starts frames otherwise
            for blob in blobs {
                guard let spot = projector.locate(workX: blob.cx, workY: blob.cy, step: step) else { continue }
                var quality = PieceTracker.viewQuality(of: blob, frameWidth: work.width, frameHeight: work.height)
                if settings.sharpnessViews {
                    let started = Date()
                    let region = Sharpness.regionScore(rgba: data.rgba, width: work.width, height: work.height, blob: blob)
                    quality *= gate.viewFactor(region)
                    regionSeconds += Date().timeIntervalSince(started)
                }
                let depthHeight = depthMap.flatMap {
                    DepthHeight.heightMm(map: $0, blob: blob, step: step, imageWidth: Float(sweep.width), imageHeight: Float(sweep.height),
                                         projector: projector, settings: settings.depth)
                }
                let observation = PieceObservation(blob: blob, position: spot.position, mmPerPixel: spot.mmPerPixel, quality: quality,
                                                   cameraPosition: position, depthHeightMm: depthHeight)
                if settings.matchWholeFrame {
                    observations.append(observation)
                } else {   // as ScanEngine used to, one detection at a time
                    matched.append(tracker.observe(observation, time: time))
                    qualities.append(quality)
                }
            }
            if settings.matchWholeFrame {
                matched = tracker.observe(frame: observations, time: time)
                qualities = observations.map { $0.quality }
            }
            for (piece, quality) in zip(matched, qualities) {
                guard let piece else { continue }
                if quality >= bestView[piece.id]?.quality ?? -1 { bestView[piece.id] = (quality, index) }
            }
            result.observations = matched.compactMap { $0 }.count
            let matchedIDs = matched.compactMap { $0?.id }
            if settings.negativeEvidence {
                ledger.record(view: projector, imageWidth: Float(sweep.width), imageHeight: Float(sweep.height),
                              inset: settings.coverageInset, pieces: tracker.pieces, matched: Set(matchedIDs))
            }
            log.record(frame: matchedIDs)
            for id in tracker.endFrame(time: time) {
                ledger.forget(id)
                log.forget(id)
                bestView[id] = nil
            }
            result.detections = blobs.count

            // Which true pieces the camera showed whole in this frame: the fair denominator.
            let whole: Set<Int>
            if let ids = data.ids {
                whole = ReplayTruthDetector.wholePieces(ids: ids, width: work.width, height: work.height)
            } else {
                usedMaps = false
                whole = Set(sweep.pieces.filter { inView($0, projector: projector, sweep: sweep) }.map { $0.id })
            }
            result.wholePieces = whole.sorted()
            for id in whole { wholeFrames[id, default: 0] += 1 }
            frames.append(result)
        }

        // The clean-up when the user taps Review, over the pieces that would be listed.
        var absorbed = Set<UUID>()
        if settings.consolidate {
            let candidates = tracker.confirmed.filter { !(settings.negativeEvidence && ledger.isDoubtful($0.id)) }
            absorbed = TrackConsolidation.plan(pieces: candidates, log: log, settings: settings.consolidation).absorbed
        }

        let tracked = tracker.pieces.map { piece in
            var row = TrackedResult(x: piece.position.x, z: piece.position.z, longMm: piece.longMm, shortMm: piece.shortMm,
                                    rgb: piece.rgbHex, sightings: piece.sightings, confirmed: tracker.isConfirmed(piece),
                                    heightMm: piece.heightMm, heightSource: piece.heightSource,
                                    doubtful: settings.negativeEvidence && ledger.isDoubtful(piece.id),
                                    absorbed: absorbed.contains(piece.id))
            if settings.negativeEvidence {
                let entry = ledger.entry(piece.id)
                row.hits = entry.hits
                row.misses = entry.misses
            }
            if let blur = settings.frameBlurPx, let best = bestView[piece.id], best.frame < blur.count {
                row.bestViewBlurPx = blur[best.frame]
            }
            return row
        }
        var techniques: [String] = []
        if settings.sharpnessGate { techniques.append("sharpness gate") }
        if settings.sharpnessViews { techniques.append("sharpness in view quality") }
        if settings.negativeEvidence { techniques.append("negative evidence") }
        if settings.consolidate { techniques.append("consolidation") }
        if settings.phantoms > 0 { techniques.append("\(phantoms.count) phantoms injected") }
        var run = Run(frames: frames, tracked: tracked, wholeFrames: wholeFrames,
                      visibilityMethod: usedMaps ? "piece maps" : "geometry",
                      matching: settings.matchWholeFrame ? "whole frame" : "one at a time")
        run.techniques = techniques
        let processed = frames.filter { $0.skipped == nil }.count
        if settings.sharpnessGate, timedFrames > 0 { run.sharpnessFrameMs = frameSeconds * 1000 / Double(timedFrames) }
        if settings.sharpnessViews, processed > 0 { run.sharpnessRegionsMs = regionSeconds * 1000 / Double(processed) }
        run.phantomsPlaced = phantoms.count
        run.consolidationMerges = absorbed.count
        return run
    }

    /// Each frame's motion blur in working pixels, from sweep.json's per-frame `blurPx` (full-resolution pixels,
    /// written by render_sweep.py --motion-blur); nil if no frame has one.
    public static func blurLengths(folder: ReplayFolder) -> [Float]? {
        struct Sweep: Decodable {
            struct Frame: Decodable { let blurPx: Float? }
            let frames: [Frame]
        }
        guard let data = try? Data(contentsOf: folder.url.appendingPathComponent("sweep.json")),
              let sweep = try? JSONDecoder().decode(Sweep.self, from: data),
              sweep.frames.contains(where: { $0.blurPx != nil }) else { return nil }
        let scale = 1 / Float(folder.sweep.work.step)
        return sweep.frames.map { ($0.blurPx ?? 0) * scale }
    }

    // MARK: Phantoms

    struct Phantom {
        var position: SIMD3<Float>
        var longMm: Float, shortMm: Float
        var r: UInt8, g: UInt8, b: UInt8
        var shown = 0
    }

    /// SplitMix64: a small seeded generator, so a replay with phantoms is the same every time and on every platform.
    struct SeededRandom {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in [a, b).
        mutating func uniform(_ a: Float, _ b: Float) -> Float {
            a + (b - a) * Float(next() >> 40) / Float(1 << 24)
        }
    }

    /// Random free spots on the table: inside the area the true pieces cover, clear of every true piece by its radius,
    /// the phantom's half length and 5 mm, so the scoring can only call the phantom a phantom.
    static func placePhantoms(sweep: ReplaySweep, settings: Settings) -> [Phantom] {
        guard settings.phantoms > 0, !sweep.pieces.isEmpty else { return [] }
        var random = SeededRandom(state: settings.phantomSeed)
        let xs = sweep.pieces.map { $0.x }, zs = sweep.pieces.map { $0.z }
        let minX = xs.min()!, maxX = xs.max()!, minZ = zs.min()!, maxZ = zs.max()!
        var placed: [Phantom] = []
        var tries = 0
        while placed.count < settings.phantoms && tries < 20_000 {
            tries += 1
            let long = random.uniform(8, 24)
            let short = long * random.uniform(0.4, 1)
            let position = SIMD3<Float>(random.uniform(minX, maxX), sweep.tableY, random.uniform(minZ, maxZ))
            let colour = (UInt8(random.uniform(0, 255)), UInt8(random.uniform(0, 255)), UInt8(random.uniform(0, 255)))
            let clearOfPieces = sweep.pieces.allSatisfy { p in
                let dx = p.x - position.x, dz = p.z - position.z
                return (dx * dx + dz * dz).squareRoot() * 1000 > p.radiusMm + long / 2 + 5
            }
            let clearOfPhantoms = placed.allSatisfy { TableMath.distance($0.position, position) * 1000 > ($0.longMm + long) / 2 + 5 }
            if clearOfPieces && clearOfPhantoms {
                placed.append(Phantom(position: position, longMm: long, shortMm: short, r: colour.0, g: colour.1, b: colour.2))
            }
        }
        return placed
    }

    /// This frame's phantom blobs: phantoms not yet shown `phantomFrames` times whose spot lies well inside the view
    /// (by the same test `VisibilityLedger` uses to count a miss).
    static func phantomBlobs(_ phantoms: inout [Phantom], projector: TableProjector, sweep: ReplaySweep,
                             settings: Settings) -> [DetectedBlob] {
        let work = sweep.work
        let step = Float(work.step)
        let footprint = CoverageMap.footprint(of: projector, imageWidth: Float(sweep.width), imageHeight: Float(sweep.height),
                                              inset: settings.coverageInset, maxDepth: settings.visibility.maxDepth)
        var blobs: [DetectedBlob] = []
        for i in phantoms.indices where phantoms[i].shown < settings.phantomFrames {
            let p = phantoms[i]
            let margin = p.longMm / 2000 + settings.visibility.edgeMargin
            guard VisibilityLedger.contains(footprint, SIMD2(p.position.x, p.position.z), margin: margin),
                  let pixel = imagePoint(p.position, projector: projector) else { continue }
            let x = pixel.x / step, y = pixel.y / step
            guard let spot = projector.locate(workX: x, workY: y, step: step), spot.mmPerPixel > 0 else { continue }
            let major = p.longMm / spot.mmPerPixel, minor = p.shortMm / spot.mmPerPixel
            let minX = Int((x - major / 2).rounded(.down)), maxX = Int((x + major / 2).rounded(.up))
            let minY = Int((y - minor / 2).rounded(.down)), maxY = Int((y + minor / 2).rounded(.up))
            guard minX > 0, minY > 0, maxX < work.width - 1, maxY < work.height - 1 else { continue }
            blobs.append(DetectedBlob(minX: minX, minY: minY, maxX: maxX, maxY: maxY, area: max(1, Int(major * minor)),
                                      cx: x, cy: y, major: major, minor: minor, r: p.r, g: p.g, b: p.b))
            phantoms[i].shown += 1
        }
        return blobs
    }

    /// Where a world point appears in the full-resolution image, or nil if it is behind the camera.
    static func imagePoint(_ world: SIMD3<Float>, projector: TableProjector) -> SIMD2<Float>? {
        let c = projector.camera.columns
        let p = world - SIMD3<Float>(c.3.x, c.3.y, c.3.z)
        let right = SIMD3<Float>(c.0.x, c.0.y, c.0.z), up = SIMD3<Float>(c.1.x, c.1.y, c.1.z), back = SIMD3<Float>(c.2.x, c.2.y, c.2.z)
        let depth = -(p * back).sum()
        guard depth > 1e-4 else { return nil }
        return SIMD2(projector.cx + projector.fx * (p * right).sum() / depth, projector.cy - projector.fy * (p * up).sum() / depth)
    }

    /// The app's InstanceDetector after the network: same input size check, padding rows and grouping thresholds.
    static func groupMaps(_ data: ReplayFrameData, frame: ReplaySweep.Frame, work: (step: Int, width: Int, height: Int),
                          settings: Settings) throws -> [DetectedBlob] {
        guard let maps = data.maps else { throw ReplayError("frame \(frame.file) has no detector output (\(frame.stem).maps)") }
        let stride = settings.mapsStride
        guard work.width == settings.mapsInputWidth, work.height >= stride * 4, work.height <= settings.mapsInputHeight else {
            throw ReplayError("the detector model takes \(settings.mapsInputWidth) x \(settings.mapsInputHeight) frames; "
                              + "this sweep's are \(work.width) x \(work.height), so the app would fall back to the colour detector")
        }
        let ow = settings.mapsInputWidth / stride, fullOH = settings.mapsInputHeight / stride
        guard maps.count == ow * fullOH * 4 else {
            throw ReplayError("\(frame.stem).maps holds \(maps.count) numbers, expected 4 x \(ow) x \(fullOH)")
        }
        return InstanceGrouping.group(maps: maps, outputWidth: ow, validRows: work.height / stride, rgba: data.rgba,
                                      frameWidth: work.width, stride: stride, pieceThreshold: settings.pieceThreshold,
                                      peakThreshold: settings.peakThreshold, minArea: settings.mapsMinArea)
    }

    /// Without piece maps: whether a circle of the piece's radius around it, at table level and at its top,
    /// lies inside the working frame (one pixel in from the edge).
    static func inView(_ piece: ReplaySweep.Piece, projector: TableProjector, sweep: ReplaySweep) -> Bool {
        let c = projector.camera.columns
        let origin = SIMD3<Float>(c.3.x, c.3.y, c.3.z)
        let right = SIMD3<Float>(c.0.x, c.0.y, c.0.z), up = SIMD3<Float>(c.1.x, c.1.y, c.1.z), back = SIMD3<Float>(c.2.x, c.2.y, c.2.z)
        let work = sweep.work
        let step = Float(work.step)
        let radius = piece.radiusMm / 1000
        let top = (piece.heightMm ?? piece.radiusMm) / 1000
        for k in 0..<16 {
            let angle = Float(k) / 16 * 2 * Float.pi
            for lift in [Float(0), top] {
                let p = SIMD3<Float>(piece.x + radius * cos(angle), sweep.tableY + lift, piece.z + radius * sin(angle)) - origin
                let depth = -(p * back).sum()
                guard depth > 0 else { return false }
                let fullX = sweep.cx + sweep.fx * (p * right).sum() / depth
                let fullY = sweep.cy - sweep.fy * (p * up).sum() / depth
                let x = fullX / step, y = fullY / step
                if x < 1 || y < 1 || x > Float(work.width - 2) || y > Float(work.height - 2) { return false }
            }
        }
        return true
    }
}
