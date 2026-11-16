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
/// 1. find the table plane and check the phone is facing it and moving slowly enough for sharp images;
/// 2. detect every fully visible piece (`InstanceDetector` when its model is bundled, else `PieceDetector`);
/// 3. project each one onto the table to get its real-world position and size (`TableProjector`);
/// 4. match it to a piece already seen at that spot, or start tracking a new one, so nothing is counted twice
///    (`PieceTracker`);
/// 5. recognise each piece. With a bundled model (`PartClassifier`) this happens on the phone from many
///    viewpoints, fused with the piece's measured size (`ShapeFusion`); a piece the model stays unsure of is
///    also sent to the server once for a second opinion (`SecondOpinion`). Names, pictures and colours come
///    from the bundled class file when it has them (`OfflineCatalog`, `ColorRanking`), so a scan can be finished
///    without a connection; the server's description replaces them when it arrives. Without a model, two crops
///    of each piece are sent to the server.
/// 6. add what the camera saw well to the coverage map (`CoverageMap`) and guess whether the scan has found
///    everything (`CompletionGuess`), for the map on the scan screen.
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
    private var coverageMap = CoverageMap()
    private var quietTime = CoverageQuietTime()
    /// `coverageMap`'s cells as the map draws them, rebuilt when a frame adds to the map.
    private var coverageCells: [CoverageSnapshot.Cell] = []
    /// Which way the top of the phone points, on the table; updated every frame.
    private var lastHeading: SIMD2<Float>?
    /// Confirmed pieces already announced with a haptic tick.
    private var announced = Set<UUID>()
    private let haptics = HapticTicker()

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
        // LiDAR phones: depth tells how tall each piece is, for placing and measuring it. The smoothed stream is
        // ARKit's depth averaged over the last few frames: steadier on a still table, which is all a sweep looks at.
        // Without LiDAR the tracker works out heights from how pieces seem to slide as the phone moves.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
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
            self.offlineCandidates.removeAll()
            self.jobs.removeAll()
            self.coverageMap.reset()
            self.quietTime.reset()
            self.coverageCells.removeAll()
            self.announced.removeAll()
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
        lastHeading = ScanEngine.heading(of: camera)

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

        // LiDAR depth, when the phone has it: each piece's height, so the tracker places it by the table point under it
        // and measures it at its own height. Without it the tracker works the height out from several views.
        let depth = ScanEngine.depthMap(of: frame)
        let resolution = frame.camera.imageResolution
        let imageWidth = Float(resolution.width), imageHeight = Float(resolution.height)

        tracker.beginFrame()
        var deviceBudget = deviceViewsPerFrame
        // Real position and size of each detection on the table.
        var seen: [(blob: DetectedBlob, observation: PieceObservation)] = []
        for blob in blobs {
            guard let spot = projector.locate(workX: blob.cx, workY: blob.cy, step: Float(work.step)) else { continue }
            let quality = PieceTracker.viewQuality(of: blob, frameWidth: work.width, frameHeight: work.height)
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

        // What this frame saw well enough to find whole pieces in.
        let update = coverageMap.add(view: projector, imageWidth: imageWidth, imageHeight: imageHeight, inset: coverageInset)
        quietTime.record(time: time, cameraPosition: cameraPosition, update: update, confirmedCount: tracker.confirmed.count)
        if update.cellsInView > 0 {
            let map = coverageMap
            coverageCells = map.cells.map { (entry: (key: CoverageCell, value: Int)) -> CoverageSnapshot.Cell in
                let centre = map.center(of: entry.key)
                return CoverageSnapshot.Cell(x: centre.x, z: centre.y, count: entry.value)
            }
        }

        pump()
        publish(hint: tracker.confirmed.isEmpty ? "Move over your pieces" : "Sweep slowly across the table")
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

        // The map, and the guess at whether the scan is complete.
        let timesSeen: [Int] = tracker.confirmed.map { (piece: TrackedPiece) -> Int in coverageMap.timesSeen(at: piece.position) }
        let guess = CompletionGuess.assess(timesSeen: timesSeen, quietSeconds: quietTime.seconds)
        let mapPieces: [CoverageSnapshot.Piece] = snapshots.map { (piece: PieceSnapshot) -> CoverageSnapshot.Piece in
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
