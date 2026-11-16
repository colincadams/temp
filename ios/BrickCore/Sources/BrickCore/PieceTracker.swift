import Foundation

/// One detection of a piece in one frame, already placed on the table.
public struct PieceObservation {
    /// Position on the table in world space (metres).
    public var position: SIMD3<Float>
    /// Longest and shortest side of the footprint in millimetres.
    public var longMm: Float
    public var shortMm: Float
    /// Median colour of the piece's pixels.
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    /// How good a picture of the piece this frame is; see `PieceTracker.viewQuality`.
    public var quality: Float
    /// Where the camera was, in world space. Lets the tracker allow for the piece's height (`HeightGeometry`);
    /// without it the piece is taken as flat, as before.
    public var cameraPosition: SIMD3<Float>?
    /// The piece's height above the table measured from LiDAR depth in this frame (`DepthHeight`), millimetres;
    /// nil without depth, or when too few depth pixels were usable.
    public var depthHeightMm: Float?

    public init(position: SIMD3<Float>, longMm: Float, shortMm: Float, r: UInt8, g: UInt8, b: UInt8, quality: Float,
                cameraPosition: SIMD3<Float>? = nil, depthHeightMm: Float? = nil) {
        self.position = position
        self.longMm = longMm
        self.shortMm = shortMm
        self.r = r; self.g = g; self.b = b
        self.quality = quality
        self.cameraPosition = cameraPosition
        self.depthHeightMm = depthHeightMm
    }

    /// - Parameters:
    ///   - mmPerPixel: scale at the blob, from `TableProjector.locate`.
    public init(blob: DetectedBlob, position: SIMD3<Float>, mmPerPixel: Float, quality: Float,
                cameraPosition: SIMD3<Float>? = nil, depthHeightMm: Float? = nil) {
        self.init(position: position, longMm: blob.major * mmPerPixel, shortMm: blob.minor * mmPerPixel,
                  r: blob.r, g: blob.g, b: blob.b, quality: quality, cameraPosition: cameraPosition, depthHeightMm: depthHeightMm)
    }
}

/// How a piece's height was worked out.
public enum HeightSource: String, Codable {
    /// Not enough to go on yet: taken as flat.
    case none
    /// From LiDAR depth (median over its frames).
    case depth
    /// From how its detected spot slid as the camera moved (`HeightGeometry.fitLift`).
    case views
}

/// A piece followed across frames. Created and owned by `PieceTracker`.
///
/// The tracker maintains the position, sightings and measurements. The recognition fields further down are
/// bookkeeping for whoever runs recognition (the app's `ScanEngine`); the tracker only reads them in
/// `shouldClassify` and `shouldSubmit`.
public final class TrackedPiece {
    public let id: UUID
    public let firstSeen: TimeInterval
    public internal(set) var position: SIMD3<Float>
    /// Frames this piece was detected in.
    public internal(set) var sightings = 1
    /// Most recent measurements, oldest first.
    public internal(set) var longSamples: [Float] = []
    public internal(set) var shortSamples: [Float] = []
    public internal(set) var rSamples: [Float] = []
    public internal(set) var gSamples: [Float] = []
    public internal(set) var bSamples: [Float] = []
    /// Best `PieceObservation.quality` seen so far.
    public internal(set) var bestQuality: Float = 0
    /// Height of the piece's top above the table in millimetres; 0 for a flat piece or while it is not known.
    public internal(set) var heightMm: Float = 0
    public internal(set) var heightSource = HeightSource.none
    /// The scanning pass the piece was found in (`PieceTracker.startNewPass`). Pieces of earlier passes are kept for the
    /// count and the review but are never matched again: their positions belong to a world ARKit has since replaced.
    public internal(set) var pass = 0

    /// One recent detection with a known camera, for the height-aware placement (oldest first).
    struct Placement {
        var spot: SIMD2<Float>
        var lever: SIMD2<Float>
        var depthHeightMm: Float?
    }
    var placements: [Placement] = []
    /// Camera height above the table for each of `longSamples` (0 when not known), for the scale correction.
    var sampleCameraHeights: [Float] = []
    /// Metres above the table of the outline's middle (`HeightGeometry`), and the base it gives (x, z).
    var lift: Float = 0
    var base: SIMD2<Float>?
    /// Height (metres) at which the outline is measured, for `longMm` and `shortMm`.
    var scaleHeight: Float = 0

