import ARKit
import AVFoundation
import Combine
import CoreImage
import simd

/// Turns a sweep of the camera over a table into a list of identified pieces.
///
/// For each processed camera frame:
/// 1. find the table plane and check the phone is facing it and moving slowly enough for sharp images;
/// 2. detect every fully visible piece (`PieceDetector`);
/// 3. project each one onto the table to get its real-world position and size;
/// 4. match it to a piece already seen at that spot, or start tracking a new one, so nothing is counted twice;
/// 5. send a crop of each piece to the server for recognition, from up to two different viewpoints.
final class ScanEngine: NSObject, ObservableObject, ARSessionDelegate {

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
    private let confirmAfter = 3                // sightings before a blob counts as a piece
    private let viewsPerPiece = 2
    private let secondViewBaseline: Float = 0.08 // metres the camera must move before a second view is worth sending
    private let maxConcurrentRequests = 3

    // MARK: State (confined to `queue`)

    private final class TrackedPiece {
        let id = UUID()
        let firstSeen: TimeInterval
        var position: SIMD3<Float>
        var sightings = 1
        var longSamples: [Float] = []
        var rSamples: [Float] = [], gSamples: [Float] = [], bSamples: [Float] = []
        var bestQuality: Float = 0
        var thumbnail: Data?
        var thumbnailQuality: Float = 0
        var views = 0
        var inFlight = 0
        var failures = 0
        var lastSubmitCamera: SIMD3<Float>?
        var scoreSum: [String: Double] = [:]
        var info: [String: Candidate] = [:]

        init(position: SIMD3<Float>, time: TimeInterval) {
            self.position = position
            self.firstSeen = time
        }

        var longMm: Float { ScanEngine.median(longSamples) }

        var rgbHex: String {
            String(format: "%02x%02x%02x", Int(ScanEngine.median(rSamples)), Int(ScanEngine.median(gSamples)), Int(ScanEngine.median(bSamples)))
        }

        func addSample(longMm: Float, blob: DetectedBlob) {
            if longSamples.count >= 25 {
                longSamples.removeFirst(); rSamples.removeFirst(); gSamples.removeFirst(); bSamples.removeFirst()
            }
            longSamples.append(longMm)
            rSamples.append(Float(blob.r)); gSamples.append(Float(blob.g)); bSamples.append(Float(blob.b))
        }

        var candidates: [Candidate] {
            guard views > 0 else { return [] }
            return info.values
                .map { c in var c = c; c.score = (scoreSum[c.partNum] ?? 0) / Double(views); return c }
                .sorted { $0.score > $1.score }
        }
    }

    private struct Job {
        let pieceID: UUID
        let jpeg: Data
        let rgbHex: String
        let longMm: Float
    }

    private let queue = DispatchQueue(label: "brickscan.engine", qos: .userInitiated)
    private let ciContext = CIContext()
    private var tracked: [TrackedPiece] = []
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
            self.tracked.removeAll()
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
            speed = simd_distance(position, last) / Float(time - lastCameraTime)
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

    /// Maps a pixel of the full-resolution camera image to the point on the table it shows.
    private struct TableProjector {
        let fx: Float, fy: Float, cx: Float, cy: Float
        let camera: simd_float4x4
        let tableY: Float

        init(frame: ARFrame, tableY: Float) {
            let k = frame.camera.intrinsics
            fx = k[0][0]; fy = k[1][1]; cx = k[2][0]; cy = k[2][1]
            camera = frame.camera.transform
            self.tableY = tableY
        }

        func point(_ px: Float, _ py: Float) -> SIMD3<Float>? {
            // Camera space: +x right, +y up, looking along -z; image y grows downwards.
            let dir = camera * SIMD4<Float>((px - cx) / fx, -(py - cy) / fy, -1, 0)
            guard dir.y < -1e-4 else { return nil }
            let origin = camera.columns.3
            let t = (tableY - origin.y) / dir.y
            guard t > 0, t < 4 else { return nil }
            return SIMD3<Float>(origin.x + dir.x * t, tableY, origin.z + dir.z * t)
        }
    }

