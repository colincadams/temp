import Foundation

/// ARKit's map drift and a map correction (a loop closure), simulated on a rendered sweep, and the app's anchors that
/// follow the correction.
///
/// The model. ARKit's estimate of the world drifts from the true one as the camera travels, so every camera pose it
/// reports is `D * true pose`, and every piece the app places lands at `D * true position`. D is a sideways shift on the
/// table and a slight turn about the vertical (`yawPerMetre` per metre of shift) about the sweep's start, made of:
/// - the drift already built up when the sweep starts (`initialDrift`): a rendered sweep is two rows and 65 cm of
///   travel, far too short to build up the centimetre or two a long scan does, so it starts as if the phone had already
///   travelled a few metres (it came from the far end of a big table, say);
/// - background drift, `perMetre` (1%) of the camera's travel during the sweep;
/// - the correction: at `correctionFrame` (the first frame of the second row by default) ARKit refines its map (a loop
///   closure, say) and D drops back to the identity; background drift then starts again from zero.
/// Anchors stay put in the reported world between corrections, as ARKit's do; at the correction ARKit moves each anchor
/// to where its piece of the scene now is, `D_after * true pose`, give or take `anchorNoise`.
///
/// Without anchors, the first row's pieces stay where the drifted world put them, and from the correction on, new
/// detections of them land up to the drift away: beyond the match radius (half the piece's length, at least 1 cm) a
/// piece is counted twice. With anchors (`ReplayRunner.Settings.anchoring`, as `ScanEngine` does) each piece is carried
/// with the anchor it was stored against (`AnchorSet`). Not modelled: a correction that comes some frames after the
/// camera is back over old ground. In those frames the tracker would start second tracks, and nothing but ARKit's own
/// correction can stop that.
public struct DriftSimulation {
    public struct Settings {
        /// Drift already built up when the sweep starts (metres).
        public var initialDrift: Float = 0.02
        /// Sweep frame at which ARKit corrects its map; nil for the middle frame (the first of a rendered sweep's second row).
        public var correctionFrame: Int?
        /// Background drift per metre of camera travel.
        public var perMetre: Float = 0.01
        /// Direction of the shift on the table, radians from world +x.
        public var direction: Float = 0.5
        /// Turn about the vertical per metre of shift (radians): 0.25 degrees per centimetre.
        public var yawPerMetre: Float = 0.25 * Float.pi / 180 * 100
        /// Error of each anchor after the correction: up to this far (metres), and up to a tenth of a degree.
        public var anchorNoise: Float = 0.0005
        public var seed: UInt64 = 7
        public init() {}
    }

    public let settings: Settings
    public let correctionFrame: Int
    private let pivot: SIMD3<Float>
    private var travelled: Float = 0
    private var lastCamera: SIMD3<Float>?
    private var random: ReplayRunner.SeededRandom
    /// The current drift: reported = drift * true.
    public private(set) var drift = Matrix4.identity
    public private(set) var corrected = false

    /// Simulated ARKit anchors: their true poses, and where ARKit currently reports them.
    public private(set) var trueAnchors: [UUID: Matrix4] = [:]
    public private(set) var reportedAnchors: [UUID: Matrix4] = [:]

    public init(sweep: ReplaySweep, settings: Settings = Settings()) {
        self.settings = settings
        correctionFrame = settings.correctionFrame ?? sweep.frames.count / 2
        let first = sweep.frames.first.flatMap { sweep.projector($0)?.cameraPosition } ?? .zero
        pivot = SIMD3(first.x, sweep.tableY, first.z)
        random = ReplayRunner.SeededRandom(state: settings.seed)
    }

    /// Advance to a sweep frame whose true camera position is `camera` (call for every frame, in order).
    /// - Returns: true if ARKit corrects its map at this frame.
    @discardableResult
    public mutating func advance(frame index: Int, camera: SIMD3<Float>) -> Bool {
        if let lastCamera {
            travelled += TableMath.distance(SIMD3(camera.x, 0, camera.z), SIMD3(lastCamera.x, 0, lastCamera.z))
        }
        lastCamera = camera
        var correctedNow = false
        if index >= correctionFrame && !corrected {
            corrected = true
            correctedNow = true
            travelled = 0
        }
        var amount = settings.perMetre * travelled
        if !corrected { amount += settings.initialDrift }
        let shift = SIMD3<Float>(cos(settings.direction), 0, sin(settings.direction)) * amount
        drift = .yaw(settings.yawPerMetre * amount, about: pivot, then: shift)
        if correctedNow {
            for id in trueAnchors.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                let truth = trueAnchors[id]!
                let noise = Matrix4.yaw(uniform(0.1) * Float.pi / 180, about: truth.translationPart,
                                        then: SIMD3(uniform(settings.anchorNoise), 0, uniform(settings.anchorNoise)))
                reportedAnchors[id] = noise * drift * truth
            }
        }
        return correctedNow
    }

    /// The camera ARKit reports for a true camera-to-world transform.
    public func reported(_ camera: Matrix4) -> Matrix4 { drift * camera }

    /// The app adds an anchor at `transform` in the reported world.
    public mutating func addAnchor(_ id: UUID, transform: Matrix4) {
        reportedAnchors[id] = transform
        trueAnchors[id] = drift.rigidInverse * transform
    }

    /// Uniform in [-a, a].
    private mutating func uniform(_ a: Float) -> Float { random.uniform(-a, a) }
}