    // MARK: Recognition bookkeeping

    public var thumbnail: Data?
    public var thumbnailQuality: Float = 0
    /// Server recognition: views answered, requests under way, requests failed.
    public var views = 0
    public var inFlight = 0
    public var failures = 0
    /// Where the camera was when the last crop was sent to the server; nil allows the next one straight away.
    public var lastSubmitCamera: SIMD3<Float>?
    /// Server recognition scores added up over `views`, by part number.
    public var scoreSum: [String: Double] = [:]
    /// On-device recognition: per-shape log-probabilities added up over `deviceViews`.
    public private(set) var logSum: [Float] = []
    public private(set) var deviceViews = 0
    public private(set) var lastDeviceCamera: SIMD3<Float>?
    /// Part numbers whose description has been asked of the server.
    public var requestedInfo = Set<String>()
    /// Whether a crop has been sent to the server for a second opinion (at most once per piece).
    public var secondOpinionRequested = false

    init(id: UUID = UUID(), position: SIMD3<Float>, time: TimeInterval) {
        self.id = id
        self.position = position
        self.firstSeen = time
    }

    /// Median of the recent measurements, measured at the piece's height rather than the table's when it stands up
    /// off the table (`HeightGeometry.scale`).
    public var longMm: Float { TableMath.median(scaled(longSamples)) }
    public var shortMm: Float { TableMath.median(scaled(shortSamples)) }
    /// The same, as measured on the table plane.
    public var tableLongMm: Float { TableMath.median(longSamples) }

    private func scaled(_ samples: [Float]) -> [Float] {
        guard scaleHeight > 0, sampleCameraHeights.count == samples.count else { return samples }
        let all = zip(samples, sampleCameraHeights).map { $0 * HeightGeometry.scale(cameraHeight: $1, height: scaleHeight) }
        guard minSteepViews > 0, sampleLevers.count == samples.count, samples.count >= 2 * minSteepViews else { return all }
        // The views most nearly from straight above show the least of the piece's side.
        let order = sampleLevers.indices.sorted { sampleLevers[$0] < sampleLevers[$1] }
        return order.prefix(max(minSteepViews, samples.count / 2)).map { all[$0] }
    }
    /// Length of the lever (`HeightGeometry.lever`) for each of `longSamples` (when known), and how few views from
    /// nearest straight above to measure a tall piece from.
    var sampleLevers: [Float] = []
    var minSteepViews = 3

    /// Median colour as "rrggbb".
    public var rgbHex: String {
        let r = Int(TableMath.median(rSamples)), g = Int(TableMath.median(gSamples)), b = Int(TableMath.median(bSamples))
        return String(format: "%02x%02x%02x", r, g, b)
    }

    func addSample(_ observation: PieceObservation, keeping limit: Int) {
        if longSamples.count >= limit {
            longSamples.removeFirst(); shortSamples.removeFirst()
            rSamples.removeFirst(); gSamples.removeFirst(); bSamples.removeFirst()
            if !sampleCameraHeights.isEmpty { sampleCameraHeights.removeFirst() }
            if !sampleLevers.isEmpty { sampleLevers.removeFirst() }
        }
        let cameraHeight = observation.cameraPosition.map { $0.y - observation.position.y } ?? 0
        if sampleCameraHeights.count == longSamples.count { sampleCameraHeights.append(cameraHeight) }
        if sampleLevers.count == longSamples.count {
            let lever = observation.cameraPosition.flatMap { HeightGeometry.lever(position: observation.position, camera: $0) }
            sampleLevers.append(lever.map { ($0 * $0).sum().squareRoot() } ?? 0)
        }
        longSamples.append(observation.longMm)
        shortSamples.append(observation.shortMm)
        rSamples.append(Float(observation.r)); gSamples.append(Float(observation.g)); bSamples.append(Float(observation.b))
    }

