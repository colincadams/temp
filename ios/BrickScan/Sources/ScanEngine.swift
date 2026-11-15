import ARKit
import AVFoundation
import BrickCore
import Combine
import CoreImage
import simd

/// Turns a sweep of the camera over a table into a list of identified pieces.
///
/// For each processed camera frame:
/// 1. find the table plane and check the phone is facing it and moving slowly enough for sharp images;
/// 2. detect every fully visible piece (`InstanceDetector` when its model is bundled, else `PieceDetector`);
/// 3. project each one onto the table to get its real-world position and size (`TableProjector`);
/// 4. match it to a piece already seen at that spot, or start tracking a new one, so nothing is counted twice
///    (`PieceTracker`);
/// 5. recognise each piece. With a bundled model (`PartClassifier`) this happens on the phone from many
///    viewpoints, fused with the piece's measured size (`ShapeFusion`); a piece the model stays unsure of is
///    also sent to the server once for a second opinion (`SecondOpinion`). Without a model, two crops of
///    each piece are sent to the server.
///
/// Everything that is not camera, Core ML or publishing lives in the BrickCore package, where it is unit-tested.
final class ScanEngine: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {

    // MARK: Published (main thread)

    @Published private(set) var pieces: [PieceSnapshot] = []
    @Published private(set) var hint = "Point the phone at the table"
    @Published private(set) var tableFound = false
    @Published private(set) var lastError: String?
    @Published var torchOn = false { didSet { applyTorch() } }

    let session = ARSession()

    // MARK: Tuning

