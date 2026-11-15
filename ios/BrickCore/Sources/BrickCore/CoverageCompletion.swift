import Foundation

/// Time spent sweeping over ground already covered without a new piece turning up.
///
/// Feed it every processed frame. A frame adds the time since the previous processed frame (capped, so a pause
/// or a run of rejected frames does not count) when the camera moved since that frame and the view is over
/// covered ground: the cells newly covered during the last `window` seconds are at most `maxNewShare` of the
/// cells in this view. (A single frame is not enough to tell: a slow first pass adds a new row of cells only
/// every few frames.) A newly confirmed piece starts the count again from zero.
public struct CoverageQuietTime {
    public struct Settings {
        /// Metres the camera must move between processed frames for the frame to count as sweeping.
        /// At 5 frames a second the default is 2.5 cm/s.
        public var minMove: Float = 0.005
        /// Seconds over which newly covered cells are added up.
        public var window: TimeInterval = 1
        /// Newly covered cells in the window, as a share of the cells in view, up to which the view counts as
        /// being over covered ground. A first pass at 2.5 cm/s with a 0.6 m footprint adds about 4% a second.
        public var maxNewShare: Float = 0.01
        /// Longest time one frame can add, in seconds.
        public var maxStep: TimeInterval = 0.5

        public init() {}
    }

    public let settings: Settings
    /// Quiet sweeping time so far, in seconds.
    public private(set) var seconds: TimeInterval = 0
    private var confirmed = 0
    private var lastTime: TimeInterval?
    private var lastCamera: SIMD3<Float>?
    /// Newly covered cells of recent frames, oldest first.
    private var recent: [(time: TimeInterval, newCells: Int)] = []

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public mutating func reset() {
        seconds = 0
        confirmed = 0
        lastTime = nil
        lastCamera = nil
        recent.removeAll()
    }

    /// - Parameters:
    ///   - update: what this frame added to the `CoverageMap`.
    ///   - confirmedCount: confirmed pieces after this frame.
    public mutating func record(time: TimeInterval, cameraPosition: SIMD3<Float>, update: CoverageUpdate, confirmedCount: Int) {
        let previousTime = lastTime, previousCamera = lastCamera
        lastTime = time
        lastCamera = cameraPosition
        recent.append((time, update.newCells))
        recent.removeAll { (entry: (time: TimeInterval, newCells: Int)) -> Bool in time - entry.time > settings.window }

        if confirmedCount > confirmed {
            confirmed = confirmedCount
            seconds = 0
            return
        }
        confirmed = confirmedCount   // the count can only fall if the tracker was reset without us
        guard let previousTime, let previousCamera else { return }
        let step = min(settings.maxStep, max(0, time - previousTime))
        let moved = TableMath.distance(cameraPosition, previousCamera) >= settings.minMove
        let newCells = recent.reduce(0) { (sum: Int, entry: (time: TimeInterval, newCells: Int)) -> Int in sum + entry.newCells }
        let overCovered = update.cellsInView > 0 && Float(newCells) <= settings.maxNewShare * Float(update.cellsInView)
        if moved && overCovered { seconds += step }
    }
}

/// A guess at whether a scan has found everything. A heuristic, not proof: it cannot know about pieces the camera
/// never saw well, such as ones hidden under others, outside every view, or too close in colour to the table.
public enum CompletionGuess: Equatable {
    /// No confirmed piece yet.
    case noPieces
    /// This many confirmed pieces lie in ground the camera has covered fewer than `minTimesSeen` times.
    case needsAnotherPass(pieces: Int)
    /// Every piece has been covered more than once, but sweeping has not yet been quiet for long enough.
    case stillLooking(quietSeconds: Double, neededSeconds: Double)
    /// Every confirmed piece lies in ground covered at least twice, and sweeping over covered ground has found
    /// nothing new for a while.
    case looksComplete

    public static let defaultQuietSeconds: Double = 4
    public static let defaultMinTimesSeen = 2

    public var looksComplete: Bool { self == .looksComplete }

    /// - Parameters:
    ///   - timesSeen: for each confirmed piece, how many views covered the cell it lies in
    ///     (`CoverageMap.timesSeen(at:)`).
    ///   - quietSeconds: `CoverageQuietTime.seconds`.
    public static func assess(timesSeen: [Int], quietSeconds: Double,
                              neededSeconds: Double = defaultQuietSeconds,
                              minTimesSeen: Int = defaultMinTimesSeen) -> CompletionGuess {
        guard !timesSeen.isEmpty else { return .noPieces }
        let thin = timesSeen.filter { $0 < minTimesSeen }.count
        if thin > 0 { return .needsAnotherPass(pieces: thin) }
        if quietSeconds < neededSeconds { return .stillLooking(quietSeconds: quietSeconds, neededSeconds: neededSeconds) }
        return .looksComplete
    }
}