    /// Carry everything stored in world space about this piece by a rigid motion: ARKit corrected its map, and the
    /// piece's anchor moved with the correction (`PieceAnchoring`). Directions (the levers of its views) turn with it;
    /// lengths and heights do not change.
    func apply(_ motion: Matrix4) {
        position = motion.transformPoint(position)
        let y = position.y
        func movePoint(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let q = motion.transformPoint(SIMD3(p.x, y, p.y))
            return SIMD2(q.x, q.z)
        }
        func turn(_ v: SIMD2<Float>) -> SIMD2<Float> {
            let w = motion.transformVector(SIMD3(v.x, 0, v.y))
            return SIMD2(w.x, w.z)
        }
        if let base { self.base = movePoint(base) }
        for i in placements.indices {
            placements[i].spot = movePoint(placements[i].spot)
            placements[i].lever = turn(placements[i].lever)
        }
        if let camera = lastDeviceCamera { lastDeviceCamera = motion.transformPoint(camera) }
        if let camera = lastSubmitCamera { lastSubmitCamera = motion.transformPoint(camera) }
    }

    /// Record one on-device recognition of this piece.
    ///
    /// - Parameter logProbabilities: log-probability of each shape for this view.
    ///   A list whose length differs from earlier views is ignored.
    public func addDeviceView(logProbabilities: [Float], cameraPosition: SIMD3<Float>) {
        if logSum.isEmpty { logSum = [Float](repeating: 0, count: logProbabilities.count) }
        guard logSum.count == logProbabilities.count else { return }
        for i in 0..<logProbabilities.count { logSum[i] += logProbabilities[i] }
        deviceViews += 1
        lastDeviceCamera = cameraPosition
    }

    /// Record one answer from the server's recognition service.
    public func addServerView(scores: [(partNum: String, score: Double)]) {
        views += 1
        for entry in scores { scoreSum[entry.partNum, default: 0] += entry.score }
    }

    /// A part's server score averaged over every answered view (0 if it was never among the answers).
    public func averageScore(_ partNum: String) -> Double {
        views > 0 ? (scoreSum[partNum] ?? 0) / Double(views) : 0
    }
}

/// Follows pieces across the frames of a sweep so each one is counted once.
///
/// A detection at the spot of a piece already known is that piece again; anywhere else it starts a new one.
/// Drive it once per processed frame: `beginFrame()`, `observe` for each detection, then `endFrame(time:)`.
/// Not thread-safe: use from one queue.
public final class PieceTracker {
    public struct Settings {
        /// Sightings before a blob counts as a piece.
        public var confirmAfter = 3
        /// Seconds an unconfirmed blob may go unseen before it is dropped.
        public var pruneAfter: TimeInterval = 3
        /// Footprints outside this range are not Lego pieces: grit, or a hand or sleeve.
        public var minLongMm: Float = 4
        public var maxLongMm: Float = 400
        /// A detection within this distance of a known piece is the same piece: the larger of
        /// `minMatchRadius` (metres) and `matchRadiusPerLength` times the detection's long side.
        /// Tall pieces shift a little with viewing angle, hence the slack.
        public var minMatchRadius: Float = 0.010
        public var matchRadiusPerLength: Float = 0.5
        /// How far a piece's position moves towards each new detection (0...1).
        public var positionBlend: Float = 0.25
        /// Measurements kept per piece for the running medians.
        public var sampleLimit = 25
        /// Server recognition: views per piece, and metres the camera must move before a second view is worth sending.
        public var viewsPerPiece = 2
        public var secondViewBaseline: Float = 0.08
        /// Server recognition: failed requests after which a piece is no longer sent.
        public var maxFailures = 2
        /// On-device recognition: views fused per piece, and metres the camera must move between those views.
        public var deviceViewsPerPiece = 8
        public var deviceViewBaseline: Float = 0.03

        // MARK: Height (`HeightGeometry`); used only for observations that carry their camera position.

        /// Allow for pieces standing up off the table: place each by the table point under it, match detections after
        /// allowing for the slide its height causes, and measure its outline at its height.
        public var heightAware = true
        /// Heights below this (mm) count as flat: lower than the depth noise and the fit can tell apart.
        public var flatBelowMm: Float = 6
        /// Height of the outline's middle as a share of the piece's height (its lift; see `HeightGeometry`).
        public var liftFraction: Float = 0.5
        /// Height at which the outline is measured, as a share of the piece's height.
        public var scaleFraction: Float = 1
        /// Frames with a depth height before depth decides the piece's height (median of them).
        public var minDepthReadings = 2
        /// Without depth: views, and how much they must differ (`HeightGeometry.LiftFit.spread`), before the
        /// height is fitted from how the piece's spot slides.
        public var minFitViews = 3
        public var minLeverSpread: Float = 0.02
        public var liftRidge: Float = 0.005
        public var maxLift: Float = 0.04
        /// Widen the match distance for a piece whose outline length changes a lot between views (it looks tall)
        /// by `HeightGeometry.slideBound`, at most `maxSlide` metres, until its height is known.
        public var maxSlide: Float = 0.02
        /// A tall piece's size is measured from the half of its views taken most nearly from straight above (at least
        /// this many), which show least of its side; 0 measures from all views.
        public var steepViews = 3