    private func process(frame: ARFrame, tableY: Float, cameraPosition: SIMD3<Float>, time: TimeInterval) {
        let buffer = frame.capturedImage
        guard let work = ScanEngine.downsample(buffer, targetWidth: workWidth) else {
            publish(hint: "Unsupported camera format.")
            return
        }
        let blobs = PieceDetector.detect(rgba: work.rgba, width: work.width, height: work.height)
        let projector = TableProjector(frame: frame, tableY: tableY)
        let step = Float(work.step)
        let centerX = Float(work.width) / 2, centerY = Float(work.height) / 2
        let maxCenterDistance = (centerX * centerX + centerY * centerY).squareRoot()

        var matched = Set<UUID>()
        for blob in blobs {
            let fullX = blob.cx * step, fullY = blob.cy * step
            // Millimetres per work pixel at this spot, from two short steps across the table.
            let probe: Float = 12
            guard let world = projector.point(fullX, fullY),
                  let right = projector.point(fullX + probe * step, fullY),
                  let down = projector.point(fullX, fullY + probe * step) else { continue }
            let mmPerPixel = (simd_distance(world, right) + simd_distance(world, down)) / 2 / probe * 1000
            let longMm = blob.major * mmPerPixel
            guard longMm >= 4, longMm <= 400 else { continue }   // not a Lego piece: grit, or a hand or sleeve

            // Same spot as a piece we already know? Tall pieces shift a little with viewing angle, hence the slack.
            let radius = max(0.010, longMm / 1000 * 0.5)
            var nearest: TrackedPiece?
            var nearestDistance = radius
            for piece in tracked where !matched.contains(piece.id) {
                let d = simd_distance(piece.position, world)
                if d < nearestDistance { nearest = piece; nearestDistance = d }
            }
            let piece: TrackedPiece
            if let nearest {
                piece = nearest
                piece.sightings += 1
                piece.position = simd_mix(piece.position, world, SIMD3<Float>(repeating: 0.25))
            } else {
                piece = TrackedPiece(position: world, time: time)
                tracked.append(piece)
            }
            matched.insert(piece.id)
            piece.addSample(longMm: longMm, blob: blob)

            // Bigger and nearer the middle of the frame is a better picture.
            let dx = blob.cx - centerX, dy = blob.cy - centerY
            let quality = Float(blob.area) * (1 - 0.5 * (dx * dx + dy * dy).squareRoot() / maxCenterDistance)
            piece.bestQuality = max(piece.bestQuality, quality)

            if shouldSubmit(piece, quality: quality, cameraPosition: cameraPosition),
               let jpeg = crop(buffer, blob: blob, step: work.step) {
                if quality >= piece.thumbnailQuality { piece.thumbnail = jpeg; piece.thumbnailQuality = quality }
                piece.inFlight += 1
                piece.lastSubmitCamera = cameraPosition
                jobs.append(Job(pieceID: piece.id, jpeg: jpeg, rgbHex: piece.rgbHex, longMm: piece.longMm))
            }
        }

        // Drop blobs that never firmed up (a passing hand, a shadow).
        tracked.removeAll { $0.sightings < confirmAfter && time - $0.firstSeen > 3 && !matched.contains($0.id) }

        pump()
        let anyConfirmed = tracked.contains(where: { $0.sightings >= confirmAfter })
        publish(hint: anyConfirmed ? "Sweep slowly across the table" : "Move over your pieces")
    }

    private func shouldSubmit(_ piece: TrackedPiece, quality: Float, cameraPosition: SIMD3<Float>) -> Bool {
        guard piece.sightings >= confirmAfter, piece.failures < 2, piece.views + piece.inFlight < viewsPerPiece else { return false }
        // Wait for a reasonably good picture, but not forever.
        guard quality >= piece.bestQuality * 0.6 || piece.sightings >= 10 else { return false }
        if let last = piece.lastSubmitCamera {
            return simd_distance(last, cameraPosition) >= secondViewBaseline
        }
        return true
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
                    candidates = try await API.shared.identify(jpeg: job.jpeg, rgbHex: job.rgbHex, longMm: job.longMm)
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
        guard generation == self.generation, let piece = tracked.first(where: { $0.id == job.pieceID }) else { return }
        piece.inFlight -= 1
        if let candidates {
            piece.views += 1
            for candidate in candidates {
                piece.scoreSum[candidate.partNum, default: 0] += candidate.score
                piece.info[candidate.partNum] = candidate   // newest view carries the freshest colour ranking
            }
        } else {
            piece.failures += 1
            piece.lastSubmitCamera = nil
        }
        DispatchQueue.main.async { self.lastError = error }
        publish(hint: nil)
    }

    // MARK: Publishing

    private func publish(hint: String?) {
        let snapshots: [PieceSnapshot] = tracked.filter { $0.sightings >= confirmAfter }.map { piece in
            let candidates = piece.candidates
            let state: PieceState
            if !candidates.isEmpty {
                state = .identified
            } else if piece.inFlight > 0 {
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

    fileprivate static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }
}
