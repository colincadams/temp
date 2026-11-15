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

    public init(position: SIMD3<Float>, longMm: Float, shortMm: Float, r: UInt8, g: UInt8, b: UInt8, quality: Float) {
        self.position = position
        self.longMm = longMm
        self.shortMm = shortMm
        self.r = r; self.g = g; self.b = b
        self.quality = quality
    }

    /// - Parameters:
    ///   - mmPerPixel: scale at the blob, from `TableProjector.locate`.
    public init(blob: DetectedBlob, position: SIMD3<Float>, mmPerPixel: Float, quality: Float) {
        self.init(position: position, longMm: blob.major * mmPerPixel, shortMm: blob.minor * mmPerPixel,
                  r: blob.r, g: blob.g, b: blob.b, quality: quality)
    }
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

    /// Median of the recent measurements.
    public var longMm: Float { TableMath.median(longSamples) }
    public var shortMm: Float { TableMath.median(shortSamples) }

    /// Median colour as "rrggbb".
    public var rgbHex: String {
        let r = Int(TableMath.median(rSamples)), g = Int(TableMath.median(gSamples)), b = Int(TableMath.median(bSamples))
        return String(format: "%02x%02x%02x", r, g, b)
    }

    func addSample(_ observation: PieceObservation, keeping limit: Int) {
        if longSamples.count >= limit {
            longSamples.removeFirst(); shortSamples.removeFirst()
            rSamples.removeFirst(); gSamples.removeFirst(); bSamples.removeFirst()
        }
        longSamples.append(observation.longMm)
        shortSamples.append(observation.shortMm)
        rSamples.append(Float(observation.r)); gSamples.append(Float(observation.g)); bSamples.append(Float(observation.b))
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

        public init() {}
    }

    public let settings: Settings
    /// Every tracked piece, confirmed or not, oldest first.
    public private(set) var pieces: [TrackedPiece] = []
    private var matched = Set<UUID>()

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Pieces seen often enough to count.
    public var confirmed: [TrackedPiece] { pieces.filter { isConfirmed($0) } }

    public func isConfirmed(_ piece: TrackedPiece) -> Bool { piece.sightings >= settings.confirmAfter }

    public func piece(id: UUID) -> TrackedPiece? { pieces.first { $0.id == id } }

    /// Forget every piece.
    public func reset() {
        pieces.removeAll()
        matched.removeAll()
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

        let radius = max(settings.minMatchRadius, longMm / 1000 * settings.matchRadiusPerLength)
        var nearest: TrackedPiece?
        var nearestDistance = radius
        for piece in pieces where !matched.contains(piece.id) {
            let d = TableMath.distance(piece.position, observation.position)
            if d < nearestDistance { nearest = piece; nearestDistance = d }
        }
        let piece: TrackedPiece
        if let nearest {
            piece = nearest
            piece.sightings += 1
            piece.position = TableMath.mix(piece.position, observation.position, settings.positionBlend)
        } else {
            piece = TrackedPiece(position: observation.position, time: time)
            pieces.append(piece)
        }
        matched.insert(piece.id)
        piece.addSample(observation, keeping: settings.sampleLimit)
        piece.bestQuality = max(piece.bestQuality, observation.quality)
        return piece
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