    private let workWidth = 640                 // detection runs on a frame downsampled to about this width
    private let frameInterval: TimeInterval = 0.2
    private let maxSpeed: Float = 0.30          // m/s; faster than this blurs small pieces
    private let minDownwardTilt: Float = 0.80   // cosine of the largest allowed angle from straight down
    private let maxConcurrentRequests = 3
    private let deviceViewsPerFrame = 12         // keeps frame processing responsive on a crowded table
    private let resolveAfterViews = 3            // views before asking the server for names and colours
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
    /// What the server has told us about parts, per tracked piece: name, picture and colour ranking by part number.
    private var info: [UUID: [String: Candidate]] = [:]
    /// The server's answer for pieces sent for a second opinion, best first.
    private var serverOpinions: [UUID: [Candidate]] = [:]
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
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.isAutoFocusEnabled = true
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            config.videoFormat = format   // more pixels per piece for recognition
        }
        session.run(config)
        queue.async { self.scanning = true }
    }

    func pause() {
        queue.async { self.scanning = false }
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
            self.jobs.removeAll()
            self.publish(hint: nil)
        }
        lastError = nil
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

        guard scanning, time - lastProcessed >= frameInterval else { return }
        lastProcessed = time

        guard case .normal = frame.camera.trackingState else {
            publish(hint: "Finding its bearings. Move the phone slowly.")
            return
        }
        guard let tableY = locateTable(frame: frame, cameraPosition: position) else {
            publish(hint: "Looking for the table. Point the phone down at it.")
            return
        }
        lockWhiteBalance()

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
        publish(hint: "Camera tracking failed: \(error.localizedDescription)")
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

    // MARK: Frame processing

    private func process(frame: ARFrame, tableY: Float, cameraPosition: SIMD3<Float>, time: TimeInterval) {
        let buffer = frame.capturedImage
        guard let work = ScanEngine.downsample(buffer, targetWidth: workWidth) else {
            publish(hint: "Unsupported camera format.")
            return
        }
        // The trained detector splits touching pieces; without it, only pieces standing apart are separated.
        let blobs = instanceDetector?.detect(rgba: work.rgba, width: work.width, height: work.height)
            ?? PieceDetector.detect(rgba: work.rgba, width: work.width, height: work.height)
        let k = frame.camera.intrinsics
        let c = frame.camera.transform.columns
        let projector = TableProjector(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                                       camera: Matrix4(c.0, c.1, c.2, c.3), tableY: tableY)

        tracker.beginFrame()
        var deviceBudget = deviceViewsPerFrame
        for blob in blobs {
            // Real position and size, then: same spot as a piece we already know, or a new one?
            guard let spot = projector.locate(workX: blob.cx, workY: blob.cy, step: Float(work.step)) else { continue }
            let quality = PieceTracker.viewQuality(of: blob, frameWidth: work.width, frameHeight: work.height)
            let observation = PieceObservation(blob: blob, position: spot.position, mmPerPixel: spot.mmPerPixel, quality: quality)
            guard let piece = tracker.observe(observation, time: time) else { continue }

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
                                               alreadyRequested: piece.secondOpinionRequested),
                   let jpeg = piece.thumbnail ?? crop(buffer, blob: blob, step: work.step) {
                    piece.secondOpinionRequested = true
                    piece.inFlight += 1
                    jobs.append(Job(pieceID: piece.id, rgbHex: piece.rgbHex,
                                    work: .identify(jpeg: jpeg, longMm: piece.longMm, secondOpinion: true)))
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
        for id in tracker.endFrame(time: time) {
            info[id] = nil
            serverOpinions[id] = nil
        }

        pump()
        publish(hint: tracker.confirmed.isEmpty ? "Move over your pieces" : "Sweep slowly across the table")
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
        let device: [Candidate] = fusedShapes(piece, classifier: classifier).compactMap { entry in
            guard var candidate = known[entry.shape.partNum] else { return nil }
            candidate.score = entry.probability
            return candidate
        }
        let server = serverOpinions[piece.id] ?? []
        switch SecondOpinion.choose(deviceTop: device.first?.score, serverTop: server.first?.score) {
        case .device: return device
        case .server: return server
        }
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
            }
        case (.describe, let candidates?):
            for candidate in candidates { info[piece.id, default: [:]][candidate.partNum] = candidate }
        case (.describe(let partNums), nil):
            piece.failures += 1
            piece.requestedInfo.subtract(partNums)   // ask again the next time the piece is seen
        }
        DispatchQueue.main.async { self.lastError = error }
        publish(hint: nil)
    }

    // MARK: Publishing

    private func publish(hint: String?) {
        let snapshots: [PieceSnapshot] = tracker.confirmed.map { piece in
            let candidates = self.candidates(for: piece)
            let state: PieceState
            if !candidates.isEmpty {
                state = .identified
            } else if piece.inFlight > 0 || (piece.deviceViews > 0 && piece.deviceViews < resolveAfterViews) {
                state = .identifying
            } else if piece.views > 0 || piece.failures >= 2 {
                state = .unknown
            } else {
                state = .seen
            }
            return PieceSnapshot(id: piece.id, position: piece.position, state: state, longMm: piece.longMm,
                                 thumbnail: piece.thumbnail, candidates: candidates)
        }
        let found = tableY != nil
        DispatchQueue.main.async {
            self.pieces = snapshots
            self.tableFound = found
            if let hint { self.hint = hint }
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

    /// Full-resolution JPEG of one piece with a margin, turned upright for a phone held in portrait.
    private func crop(_ buffer: CVPixelBuffer, blob: DetectedBlob, step: Int) -> Data? {
        let fullWidth = CGFloat(CVPixelBufferGetWidth(buffer)), fullHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let s = CGFloat(step)
        let w = CGFloat(blob.maxX - blob.minX + 1) * s, h = CGFloat(blob.maxY - blob.minY + 1) * s
        let pad = max(w, h) * 0.18
        let top = CGRect(x: CGFloat(blob.minX) * s - pad, y: CGFloat(blob.minY) * s - pad, width: w + pad * 2, height: h + pad * 2)
            .intersection(CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
        guard top.width >= 8, top.height >= 8 else { return nil }
        // Core Image's origin is the bottom-left corner.
        let rect = CGRect(x: top.minX, y: fullHeight - top.maxY, width: top.width, height: top.height)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: rect).oriented(.right)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace)
    }

    /// Square region centred on a piece, sized so the piece fills about 70% of it, as in the training images.
    private func squareCrop(_ buffer: CVPixelBuffer, blob: DetectedBlob, step: Int) -> CIImage {
        let fullHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let s = CGFloat(step)
        let side = CGFloat(max(blob.maxX - blob.minX, blob.maxY - blob.minY) + 1) * s / 0.7
        let centreX = CGFloat(blob.minX + blob.maxX + 1) / 2 * s, centreY = CGFloat(blob.minY + blob.maxY + 1) / 2 * s
        // Core Image's origin is the bottom-left corner. Clamping repeats edge pixels if the square leaves the frame.
        let rect = CGRect(x: centreX - side / 2, y: fullHeight - centreY - side / 2, width: side, height: side)
        return CIImage(cvPixelBuffer: buffer).clampedToExtent().cropped(to: rect)
    }
}