        public init() {}
    }

    public let settings: Settings
    /// Every tracked piece, confirmed or not, oldest first.
    public private(set) var pieces: [TrackedPiece] = []
    private var matched = Set<UUID>()

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Pieces seen often enough to count, from every pass.
    public var confirmed: [TrackedPiece] { pieces.filter { isConfirmed($0) } }

    /// The pass new pieces belong to, and the only one matched against (`startNewPass`).
    public private(set) var currentPass = 0

    /// Pieces of the current pass, confirmed or not.
    public var currentPieces: [TrackedPiece] { pieces.filter { $0.pass == currentPass } }

    /// Confirmed pieces of the current pass: the ones the coverage map, negative evidence and the completion guess are
    /// about, since only they live in the current world.
    public var currentConfirmed: [TrackedPiece] { pieces.filter { $0.pass == currentPass && isConfirmed($0) } }

    /// Start a fresh pass after tracking was lost for good: keep every confirmed piece for the count and the review,
    /// but never match a new detection to one of them again, and drop the unconfirmed ones.
    /// - Returns: the ids of the pieces dropped.
    @discardableResult
    public func startNewPass() -> [UUID] {
        var removed: [UUID] = []
        pieces.removeAll { piece in
            let drop = piece.pass == currentPass && !isConfirmed(piece)
            if drop { removed.append(piece.id) }
            return drop
        }
        currentPass += 1
        matched.removeAll()
        return removed
    }

    /// Carry a piece by a rigid motion (ARKit moved the anchor it is stored against; see `PieceAnchoring`).
    public func move(_ piece: TrackedPiece, by motion: Matrix4) {
        piece.apply(motion)
    }

    public func isConfirmed(_ piece: TrackedPiece) -> Bool { piece.sightings >= settings.confirmAfter }

    public func piece(id: UUID) -> TrackedPiece? { pieces.first { $0.id == id } }

    /// Forget every piece.
    public func reset() {
        pieces.removeAll()
        matched.removeAll()
        currentPass = 0
    }

    /// Call before the first `observe` of each frame.
    public func beginFrame() {
        matched.removeAll()
    }

    /// Match one detection of this frame to a known piece, or start tracking a new one.
    ///
    /// Each piece is matched by at most one detection per frame.
    /// - Returns: the piece, or nil if the detection is too small or too large to be a Lego piece.
    @discardableResult
    public func observe(_ observation: PieceObservation, time: TimeInterval) -> TrackedPiece? {
        let longMm = observation.longMm
        guard longMm >= settings.minLongMm, longMm <= settings.maxLongMm else { return nil }

        var nearest: TrackedPiece?
        var nearestDistance = Float.infinity
        for piece in pieces where !matched.contains(piece.id) && piece.pass == currentPass {
            if let d = matchDistance(piece, observation), d < nearestDistance { nearest = piece; nearestDistance = d }
        }
        return record(observation, into: nearest, time: time)
    }

