import Foundation

// How ScanEngine uses this:
//
//     private var stills = StillRequests()
//
//     // a piece the model stays unsure of (SecondOpinion.shouldRequest): wait for a still instead of sending its thumbnail
//     if stills.want(piece.id, time: time) { ... } else { send the thumbnail as before }
//     // after the frame's pieces:
//     for id in stills.expired(time: time) { send that piece's thumbnail as before }
//     if stills.shouldCapture(time: time) { session.captureHighResolutionFrame { ... } }
//     // when the still arrives: for each waiting piece `StillCrop.square` finds in it, classify that crop, send it for
//     // the second opinion, and `stills.captured(served:)`; on an error `stills.failed(permanently:)`.

/// Which pieces are waiting for a full-resolution still, and when the next one may be asked for.
///
/// At most one still every `minInterval` seconds (each costs ARKit a brief pause of the video and about 50 MB of
/// memory while it is handled); one still serves every waiting piece it shows. A piece waits at most `maxWait` seconds,
/// then gets its second opinion from its best video crop as before.
public struct StillRequests {
    public struct Settings {
        public var minInterval: TimeInterval = 2
        public var maxWait: TimeInterval = 4
        public init() {}
    }

    public let settings: Settings
    public private(set) var waiting: [UUID: TimeInterval] = [:]
    /// Pieces that had their still, or gave up waiting: never asked for again.
    public private(set) var done = Set<UUID>()
    public private(set) var inFlight = false
    /// False once the session has said it cannot capture stills (an unsupported video format, say).
    public private(set) var available = true
    private var lastRequest = -TimeInterval.infinity

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public mutating func reset() {
        waiting.removeAll()
        done.removeAll()
        inFlight = false
        lastRequest = -.infinity
        // `available` is kept: it is a property of the session's configuration.
    }

    /// Ask for a still of this piece. False if stills are not available or the piece already had its turn: then use
    /// the video crop straight away.
    public mutating func want(_ id: UUID, time: TimeInterval) -> Bool {
        guard available, !done.contains(id) else { return false }
        if waiting[id] == nil { waiting[id] = time }
        return true
    }

    public func isWaiting(_ id: UUID) -> Bool { waiting[id] != nil }

    /// Whether to capture a still now; if so, it is marked as under way.
    public mutating func shouldCapture(time: TimeInterval) -> Bool {
        guard available, !inFlight, !waiting.isEmpty, time - lastRequest >= settings.minInterval else { return false }
        inFlight = true
        lastRequest = time
        return true
    }

    /// The still arrived; these waiting pieces were found in it and are done.
    public mutating func captured(served: Set<UUID>) {
        inFlight = false
        for id in served where waiting.removeValue(forKey: id) != nil { done.insert(id) }
    }

    /// The still failed. `permanently`: the session cannot capture stills, so every waiting piece is handed back.
    /// - Returns: the pieces to send with their video crops now.
    public mutating func failed(permanently: Bool) -> [UUID] {
        inFlight = false
        guard permanently else { return [] }
        available = false
        let ids = waiting.keys.sorted { $0.uuidString < $1.uuidString }
        for id in ids { done.insert(id) }
        waiting.removeAll()
        return ids
    }

    /// Pieces that have waited too long: they are done waiting; send them with their video crops.
    public mutating func expired(time: TimeInterval) -> [UUID] {
        let ids = waiting.filter { time - $0.value > settings.maxWait }.keys.sorted { $0.uuidString < $1.uuidString }
        for id in ids {
            waiting[id] = nil
            done.insert(id)
        }
        return ids
    }

    public mutating func forget(_ id: UUID) {
        waiting[id] = nil
        done.remove(id)
    }
}

/// Where a tracked piece is in a still taken from another viewpoint than the frames it was found in.
public enum StillCrop {
    /// A square around the piece in the still's full-resolution pixels, sized as the recognition model's training crops
    /// (the piece about 70% of the side), or nil if the square does not lie wholly inside the image.
    /// - Parameter projector: the still's camera, with intrinsics in pixels of its `imageWidth` x `imageHeight` image.
    public static func square(of piece: TrackedPiece, projector: TableProjector, imageWidth: Float, imageHeight: Float,
                              fill: Float = 0.7) -> (centreX: Float, centreY: Float, side: Float)? {
        square(position: piece.position, longMm: piece.longMm, heightMm: piece.heightMm, projector: projector,
               imageWidth: imageWidth, imageHeight: imageHeight, fill: fill)
    }

    public static func square(position: SIMD3<Float>, longMm: Float, heightMm: Float, projector: TableProjector,
                              imageWidth: Float, imageHeight: Float, fill: Float = 0.7) -> (centreX: Float, centreY: Float, side: Float)? {
        guard longMm > 0, fill > 0 else { return nil }
        // The outline's middle sits half-way up a tall piece.
        let middle = position + SIMD3<Float>(0, heightMm / 2000, 0)
        guard let seen = projector.project(middle) else { return nil }
        let side = longMm / 1000 * projector.fx / seen.depth / fill
        let half = side / 2
        guard side >= 8, seen.pixel.x - half >= 0, seen.pixel.y - half >= 0,
              seen.pixel.x + half <= imageWidth, seen.pixel.y + half <= imageHeight else { return nil }
        return (seen.pixel.x, seen.pixel.y, side)
    }
}
