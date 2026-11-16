import ARKit
import AVFoundation
import BrickCore
import Combine
import CoreImage
import simd
import UIKit

/// Turns a sweep of the camera over a table into a list of identified pieces.
///
/// For each processed camera frame:
/// 1. check tracking is normal (or say why not, and wait for ARKit to relocalise after an interruption:
///    `TrackingRecovery`), find the table plane and check the phone is facing it and moving slowly enough;
/// 2. skip the frame if it is much blurrier than the recent ones (`SharpnessGate`);
/// 3. detect every fully visible piece (`InstanceDetector` when its model is bundled, else `PieceDetector`), leaving out
///    detections under the user's hand (ARKit person segmentation, `HandMasking`);
/// 4. carry every known piece by the corrections ARKit has made to its map since the last frame (each piece is stored
///    against an `ARAnchor` made near it: `AnchorSet`, `PieceAnchoring`);
/// 5. project each detection onto the table to get its real-world position and size (`TableProjector`), match it to a
///    piece already seen at that spot or start tracking a new one (`PieceTracker`), and note which pieces the camera
///    looked at without finding (`VisibilityLedger`) and which were found together (`ObservationLog`);
/// 6. recognise each piece. With a bundled model (`PartClassifier`) this happens on the phone from many viewpoints,
///    fused with the piece's measured size (`ShapeFusion`), the sharpest views counting most (`SharpnessGate.viewFactor`);
///    a piece the model stays unsure of gets a full-resolution still (`StillRequests`), whose crop is classified too and
///    sent to the server once for a second opinion (`SecondOpinion`). Names, pictures and colours come from the bundled
///    class file when it has them (`OfflineCatalog`, `ColorRanking`), so a scan can be finished without a connection;
///    the server's description replaces them when it arrives. Without a model, two crops of each piece are sent to the
///    server.
/// 7. add what the camera saw well to the coverage map (`CoverageMap`) and guess whether the scan has found
///    everything (`CompletionGuess`), for the map on the scan screen.
/// When the user opens Review, tracks that are probably one piece counted twice are merged (`finishForReview`,
/// `TrackConsolidation`). Pieces the camera keeps looking at without finding are left out of the count, the map and the
/// review until they are seen again.
///
/// Everything that is not camera, Core ML or publishing lives in the BrickCore package, where it is unit-tested.
final class ScanEngine: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {

    // MARK: Published (main thread)

    @Published private(set) var pieces: [PieceSnapshot] = []
    @Published private(set) var hint = "Point the phone at the table"
    @Published private(set) var tableFound = false
    @Published private(set) var lastError: String?
    @Published var torchOn = false { didSet { applyTorch() } }
    /// Where the camera has looked, the pieces and the phone, for the map on the scan screen.
    @Published private(set) var coverage = CoverageSnapshot.empty
    /// ARKit could not find where the scan left off after an interruption: offer `startFreshPass()`.
    @Published private(set) var offerFreshPass = false
    /// Set when the room is too dark for a short shutter: the scan works, but pictures may blur. Suggests the light.
    @Published private(set) var lightAdvice: String?

    let session = ARSession()

    // MARK: Tuning

    private let workWidth = 640                 // detection runs on a frame downsampled to about this width
    private let frameInterval: TimeInterval = 0.2
    private let maxSpeed: Float = 0.30          // m/s; faster than this blurs small pieces
    private let minDownwardTilt: Float = 0.80   // cosine of the largest allowed angle from straight down
    private let maxConcurrentRequests = 3
    private let deviceViewsPerFrame = 12         // keeps frame processing responsive on a crowded table
    private let resolveAfterViews = 3            // views before asking the server for names and colours
    private let coverageInset: Float = 0.05      // share of each image edge left out of coverage (pieces cut by it are ignored)
    /// Pieces per frame whose region sharpness is measured (about 8 microseconds each); the rest count as sharp.
    private let sharpViewsPerFrame = 100
    /// Exposure is fixed once it has stopped adjusting for this long with the table in view.
    private let exposureSettleTime: TimeInterval = 0.5
    // Sightings to confirm a piece, views per piece and the distances between them: `PieceTracker.Settings`.

    // MARK: State (confined to `queue`)

    private struct Job {
        enum Work {
            /// The server recognises the crop. `secondOpinion`: the phone's model has already had its say.
            case identify(jpeg: Data, longMm: Float, secondOpinion: Bool)
            /// The server supplies names, images and colours.
            case describe(partNums: [String])
        }
        let pieceID: UUID
        let rgbHex: String
        let work: Work
    }

    private let queue = DispatchQueue(label: "brickscan.engine", qos: .userInitiated)
    private let ciContext = CIContext()
    private lazy var classifier = PartClassifier(context: ciContext)
    private lazy var instanceDetector = InstanceDetector()
    private let tracker = PieceTracker()
    /// Negative evidence. Its miss rate must match the detector in use (measured by brick-replay, ml/README.md): the
    /// trained detector misses under 1% of pieces in plain view on rendered tables (99.1% found standing apart, 94.7%
    /// touching), so the ledger's 0.2 leaves room for real photos; the colour threshold, which merges touching pieces,
    /// missed 59-76% of the pieces in view in the replays, so 0.6.
    private lazy var visibility: VisibilityLedger = {
        var settings = VisibilityLedger.Settings()
        settings.detectorMissRate = instanceDetector == nil ? 0.6 : 0.2
        return VisibilityLedger(settings: settings)
    }()
    private var sharpness = SharpnessGate()
    /// Which pieces each processed frame matched, for the clean-up when Review is opened.
    private var observationLog = ObservationLog()
    /// Pieces merged into another by the last clean-up, and the piece each now belongs to.
    private var absorbed: [UUID: UUID] = [:]
    /// The anchors the engine made, and which anchor each piece is stored against.
    private var anchorSet = AnchorSet()
    private var anchoring = PieceAnchoring()
    private var recovery = TrackingRecovery()
    private var stills = StillRequests()
    /// High-resolution captures that failed in a row; after three the session is taken not to support them.
    private var stillFailures = 0
    /// Whether ARKit's person segmentation is on in the running configuration.
    private var personSegmentation = false
    /// What the server has told us about parts, per tracked piece: name, picture and colour ranking by part number.
    private var info: [UUID: [String: Candidate]] = [:]
    /// The server's answer for pieces sent for a second opinion, best first.
    private var serverOpinions: [UUID: [Candidate]] = [:]
    /// Candidates described from the bundled class file (no server needed), by part number and measured colour.
    private var offlineCandidates: [String: Candidate] = [:]
    private var jobs: [Job] = []
    private var activeRequests = 0
    private var generation = 0
    private var scanning = false
    private var lastProcessed: TimeInterval = 0
    private var lastCameraPosition: SIMD3<Float>?
    private var lastCameraTime: TimeInterval = 0
    private var tableAnchorID: UUID?
    private var tableY: Float?
    private var whiteBalanceLocked = false
    /// Exposure: when it last started holding still with the table in view, and whether it has been fixed since.
    private var exposureSteadySince: TimeInterval?
    private var exposureFixed = false
    private var coverageMap = CoverageMap()
    private var quietTime = CoverageQuietTime()
    /// `coverageMap`'s cells as the map draws them, rebuilt when a frame adds to the map.
    private var coverageCells: [CoverageSnapshot.Cell] = []
    /// Which way the top of the phone points, on the table; updated every frame.
    private var lastHeading: SIMD2<Float>?
    /// Confirmed pieces already announced with a haptic tick.
    private var announced = Set<UUID>()
    private let haptics = HapticTicker()