    /// How far a detection is from a known piece, or nil if too far to be that piece.
    ///
    /// The plain rule: within the larger of `minMatchRadius` and `matchRadiusPerLength` times the detection's long side.
    /// Height-aware, for a detection with its camera position: the detection is first moved to the base it implies
    /// with the piece's lift (or, while the piece's height is unknown, the lift of this frame's depth height), and
    /// compared with the piece's base. While the piece's height is still unknown and its outline length has varied a
    /// lot between views, the distance allowed grows by how far the side of a tall piece could move the outline's middle.
    func matchDistance(_ piece: TrackedPiece, _ observation: PieceObservation) -> Float? {
        var radius = max(settings.minMatchRadius, observation.longMm / 1000 * settings.matchRadiusPerLength)
        guard settings.heightAware, let camera = observation.cameraPosition, let base = piece.base,
              let lever = HeightGeometry.lever(position: observation.position, camera: camera) else {
            let d = TableMath.distance(piece.position, observation.position)
            return d < radius ? d : nil
        }
        var lift = piece.lift
        if piece.heightSource == .none, let h = observation.depthHeightMm, h >= settings.flatBelowMm {
            lift = h / 1000 * settings.liftFraction
        }
        let moved = HeightGeometry.base(position: observation.position, lever: lever, lift: lift)
        let d = TableMath.distance(SIMD3<Float>(base.x, moved.y, base.y), moved)
        if piece.heightSource == .none, let shortest = piece.longSamples.min() {
            let lengths = piece.longSamples + [observation.longMm]
            let lowest = min(shortest, observation.longMm), highest = lengths.max() ?? lowest
            if highest - lowest > max(3, 0.25 * lowest) {
                let slide = HeightGeometry.slideBound(longMm: observation.longMm, shortestMm: lowest)
                    + HeightGeometry.slideBound(longMm: TableMath.median(piece.longSamples), shortestMm: lowest)
                radius += min(settings.maxSlide, slide)
            }
        }
        return d < radius ? d : nil
    }

    /// Match all of one frame's detections at once, closest pairs first, or start tracking new pieces.
    ///
    /// Unlike calling `observe` once per detection, the result does not depend on the order of the detections:
    /// a piece seen for the first time right next to a known one cannot take over that piece's track just because
    /// its detection came first, which would leave the known piece to start a second track (counted twice).
    /// Each piece is matched by at most one detection per frame.
    /// - Returns: for each observation in order, its piece, or nil if it is too small or too large to be a Lego piece.
    @discardableResult
    public func observe(frame observations: [PieceObservation], time: TimeInterval) -> [TrackedPiece?] {
        var candidates: [(observation: Int, piece: Int, distance: Float)] = []
        for (o, observation) in observations.enumerated() {
            guard observation.longMm >= settings.minLongMm, observation.longMm <= settings.maxLongMm else { continue }
            for (p, piece) in pieces.enumerated() where !matched.contains(piece.id) && piece.pass == currentPass {
                if let d = matchDistance(piece, observation) { candidates.append((o, p, d)) }
            }
        }
        // Ties are broken by order so the result is deterministic.
        candidates.sort { ($0.distance, $0.observation, $0.piece) < ($1.distance, $1.observation, $1.piece) }
        var pieceFor = [TrackedPiece?](repeating: nil, count: observations.count)
        var taken = Set<Int>()
        for candidate in candidates where pieceFor[candidate.observation] == nil && !taken.contains(candidate.piece) {
            pieceFor[candidate.observation] = pieces[candidate.piece]
            taken.insert(candidate.piece)
        }
        return observations.enumerated().map { o, observation in
            guard observation.longMm >= settings.minLongMm, observation.longMm <= settings.maxLongMm else { return nil }
            return record(observation, into: pieceFor[o], time: time)
        }
    }

    /// Add a detection to `existing`, or start a new piece with it.
    private func record(_ observation: PieceObservation, into existing: TrackedPiece?, time: TimeInterval) -> TrackedPiece {
        let piece: TrackedPiece
        if let existing {
            piece = existing
            piece.sightings += 1
            piece.position = TableMath.mix(piece.position, observation.position, settings.positionBlend)
        } else {
            piece = TrackedPiece(position: observation.position, time: time)
            piece.pass = currentPass
            pieces.append(piece)
        }
        matched.insert(piece.id)
        piece.addSample(observation, keeping: settings.sampleLimit)
        piece.bestQuality = max(piece.bestQuality, observation.quality)
        if settings.heightAware, let camera = observation.cameraPosition,
           let lever = HeightGeometry.lever(position: observation.position, camera: camera) {
            if piece.placements.count >= settings.sampleLimit { piece.placements.removeFirst() }
            piece.placements.append(TrackedPiece.Placement(spot: SIMD2(observation.position.x, observation.position.z),
                                                           lever: lever, depthHeightMm: observation.depthHeightMm))
            updateHeight(piece, tableY: observation.position.y)
        }
        return piece
    }