    // MARK: Configuration (main thread)

    /// How much of the preferred configuration to give up after ARKit refused it (`session(_:didFailWithError:)`):
    /// 0 everything, 1 without person segmentation, 2 also without the 4K video format.
    private var fallbackLevel = 0
    private var configuration: ARWorldTrackingConfiguration?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    // MARK: Control (call on the main thread)

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            hint = "This device does not support AR tracking."
            return
        }
        let config = ScanEngine.makeConfiguration(fallbackLevel: fallbackLevel)
        configuration = config
        session.run(config)
        let segmentation = config.frameSemantics.contains(.personSegmentation)
        queue.async {
            self.personSegmentation = segmentation
            self.scanning = true
        }
    }

    /// The session's configuration.
    ///
    /// - Video: the 4K format when the phone has one. Detection runs on a 640-wide copy either way, but recognition
    ///   classifies a crop of every piece from up to 8 views, and 4K gives it about twice the pixels per piece of the
    ///   1920 x 1440 format ARKit recommends for high-resolution stills (a 1 x 2 plate at 30 cm: about 160 pixels long
    ///   against 77). Uncertain pieces still get a full-resolution still on demand (`captureHighResolutionFrame`, which
    ///   delivers the best still the running format supports), so the stream is chosen for the many and the still for
    ///   the few. If a phone cannot capture stills with 4K, the capture fails, `StillRequests` stops asking, and those
    ///   pieces go to the server with their best video crop as before.
    /// - Depth: LiDAR phones get the smoothed scene depth, for piece heights.
    /// - Person segmentation, to keep hands out of the scan: added only where ARKit says it supports it together with
    ///   the depth semantics (`supportsFrameSemantics` with both). Where it does not, a LiDAR phone keeps depth and goes
    ///   without hand masking (a hand that becomes a phantom is still set aside by negative evidence once the camera
    ///   sees the spot empty); phones without LiDAR use person segmentation.
    private static func makeConfiguration(fallbackLevel: Int) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.isAutoFocusEnabled = true
        if fallbackLevel < 2, let format = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            config.videoFormat = format   // more pixels per piece for recognition
        }
        // LiDAR phones: depth tells how tall each piece is, for placing and measuring it. The smoothed stream is
        // ARKit's depth averaged over the last few frames: steadier on a still table, which is all a sweep looks at.
        // Without LiDAR the tracker works out heights from how pieces seem to slide as the phone moves.
        var semantics: ARConfiguration.FrameSemantics = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            semantics.insert(.sceneDepth)
        }
        if fallbackLevel < 1 {
            var withPeople = semantics
            withPeople.insert(.personSegmentation)
            if ARWorldTrackingConfiguration.supportsFrameSemantics(withPeople) { semantics = withPeople }
        }
        config.frameSemantics = semantics
        return config
    }

    func pause() {
        queue.async {
            self.scanning = false
            self.unlockCamera()
        }
        session.pause()
        if torchOn { torchOn = false }
    }

    /// Forget every piece and start a fresh scan.
    func reset() {
        queue.async {
            self.generation += 1
            self.tracker.reset()
            self.info.removeAll()
            self.serverOpinions.removeAll()
            self.offlineCandidates.removeAll()
            self.jobs.removeAll()
            self.coverageMap.reset()
            self.quietTime.reset()
            self.coverageCells.removeAll()
            self.announced.removeAll()
            self.sharpness.reset()
            self.visibility.reset()
            self.observationLog.reset()
            self.absorbed.removeAll()
            self.anchorSet.reset()
            self.anchoring.reset()
            self.stills.reset()
            self.publish(hint: nil)
        }
        lastError = nil
    }

    /// After ARKit failed to find where the scan left off: keep every piece found so far for the review, and scan on with
    /// a new map. The coverage map starts again; new detections are never matched to the earlier pieces, whose positions
    /// belong to the old map.
    func startFreshPass() {
        guard let config = configuration else { return }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        offerFreshPass = false
        queue.async {
            for id in self.tracker.startNewPass() { self.forget(id) }
            self.coverageMap.reset()
            self.quietTime.reset()
            self.coverageCells.removeAll()
            self.anchorSet.reset()
            self.anchoring.reset()
            self.sharpness.reset()
            self.tableAnchorID = nil
            self.tableY = nil
            self.lastCameraPosition = nil
            self.recovery.startedFreshPass()
            self.publish(hint: "Fresh pass: sweep over the table again. The pieces found so far are kept.")
        }
    }

    /// The user would rather wait for ARKit to find its place than start a fresh pass.
    func keepTryingToRelocalise() {
        offerFreshPass = false
        queue.async { self.recovery.keepTrying() }
    }

    /// The pieces to review: runs the end-of-scan clean-up (tracks that are one piece counted twice are merged) and
    /// returns the list without pieces set aside or merged away. Call on the main thread when Review is opened; it waits
    /// for the frame being processed, if any.
    func finishForReview() -> [PieceSnapshot] {
        var result: [PieceSnapshot] = []
        queue.sync {
            let merged = consolidate()
            result = snapshots()
            publish(hint: merged > 0 ? "Merged \(merged) \(merged == 1 ? "piece" : "pieces") counted twice." : nil)
        }
        pieces = result
        return result
    }

    private var captureDevice: AVCaptureDevice? {
        ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
    }

    private func applyTorch() {
        guard let device = captureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchOn ? .on : .off
            device.unlockForConfiguration()
        } catch {}
        // The light changes the scene's brightness and colour: let exposure and white balance settle again, then fix them.
        queue.async {
            guard self.scanning else { return }
            self.unlockCamera()
        }
        if torchOn { lightAdvice = nil }
    }

    /// Freeze white balance once the table is in view so piece colours stay comparable across the sweep.
    private func lockWhiteBalance() {
        guard !whiteBalanceLocked, let device = captureDevice else { return }
        whiteBalanceLocked = true
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()
        } catch {}
    }

    /// Fix the exposure once it has settled on the table, so brightness (and so measured colour) stays the same across
    /// the sweep, with a shutter short enough that a sweep at the fastest allowed speed smears under 2 working pixels:
    /// `ExposurePlan` (about 4.3 ms, 1/230 s, for the wide camera at 30 cm). If the auto exposure is already that short it
    /// is simply locked; if not, the shutter is shortened and the ISO raised to keep the brightness; if that would take
    /// the ISO over 1000, the room is too dark: auto exposure stays on and the light is suggested.
    private func fixExposure(frame: ARFrame, time: TimeInterval, cameraHeight: Float) {
        guard !exposureFixed, let device = captureDevice else { return }
        if device.isAdjustingExposure {
            exposureSteadySince = nil
            return
        }
        guard let since = exposureSteadySince else {
            exposureSteadySince = time
            return
        }
        guard time - since >= exposureSettleTime else { return }
        exposureFixed = true

        let fx = frame.camera.intrinsics[0][0]
        let step = max(1, CVPixelBufferGetWidth(frame.capturedImage) / workWidth)
        let longest = ExposurePlan.longestExposure(fx: fx, step: step, distance: cameraHeight)
        let format = device.activeFormat
        let decision = ExposurePlan.decide(duration: CMTimeGetSeconds(device.exposureDuration), iso: device.iso, longest: longest,
                                           minDuration: CMTimeGetSeconds(format.minExposureDuration),
                                           minISO: format.minISO, maxISO: format.maxISO)
        var advice: String?
        do {
            try device.lockForConfiguration()
            switch decision {
            case .lock:
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            case .custom(let duration, let iso):
                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000), iso: iso,
                                                 completionHandler: nil)
                } else if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
            case .tooDark:
                advice = device.hasTorch ? "It is too dark for sharp pictures. Turn on the light." : "It is too dark for sharp pictures."
            }
            device.unlockForConfiguration()
        } catch {}
        DispatchQueue.main.async { self.lightAdvice = advice }
    }

    /// Give white balance and exposure back to the camera (on `queue`); they are fixed again once the table is in view.
    private func unlockCamera() {
        whiteBalanceLocked = false
        exposureFixed = false
        exposureSteadySince = nil
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: ARSessionDelegate (called on `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let time = frame.timestamp
        let camera = frame.camera.transform
        let position = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)

        // Camera speed, measured on every frame.
        var speed: Float = 0
        if let last = lastCameraPosition, time > lastCameraTime {
            speed = TableMath.distance(position, last) / Float(time - lastCameraTime)
        }
        lastCameraPosition = position
        lastCameraTime = time
        lastHeading = ScanEngine.heading(of: camera)

        let condition = ScanEngine.condition(of: frame.camera.trackingState)
        let offering = recovery.offerFreshPass
        recovery.update(condition, time: time)
        if recovery.offerFreshPass != offering {
            let offer = recovery.offerFreshPass
            DispatchQueue.main.async { self.offerFreshPass = offer }
        }

        guard scanning, time - lastProcessed >= frameInterval else { return }
        lastProcessed = time

        // While tracking is limited, or ARKit has not yet found its place after an interruption, nothing is matched:
        // the world may be shifted.
        guard recovery.canMatch(condition) else {
            publish(hint: recovery.hint(condition) ?? "Finding its bearings. Move the phone slowly.")
            return
        }
        guard let tableY = locateTable(frame: frame, cameraPosition: position) else {
            publish(hint: "Looking for the table. Point the phone down at it.")
            return
        }
        lockWhiteBalance()
        fixExposure(frame: frame, time: time, cameraHeight: position.y - tableY)

        let forward = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        guard forward.y < -minDownwardTilt else {
            publish(hint: "Hold the phone flat, facing straight down.")
            return
        }
        guard speed <= maxSpeed else {
            publish(hint: "Slow down a little.")
            return
        }

        process(frame: frame, tableY: tableY, cameraPosition: position, time: time)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // A configuration this phone cannot run (an unusual combination of video format and frame semantics): try again
        // with less of it, person segmentation first, then the 4K format.
        if let arError = error as? ARError, arError.code == .unsupportedConfiguration {
            DispatchQueue.main.async {
                guard self.fallbackLevel < 2 else { return }
                self.fallbackLevel += 1
                self.start()
            }
            return
        }
        publish(hint: "Camera tracking failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        queue.async {
            self.recovery.interrupted()
            self.publish(hint: "Camera paused.")
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        queue.async {
            self.recovery.interruptionEnded()
            // The camera may have been reconfigured meanwhile: fix exposure and white balance again once settled.
            self.unlockCamera()
            self.publish(hint: TrackingRecovery.hint(for: .relocalizing))
        }
    }

    /// After an interruption, ask ARKit to find its place in the map it had, so the pieces found so far stay valid.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    private static func condition(of state: ARCamera.TrackingState) -> TrackingCondition {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .excessiveMotion: return .excessiveMotion
            case .insufficientFeatures: return .insufficientFeatures
            case .relocalizing: return .relocalizing
            @unknown default: return .initializing
            }
        }
    }

    // MARK: Table plane

    /// Height of the table surface in world space, or nil until ARKit has found a horizontal plane under the camera.
    private func locateTable(frame: ARFrame, cameraPosition origin: SIMD3<Float>) -> Float? {
        if let id = tableAnchorID, let anchor = frame.anchors.first(where: { $0.identifier == id }) {
            tableY = anchor.transform.columns.3.y
            return tableY
        }
        let camera = frame.camera.transform
        let forward = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        var best: (anchor: ARPlaneAnchor, distance: Float)?
        if forward.y < -0.1 {
            for anchor in frame.anchors {
                guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { continue }
                let y = plane.transform.columns.3.y
                guard y < origin.y - 0.08 else { continue }           // must be below the phone
                let t = (y - origin.y) / forward.y
                let hit = origin + forward * t
                let local = plane.transform.inverse * SIMD4<Float>(hit.x, hit.y, hit.z, 1)
                let extent = plane.planeExtent
                guard abs(local.x - plane.center.x) <= extent.width / 2 + 0.05,
                      abs(local.z - plane.center.z) <= extent.height / 2 + 0.05 else { continue }
                if best == nil || t < best!.distance { best = (plane, t) }
            }
        }
        if let best {
            tableAnchorID = best.anchor.identifier
            tableY = best.anchor.transform.columns.3.y
        }
        return tableY   // keeps the last known height if ARKit merged the plane away
    }

    // MARK: Anchors

    /// Carry every piece whose anchor ARKit has moved since the last frame (a map correction) by the same motion, so it
    /// is matched where the corrected world now puts it.
    private func applyAnchorCorrections(frame: ARFrame, cameraPosition: SIMD3<Float>) {
        anchorSet.moveCamera(to: cameraPosition)
        var current: [UUID: Matrix4] = [:]
        for anchor in frame.anchors where anchorSet.owns(anchor.identifier) {
            current[anchor.identifier] = ScanEngine.matrix(anchor.transform)
        }
        for correction in anchoring.corrections(current: current) {
            for id in correction.pieces {
                guard let piece = tracker.piece(id: id) else { continue }
                tracker.move(piece, by: correction.motion)
            }
        }
    }

    /// Store each new piece against a recent anchor near it, adding one to the session where there is none.
    private func anchorNewPieces(_ matched: [TrackedPiece?], tableY: Float) {
        for piece in matched.compactMap({ $0 }) where anchoring.anchorOf[piece.id] == nil {
            if let id = anchorSet.anchor(for: piece.position), let transform = anchoring.applied[id] {
                anchoring.bind(piece: piece.id, to: id, transform: transform)
                continue
            }
            let transform = anchorSet.anchorTransform(for: piece.position, tableY: tableY)
            let anchor = ARAnchor(name: "brickscan.piece", transform: ScanEngine.simdMatrix(transform))
            // Its identifier exists from now on; ARKit reports its transform in the frames after it is added.
            let session = self.session
            DispatchQueue.main.async { session.add(anchor: anchor) }
            anchorSet.register(anchor.identifier, at: transform)
            anchoring.bind(piece: piece.id, to: anchor.identifier, transform: transform)
        }
    }

    private static func matrix(_ m: simd_float4x4) -> Matrix4 {
        Matrix4(m.columns.0, m.columns.1, m.columns.2, m.columns.3)
    }

    private static func simdMatrix(_ m: Matrix4) -> simd_float4x4 {
        simd_float4x4(columns: (m.columns.0, m.columns.1, m.columns.2, m.columns.3))
    }

    // MARK: Frame processing

    private func process(frame: ARFrame, tableY: Float, cameraPosition: SIMD3<Float>, time: TimeInterval) {
        let buffer = frame.capturedImage
        guard let work = ScanEngine.downsample(buffer, targetWidth: workWidth) else {
            publish(hint: "Unsupported camera format.")
            return
        }
        // A frame much blurrier than the last few (a jerk of the hand) is not used at all.
        let score = Sharpness.frameScore(rgba: work.rgba, width: work.width, height: work.height)
        guard sharpness.admit(score) else {
            publish(hint: "Hold the phone steady.")
            return
        }
        let resolution = frame.camera.imageResolution
        let imageWidth = Float(resolution.width), imageHeight = Float(resolution.height)

        // The trained detector splits touching pieces; without it, only pieces standing apart are separated.
        let detected = instanceDetector?.detect(rgba: work.rgba, width: work.width, height: work.height)
            ?? PieceDetector.detect(rgba: work.rgba, width: work.width, height: work.height)
        // A hand in view is not a piece, and a piece under it is not measured right.
        let mask = personSegmentation ? ScanEngine.personMask(of: frame) : nil
        let handFiltered = HandMasking.filter(detected, mask: mask, step: work.step, imageWidth: imageWidth, imageHeight: imageHeight)
        let blobs = handFiltered.kept

        let k = frame.camera.intrinsics
        let c = frame.camera.transform.columns
        let projector = TableProjector(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                                       camera: Matrix4(c.0, c.1, c.2, c.3), tableY: tableY)

        // LiDAR depth, when the phone has it: each piece's height, so the tracker places it by the table point under it
        // and measures it at its own height. Without it the tracker works the height out from several views.
        let depth = ScanEngine.depthMap(of: frame)

        // Move the pieces found so far by whatever corrections ARKit has made to its map, before matching.
        applyAnchorCorrections(frame: frame, cameraPosition: cameraPosition)

        tracker.beginFrame()
        var deviceBudget = deviceViewsPerFrame
        // Real position and size of each detection on the table.
        var seen: [(blob: DetectedBlob, observation: PieceObservation)] = []
        for (index, blob) in blobs.enumerated() {
            guard let spot = projector.locate(workX: blob.cx, workY: blob.cy, step: Float(work.step)) else { continue }
            var quality = PieceTracker.viewQuality(of: blob, frameWidth: work.width, frameHeight: work.height)
            // Sharp views count most, so the thumbnail and the crops sent for recognition come from sharp frames.
            if index < sharpViewsPerFrame {
                let region = Sharpness.regionScore(rgba: work.rgba, width: work.width, height: work.height, blob: blob)
                quality *= sharpness.viewFactor(region)
            }
            var depthHeight: Float?
            if let depth {
                depthHeight = DepthHeight.heightMm(map: depth, blob: blob, step: Float(work.step), imageWidth: imageWidth,
                                                   imageHeight: imageHeight, projector: projector)
            }
            let observation = PieceObservation(blob: blob, position: spot.position, mmPerPixel: spot.mmPerPixel, quality: quality,
                                               cameraPosition: cameraPosition, depthHeightMm: depthHeight)
            seen.append((blob, observation))
        }
        // Same spot as a piece we already know, or a new one? Matching the whole frame at once, closest pairs first,
        // stops a newly visible piece from taking over a neighbour's track (which would count the neighbour twice).
        let matchedPieces = tracker.observe(frame: seen.map { $0.observation }, time: time)
        let matchedIDs = matchedPieces.compactMap { $0?.id }

        // Negative evidence: pieces whose spot this frame showed well, yet nothing was found there. A piece under the
        // user's hand was not looked at. Only the current pass's pieces are in this world.
        let current = tracker.currentPieces
        let occluded = HandMasking.occluded(pieces: current, projector: projector, mask: mask,
                                            imageWidth: imageWidth, imageHeight: imageHeight)
        visibility.record(view: projector, imageWidth: imageWidth, imageHeight: imageHeight, inset: coverageInset,
                          pieces: current, matched: Set(matchedIDs), occluded: occluded)
        observationLog.record(frame: matchedIDs)
        // Two tracks merged at the last review but now seen side by side are two pieces after all.
        if !absorbed.isEmpty {
            let matchedSet = Set(matchedIDs)
            for id in matchedIDs where absorbed[id].map({ matchedSet.contains($0) }) == true { absorbed[id] = nil }
        }
        anchorNewPieces(matchedPieces, tableY: tableY)

        for (index, entry) in seen.enumerated() {
            guard let piece = matchedPieces[index] else { continue }
            let blob = entry.blob
            let quality = entry.observation.quality

            if let classifier {
                if deviceBudget > 0, tracker.shouldClassify(piece, cameraPosition: cameraPosition),
                   let logProbabilities = classifier.classify(squareCrop(buffer, blob: blob, step: work.step)) {
                    deviceBudget -= 1
                    piece.addDeviceView(logProbabilities: logProbabilities, cameraPosition: cameraPosition)
                    if quality >= piece.thumbnailQuality, let jpeg = crop(buffer, blob: blob, step: work.step) {
                        piece.thumbnail = jpeg
                        piece.thumbnailQuality = quality
                    }
                }
                let shapes = fusedShapes(piece, classifier: classifier)
                requestDescriptions(for: piece, shapes: shapes)
                if SecondOpinion.shouldRequest(topProbability: shapes.first?.probability, views: piece.deviceViews,
                                               alreadyRequested: piece.secondOpinionRequested) {
                    // Unsure after several views: wait for a full-resolution still of it (a few seconds at most),
                    // else send its best video crop.
                    if !stills.want(piece.id, time: time), let jpeg = piece.thumbnail ?? crop(buffer, blob: blob, step: work.step) {
                        requestSecondOpinion(piece, jpeg: jpeg)
                    }
                }
            } else if tracker.shouldSubmit(piece, quality: quality, cameraPosition: cameraPosition),
                      let jpeg = crop(buffer, blob: blob, step: work.step) {
                if quality >= piece.thumbnailQuality { piece.thumbnail = jpeg; piece.thumbnailQuality = quality }
                piece.inFlight += 1
                piece.lastSubmitCamera = cameraPosition
                jobs.append(Job(pieceID: piece.id, rgbHex: piece.rgbHex,
                                work: .identify(jpeg: jpeg, longMm: piece.longMm, secondOpinion: false)))
            }
        }

        // Drop blobs that never firmed up (a passing hand, a shadow).
        for id in tracker.endFrame(time: time) { forget(id) }

        // Pieces that waited too long for a still go with their video crop; then perhaps ask for a still.
        for id in stills.expired(time: time) { sendWithVideoCrop(id) }
        if stills.shouldCapture(time: time) { captureStill() }

        // What this frame saw well enough to find whole pieces in.
        let update = coverageMap.add(view: projector, imageWidth: imageWidth, imageHeight: imageHeight, inset: coverageInset)
        let counted = countable().filter { $0.pass == tracker.currentPass }
        quietTime.record(time: time, cameraPosition: cameraPosition, update: update, confirmedCount: counted.count)
        if update.cellsInView > 0 {
            let map = coverageMap
            coverageCells = map.cells.map { (entry: (key: CoverageCell, value: Int)) -> CoverageSnapshot.Cell in
                let centre = map.center(of: entry.key)
                return CoverageSnapshot.Cell(x: centre.x, z: centre.y, count: entry.value)
            }
        }

        pump()
        let hint: String
        if handFiltered.dropped > 0 {
            hint = "Keep your hand out of the picture."
        } else {
            hint = counted.isEmpty ? "Move over your pieces" : "Sweep slowly across the table"
        }
        publish(hint: hint)
    }

    /// Forget everything about a piece the tracker dropped.
    private func forget(_ id: UUID) {
        info[id] = nil
        serverOpinions[id] = nil
        visibility.forget(id)
        observationLog.forget(id)
        anchoring.forget(piece: id)
        stills.forget(id)
        absorbed[id] = nil
    }

    /// The direction on the table in which the top edge of the phone points, or nil if the phone is held on edge.
    /// The app runs in portrait, where the top of the screen is the camera's -x axis.
    private static func heading(of camera: simd_float4x4) -> SIMD2<Float>? {
        var top = SIMD2<Float>(-camera.columns.0.x, -camera.columns.0.z)
        if simd_length(top) < 0.3 {
            // Phone nearly upright: use where the camera looks instead.
            top = SIMD2<Float>(-camera.columns.2.x, -camera.columns.2.z)
        }
        let length = simd_length(top)
        return length > 0.1 ? top / length : nil
    }

    // MARK: Counting and clean-up

    /// Confirmed pieces that count: not set aside by negative evidence, not merged into another.
    private func countable() -> [TrackedPiece] {
        tracker.confirmed.filter { !visibility.isDoubtful($0.id) && absorbed[$0.id] == nil }
    }

    /// Merge tracks that are probably one piece counted twice, pass by pass (positions of different passes are in
    /// different worlds). Returns the number of merges made now.
    private func consolidate() -> Int {
        let candidates = countable()
        var merges = 0
        for pass in Set(candidates.map { $0.pass }) {
            let group = candidates.filter { $0.pass == pass }
            let result = TrackConsolidation.plan(pieces: group, log: observationLog)
            TrackConsolidation.apply(result, to: group)   // the kept piece takes the sharper thumbnail
            for (absorbedID, keptID) in result.keptFor { absorbed[absorbedID] = keptID }
            merges += result.merges.count
        }
        return merges
    }

    // MARK: On-device recognition

    /// The most likely shapes for a piece: views averaged, then weighed against its measured size.
    private func fusedShapes(_ piece: TrackedPiece, classifier: PartClassifier) -> [FusedShape] {
        ShapeFusion.fuse(logSum: piece.logSum, views: piece.deviceViews, classes: classifier.classes,
                         longMm: piece.longMm, shortMm: piece.shortMm)
    }

    /// Ask the server once for the name, picture and colour ranking of each shape in the running.
    private func requestDescriptions(for piece: TrackedPiece, shapes: [FusedShape]) {
        guard piece.deviceViews >= resolveAfterViews, piece.failures < 3 else { return }
        let wanted = shapes.map { $0.shape.partNum }.filter { !piece.requestedInfo.contains($0) }
        guard !wanted.isEmpty else { return }
        piece.requestedInfo.formUnion(wanted)
        piece.inFlight += 1
        jobs.append(Job(pieceID: piece.id, rgbHex: piece.rgbHex, work: .describe(partNums: wanted)))
    }

    /// Send a crop of a piece the phone's model is unsure of to the server, once.
    private func requestSecondOpinion(_ piece: TrackedPiece, jpeg: Data) {
        guard !piece.secondOpinionRequested else { return }
        piece.secondOpinionRequested = true
        piece.inFlight += 1
        jobs.append(Job(pieceID: piece.id, rgbHex: piece.rgbHex, work: .identify(jpeg: jpeg, longMm: piece.longMm, secondOpinion: true)))
    }

    /// A piece whose still did not come: its second opinion goes with its best video crop.
    private func sendWithVideoCrop(_ id: UUID) {
        guard let piece = tracker.piece(id: id), let jpeg = piece.thumbnail else { return }
        requestSecondOpinion(piece, jpeg: jpeg)
    }

    // MARK: Full-resolution stills

    private func captureStill() {
        let generation = self.generation
        session.captureHighResolutionFrame { [weak self] (still: ARFrame?, error: Error?) in
            guard let self else { return }
            self.queue.async { self.handleStill(still, error: error, generation: generation) }
        }
    }

    /// A full-resolution still arrived (or failed): classify each waiting piece it shows from its crop, and send that crop
    /// for the second opinion if the phone is still unsure.
    private func handleStill(_ still: ARFrame?, error: Error?, generation: Int) {
        guard let still, generation == self.generation else {
            if still == nil {
                stillFailures += 1
                // Three failures in a row: this configuration cannot capture stills. Send the waiting pieces as before.
                for id in stills.failed(permanently: stillFailures >= 3) { sendWithVideoCrop(id) }
            } else {
                stills.captured(served: [])
            }
            pump()
            return
        }
        stillFailures = 0
        guard let tableY else {
            stills.captured(served: [])
            return
        }
        let buffer = still.capturedImage
        let width = Float(CVPixelBufferGetWidth(buffer)), height = Float(CVPixelBufferGetHeight(buffer))
        // Intrinsics are for `imageResolution`; scale them should the buffer differ.
        let resolution = still.camera.imageResolution
        let scale = resolution.width > 0 ? width / Float(resolution.width) : 1
        let k = still.camera.intrinsics
        let c = still.camera.transform.columns
        let projector = TableProjector(fx: k[0][0] * scale, fy: k[1][1] * scale, cx: k[2][0] * scale, cy: k[2][1] * scale,
                                       camera: Matrix4(c.0, c.1, c.2, c.3), tableY: tableY)
        let cameraPosition = projector.cameraPosition

        var served = Set<UUID>()
        for id in stills.waiting.keys {
            guard let piece = tracker.piece(id: id), piece.pass == tracker.currentPass, !piece.secondOpinionRequested,
                  let square = StillCrop.square(of: piece, projector: projector, imageWidth: width, imageHeight: height) else { continue }
            served.insert(id)
            // The piece fills 70% of the square; the JPEG keeps an 18% margin around it, as the video crops do.
            let pieceSide = CGFloat(square.side) * 0.7
            let side = pieceSide * 1.36
            let rect = CGRect(x: CGFloat(square.centreX) - side / 2, y: CGFloat(square.centreY) - side / 2, width: side, height: side)
            let jpeg = crop(buffer, rect: rect)
            if let jpeg, piece.thumbnail == nil { piece.thumbnail = jpeg }
            var stillUnsure = true
            if let classifier {
                if let logProbabilities = classifier.classify(squareCrop(buffer, centreX: CGFloat(square.centreX),
                                                                          centreY: CGFloat(square.centreY), side: CGFloat(square.side))) {
                    piece.addDeviceView(logProbabilities: logProbabilities, cameraPosition: cameraPosition)
                }
                let top = fusedShapes(piece, classifier: classifier).first?.probability
                stillUnsure = top.map { $0 < SecondOpinion.defaultThreshold } ?? true
            }
            if stillUnsure, let jpeg = jpeg ?? piece.thumbnail {
                requestSecondOpinion(piece, jpeg: jpeg)
            } else {
                piece.secondOpinionRequested = true   // the still settled it
            }
        }
        stills.captured(served: served)
        pump()
        publish(hint: nil)
    }

    /// What to show for a piece, best match first.
    private func candidates(for piece: TrackedPiece) -> [Candidate] {
        let known = info[piece.id] ?? [:]
        guard let classifier else {
            // Server recognition: scores averaged over every answered view.
            guard piece.views > 0 else { return [] }
            return known.values
                .map { c in var c = c; c.score = piece.averageScore(c.partNum); return c }
                .sorted { $0.score > $1.score }
        }
        // The server's description when it has arrived (its picture may be fresher), else the bundled one.
        let device: [Candidate] = fusedShapes(piece, classifier: classifier).compactMap { (entry: FusedShape) -> Candidate? in
            let partNum = entry.shape.partNum
            guard var candidate = known[partNum] ?? offlineCandidate(partNum, for: piece, classifier: classifier) else { return nil }
            candidate.score = entry.probability
            return candidate
        }
        let server = serverOpinions[piece.id] ?? []
        switch SecondOpinion.choose(deviceTop: device.first?.score, serverTop: server.first?.score) {
        case .device: return device
        case .server: return server
        }
    }

    /// A candidate described on the phone from the bundled class file, with its colours ranked for the piece's
    /// measured colour as the server would rank them. Offered once the piece has had as many views as the server
    /// would be asked after, so pieces become "identified" at the same point with or without a connection.
    private func offlineCandidate(_ partNum: String, for piece: TrackedPiece, classifier: PartClassifier) -> Candidate? {
        guard piece.deviceViews >= resolveAfterViews, let offline = classifier.offline else { return nil }
        let rgbHex = piece.rgbHex
        let key = partNum + "|" + rgbHex
        if let cached = offlineCandidates[key] { return cached }
        guard let part = offline.part(partNum, measuredHex: rgbHex) else { return nil }
        let colors: [ColorInfo] = part.colors.map { (color: CatalogColor) -> ColorInfo in
            ColorInfo(id: color.id, name: color.name, rgb: color.rgb, isTrans: color.isTrans)
        }
        let candidate = Candidate(partNum: part.partNum, name: part.name, img: part.img, colors: colors, score: 0)
        if offlineCandidates.count >= 20_000 { offlineCandidates.removeAll() }   // measured colours drift; keep it bounded
        offlineCandidates[key] = candidate
        return candidate
    }

    /// True when the bundled class file describes every one of these parts, so the server is not needed for them.
    private func describedOffline(_ partNums: [String]) -> Bool {
        guard let offline = classifier?.offline else { return false }
        return partNums.allSatisfy { (partNum: String) -> Bool in offline.contains(partNum) }
    }

    // MARK: Recognition requests

    private func pump() {
        while activeRequests < maxConcurrentRequests, !jobs.isEmpty {
            let job = jobs.removeFirst()
            let generation = self.generation
            activeRequests += 1
            Task.detached(priority: .userInitiated) { [weak self] in
                let candidates: [Candidate]?
                let message: String?
                do {
                    switch job.work {
                    case .identify(let jpeg, let longMm, _):
                        candidates = try await API.shared.identify(jpeg: jpeg, rgbHex: job.rgbHex, longMm: longMm)
                    case .describe(let partNums):
                        candidates = try await API.shared.partInfo(partNums: partNums, rgbHex: job.rgbHex)
                    }
                    message = nil
                } catch {
                    candidates = nil
                    message = error.localizedDescription
                }
                self?.queue.async {
                    self?.finish(job: job, generation: generation, candidates: candidates, error: message)
                }
            }
        }
    }

    private func finish(job: Job, generation: Int, candidates: [Candidate]?, error: String?) {
        activeRequests -= 1
        defer { pump() }
        guard generation == self.generation, let piece = tracker.piece(id: job.pieceID) else { return }
        piece.inFlight -= 1
        var error = error
        switch (job.work, candidates) {
        case (.identify(_, _, let secondOpinion), let candidates?):
            if secondOpinion {
                serverOpinions[piece.id] = candidates.sorted { $0.score > $1.score }
            } else {
                piece.addServerView(scores: candidates.map { (partNum: $0.partNum, score: $0.score) })
                // The newest view carries the freshest colour ranking.
                for candidate in candidates { info[piece.id, default: [:]][candidate.partNum] = candidate }
            }
        case (.identify(_, _, let secondOpinion), nil):
            // A second opinion is asked for once only; if it fails, the phone's own answer stands.
            if !secondOpinion {
                piece.failures += 1
                piece.lastSubmitCamera = nil
            } else if classifier?.offline != nil {
                error = nil   // the phone's answer stands, and the scan can be finished without the server
            }
        case (.describe, let candidates?):
            for candidate in candidates { info[piece.id, default: [:]][candidate.partNum] = candidate }
        case (.describe(let partNums), nil):
            piece.failures += 1
            piece.requestedInfo.subtract(partNums)   // ask again the next time the piece is seen
            // Offline is not a problem worth showing when the bundled class file already describes these parts.
            if describedOffline(partNums) { error = nil }
        }
        let shownError = error
        DispatchQueue.main.async { self.lastError = shownError }
        publish(hint: nil)
    }

    // MARK: Publishing

    /// The pieces that count, as the UI shows them.
    private func snapshots() -> [PieceSnapshot] {
        let currentPass = tracker.currentPass
        return countable().map { piece in
            let candidates = self.candidates(for: piece)
            let state: PieceState
            if !candidates.isEmpty {
                state = .identified
            } else if piece.inFlight > 0 || (piece.deviceViews > 0 && piece.deviceViews < resolveAfterViews) || stills.isWaiting(piece.id) {
                state = .identifying
            } else if piece.views > 0 || piece.failures >= 2 {
                state = .unknown
            } else {
                state = .seen
            }
            return PieceSnapshot(id: piece.id, position: piece.position, state: state, longMm: piece.longMm,
                                 thumbnail: piece.thumbnail, candidates: candidates, earlierPass: piece.pass != currentPass)
        }
    }

    private func publish(hint: String?) {
        let snapshots = self.snapshots()
        let found = tableY != nil

        // The map, and the guess at whether the scan is complete: this pass's pieces only, as they are in this world.
        let currentPass = tracker.currentPass
        let timesSeen: [Int] = countable().filter { $0.pass == currentPass }
            .map { (piece: TrackedPiece) -> Int in coverageMap.timesSeen(at: piece.position) }
        let guess = CompletionGuess.assess(timesSeen: timesSeen, quietSeconds: quietTime.seconds)
        let mapPieces: [CoverageSnapshot.Piece] = snapshots.filter { !$0.earlierPass }.map { (piece: PieceSnapshot) -> CoverageSnapshot.Piece in
            CoverageSnapshot.Piece(id: piece.id, x: piece.position.x, z: piece.position.z, state: piece.state)
        }
        var camera: SIMD2<Float>?
        if found, let position = lastCameraPosition { camera = SIMD2<Float>(position.x, position.z) }
        let coverage = CoverageSnapshot(cellSize: coverageMap.cellSize, cells: coverageCells, bounds: coverageMap.bounds,
                                        camera: camera, heading: camera == nil ? nil : lastHeading,
                                        pieces: mapPieces, guess: guess)

        // A haptic tick for newly confirmed pieces.
        let fresh = snapshots.filter { (piece: PieceSnapshot) -> Bool in !announced.contains(piece.id) }
        for piece in fresh { announced.insert(piece.id) }
        let haptics = self.haptics

        DispatchQueue.main.async {
            self.pieces = snapshots
            self.tableFound = found
            self.coverage = coverage
            if let hint { self.hint = hint }
        }
        if !fresh.isEmpty {
            Task { @MainActor in haptics.tick() }
        }
    }

    // MARK: Pixels

    /// Nearest-neighbour downsample of ARKit's YCbCr camera frame to RGBA, rows top to bottom.
    private static func downsample(_ buffer: CVPixelBuffer, targetWidth: Int) -> (rgba: [UInt8], width: Int, height: Int, step: Int)? {
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let fullWidth = CVPixelBufferGetWidthOfPlane(buffer, 0), fullHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let step = max(1, fullWidth / targetWidth)
        let width = fullWidth / step, height = fullHeight / step
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self), chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        var out = [UInt8](repeating: 255, count: width * height * 4)
        out.withUnsafeMutableBufferPointer { dst in
            for j in 0..<height {
                let sy = j * step
                let lumaRow = luma + sy * lumaStride
                let chromaRow = chroma + (sy / 2) * chromaStride
                for i in 0..<width {
                    let sx = i * step
                    let y = Float(lumaRow[sx])
                    let cb = Float(chromaRow[(sx / 2) * 2]) - 128
                    let cr = Float(chromaRow[(sx / 2) * 2 + 1]) - 128
                    let o = (j * width + i) * 4
                    dst[o] = UInt8(max(0, min(255, y + 1.402 * cr)))
                    dst[o + 1] = UInt8(max(0, min(255, y - 0.344 * cb - 0.714 * cr)))
                    dst[o + 2] = UInt8(max(0, min(255, y + 1.772 * cb)))
                }
            }
        }
        return (out, width, height, step)
    }

    /// The frame's LiDAR depth (smoothed when available) and confidence, copied out of their pixel buffers, or nil on a
    /// phone without LiDAR or a frame without depth. Same orientation and field of view as `capturedImage`.
    private static func depthMap(of frame: ARFrame) -> DepthMap? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let buffer = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }

        var depth = [Float](repeating: 0, count: width * height)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { depth[y * width + x] = row[x] }
        }

        var confidence: [UInt8]?
        if let confidenceBuffer = sceneDepth.confidenceMap,
           CVPixelBufferGetPixelFormatType(confidenceBuffer) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidenceBuffer) == width, CVPixelBufferGetHeight(confidenceBuffer) == height {
            CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly) }
            if let confidenceBase = CVPixelBufferGetBaseAddress(confidenceBuffer) {
                let confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceBuffer)
                var levels = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    let row = confidenceBase.advanced(by: y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { levels[y * width + x] = row[x] }
                }
                confidence = levels
            }
        }
        return DepthMap(width: width, height: height, depth: depth, confidence: confidence)
    }

    /// ARKit's person segmentation for the frame (`segmentationBuffer`, one byte per pixel, 255 where a person is), copied
    /// out of its pixel buffer; nil when segmentation is off or the frame has none. Same orientation and field of view as
    /// `capturedImage`, at a lower resolution.
    private static func personMask(of frame: ARFrame) -> PersonMask? {
        guard let buffer = frame.segmentationBuffer,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [UInt8](repeating: 0, count: width * height)
        var any = false
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let v = row[x]
                values[y * width + x] = v
                if v != 0 { any = true }
            }
        }
        return any ? PersonMask(width: width, height: height, values: values) : nil
    }

    /// Full-resolution JPEG of one piece with a margin, turned upright for a phone held in portrait.
    private func crop(_ buffer: CVPixelBuffer, blob: DetectedBlob, step: Int) -> Data? {
        let s = CGFloat(step)
        let w = CGFloat(blob.maxX - blob.minX + 1) * s, h = CGFloat(blob.maxY - blob.minY + 1) * s
        let pad = max(w, h) * 0.18
        return crop(buffer, rect: CGRect(x: CGFloat(blob.minX) * s - pad, y: CGFloat(blob.minY) * s - pad,
                                         width: w + pad * 2, height: h + pad * 2))
    }

    /// JPEG of a rectangle of the image (pixels, origin top left), clipped to the image and turned upright.
    private func crop(_ buffer: CVPixelBuffer, rect top: CGRect) -> Data? {
        let fullWidth = CGFloat(CVPixelBufferGetWidth(buffer)), fullHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let clipped = top.intersection(CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
        guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8 else { return nil }
        // Core Image's origin is the bottom-left corner.
        let rect = CGRect(x: clipped.minX, y: fullHeight - clipped.maxY, width: clipped.width, height: clipped.height)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: rect).oriented(.right)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace)
    }

    /// Square region centred on a piece, sized so the piece fills about 70% of it, as in the training images.
    private func squareCrop(_ buffer: CVPixelBuffer, blob: DetectedBlob, step: Int) -> CIImage {
        let s = CGFloat(step)
        let side = CGFloat(max(blob.maxX - blob.minX, blob.maxY - blob.minY) + 1) * s / 0.7
        let centreX = CGFloat(blob.minX + blob.maxX + 1) / 2 * s, centreY = CGFloat(blob.minY + blob.maxY + 1) / 2 * s
        return squareCrop(buffer, centreX: centreX, centreY: centreY, side: side)
    }

    /// Square of the image centred on (`centreX`, `centreY`) (pixels, origin top left). Clamping repeats edge pixels
    /// if the square leaves the frame.
    private func squareCrop(_ buffer: CVPixelBuffer, centreX: CGFloat, centreY: CGFloat, side: CGFloat) -> CIImage {
        let fullHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        // Core Image's origin is the bottom-left corner.
        let rect = CGRect(x: centreX - side / 2, y: fullHeight - centreY - side / 2, width: side, height: side)
        return CIImage(cvPixelBuffer: buffer).clampedToExtent().cropped(to: rect)
    }
}

/// A light haptic tap, at most one per `minInterval` so a burst of new pieces does not buzz continuously.
final class HapticTicker: @unchecked Sendable {
    private let minInterval: TimeInterval
    // Touched only on the main thread, from `tick()`.
    private var generator: UIImpactFeedbackGenerator?
    private var lastTick: TimeInterval = 0

    init(minInterval: TimeInterval = 0.35) {
        self.minInterval = minInterval
    }

    @MainActor
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTick >= minInterval else { return }
        lastTick = now
        let feedback: UIImpactFeedbackGenerator
        if let generator {
            feedback = generator
        } else {
            feedback = UIImpactFeedbackGenerator(style: .light)
            generator = feedback
        }
        feedback.impactOccurred()
        feedback.prepare()   // keeps the next tap prompt
    }
}