    /// Work out a piece's height from its recent placements, then its base, position and measuring height.
    ///
    /// Depth decides when at least `minDepthReadings` frames measured it (their median). Otherwise, once there are
    /// `minFitViews` views that differ enough, the lift is fitted from how the spot slid (`HeightGeometry.fitLift`) and
    /// the height is the lift over `liftFraction`. Anything under `flatBelowMm` is flat: lift 0, and the base is simply
    /// the mean spot. The position is the mean of the bases the placements imply with that lift.
    func updateHeight(_ piece: TrackedPiece, tableY: Float) {
        let placements = piece.placements
        guard !placements.isEmpty else { return }
        let depthHeights = placements.compactMap { $0.depthHeightMm }
        var heightMm: Float = 0
        if depthHeights.count >= settings.minDepthReadings {
            heightMm = TableMath.median(depthHeights)
            piece.heightSource = .depth
        } else if placements.count >= settings.minFitViews,
                  let fit = HeightGeometry.fitLift(positions: placements.map { $0.spot }, levers: placements.map { $0.lever },
                                                   ridge: settings.liftRidge, maxLift: settings.maxLift),
                  fit.spread >= settings.minLeverSpread {
            heightMm = fit.lift / settings.liftFraction * 1000
            piece.heightSource = .views
        } else {
            piece.heightSource = .none
        }
        if heightMm < settings.flatBelowMm { heightMm = 0 }
        piece.heightMm = heightMm
        piece.lift = heightMm / 1000 * settings.liftFraction
        piece.scaleHeight = heightMm / 1000 * settings.scaleFraction
        piece.minSteepViews = settings.steepViews
        var sum = SIMD2<Float>(0, 0)
        for placement in placements { sum += placement.spot - piece.lift * placement.lever }
        let base = sum / Float(placements.count)
        piece.base = base
        piece.position = SIMD3<Float>(base.x, tableY, base.y)
    }

    /// Call after the last `observe` of each frame. Drops blobs that never firmed up (a passing hand, a shadow).
    /// - Returns: the ids of the pieces dropped.
    @discardableResult
    public func endFrame(time: TimeInterval) -> [UUID] {
        var removed: [UUID] = []
        pieces.removeAll { piece in
            let drop = piece.sightings < settings.confirmAfter && time - piece.firstSeen > settings.pruneAfter
                && !matched.contains(piece.id)
            if drop { removed.append(piece.id) }
            return drop
        }
        return removed
    }

    /// How good a picture of a blob a frame is: bigger and nearer the middle of the frame is better.
    public static func viewQuality(of blob: DetectedBlob, frameWidth: Int, frameHeight: Int) -> Float {
        let centerX = Float(frameWidth) / 2, centerY = Float(frameHeight) / 2
        let maxCenterDistance = (centerX * centerX + centerY * centerY).squareRoot()
        guard maxCenterDistance > 0 else { return 0 }
        let dx = blob.cx - centerX, dy = blob.cy - centerY
        return Float(blob.area) * (1 - 0.5 * (dx * dx + dy * dy).squareRoot() / maxCenterDistance)
    }

    /// On-device recognition: whether another view of this piece from here is worth classifying.
    public func shouldClassify(_ piece: TrackedPiece, cameraPosition: SIMD3<Float>) -> Bool {
        guard isConfirmed(piece), piece.deviceViews < settings.deviceViewsPerPiece else { return false }
        if let last = piece.lastDeviceCamera {
            return TableMath.distance(last, cameraPosition) >= settings.deviceViewBaseline
        }
        return true
    }

    /// Server recognition: whether to send this frame's picture of the piece.
    ///
    /// - Parameter quality: this frame's `PieceObservation.quality` for the piece.
    public func shouldSubmit(_ piece: TrackedPiece, quality: Float, cameraPosition: SIMD3<Float>) -> Bool {
        guard isConfirmed(piece), piece.failures < settings.maxFailures,
              piece.views + piece.inFlight < settings.viewsPerPiece else { return false }
        // Wait for a reasonably good picture, but not forever.
        guard quality >= piece.bestQuality * 0.6 || piece.sightings >= 10 else { return false }
        if let last = piece.lastSubmitCamera {
            return TableMath.distance(last, cameraPosition) >= settings.secondViewBaseline
        }
        return true
    }
}
