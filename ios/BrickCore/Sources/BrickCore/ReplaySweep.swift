import Foundation

/// A rendered sweep as written by `ml/render_sweep.py`: what ARKit would report for each frame, the frames
/// themselves at the detector's working resolution, and the truth about every piece on the table.
public struct ReplaySweep: Codable {
    public struct Frame: Codable {
        /// The full-resolution picture (not read here).
        public var file: String
        /// Seconds since the start of the sweep.
        public var time: Double
        /// Camera-to-world transform, 16 numbers by columns, ARKit conventions (metres, y up, looking along -z).
        public var transform: [Float]
        /// Raw RGBA bytes at the working resolution (`ml/sweep_frames.py`).
        public var rgba: String?
        /// Piece-number map at the working resolution, little-endian UInt16: 0 = table, `Piece.id + 1` = that piece.
        public var ids: String?

        public init(file: String, time: Double, transform: [Float], rgba: String? = nil, ids: String? = nil) {
            self.file = file; self.time = time; self.transform = transform; self.rgba = rgba; self.ids = ids
        }

        /// Name shared by this frame's files: "0007" for "0007.jpg".
        public var stem: String { (file as NSString).deletingPathExtension }
    }

    public struct Piece: Codable {
        public var id: Int
        public var partNum: String
        public var classId: Int?
        public var colorId: Int?
        /// Position on the table, world metres.
        public var x: Float
        public var z: Float
        /// Furthest distance of the part's surface from its middle, millimetres.
        public var radiusMm: Float
        /// Sides of the smallest rectangle around the piece seen from straight above, and its height (newer sweeps only).
        public var longMm: Float?
        public var shortMm: Float?
        public var heightMm: Float?
        /// The piece's catalog colour as "rrggbb" (newer sweeps only).
        public var rgb: String?

        public init(id: Int, partNum: String, classId: Int? = nil, colorId: Int? = nil, x: Float, z: Float, radiusMm: Float,
                    longMm: Float? = nil, shortMm: Float? = nil, heightMm: Float? = nil, rgb: String? = nil) {
            self.id = id; self.partNum = partNum; self.classId = classId; self.colorId = colorId
            self.x = x; self.z = z; self.radiusMm = radiusMm
            self.longMm = longMm; self.shortMm = shortMm; self.heightMm = heightMm; self.rgb = rgb
        }
    }

    /// Full-resolution image size and intrinsics.
    public var width: Int
    public var height: Int
    public var fx: Float, fy: Float, cx: Float, cy: Float
    public var tableY: Float
    public var frames: [Frame]
    public var pieces: [Piece]
    /// Working resolution the frames were saved at (`ml/sweep_frames.py`); worked out as the app does if absent.
    public var workStep: Int?
    public var workWidth: Int?
    public var workHeight: Int?

    public init(width: Int, height: Int, fx: Float, fy: Float, cx: Float, cy: Float, tableY: Float,
                frames: [Frame], pieces: [Piece], workStep: Int? = nil, workWidth: Int? = nil, workHeight: Int? = nil) {
        self.width = width; self.height = height
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.tableY = tableY
        self.frames = frames; self.pieces = pieces
        self.workStep = workStep; self.workWidth = workWidth; self.workHeight = workHeight
    }

    /// The app's working width (`ScanEngine.workWidth`).
    public static let appWorkWidth = 640

    /// Working resolution: every `step`-th pixel of every `step`-th row, as `ScanEngine.downsample` does.
    public var work: (step: Int, width: Int, height: Int) {
        let step = workStep ?? max(1, width / ReplaySweep.appWorkWidth)
        return (step, workWidth ?? width / step, workHeight ?? height / step)
    }

    public func camera(_ frame: Frame) -> Matrix4? {
        let t = frame.transform
        guard t.count == 16 else { return nil }
        return Matrix4(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                       SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
    }

    public func projector(_ frame: Frame) -> TableProjector? {
        guard let camera = camera(frame) else { return nil }
        return TableProjector(fx: fx, fy: fy, cx: cx, cy: cy, camera: camera, tableY: tableY)
    }
}

/// One frame's pixels, as the replay reads them.
public struct ReplayFrameData {
    public var rgba: [UInt8]
    /// Piece-number map at the working resolution, if the sweep has one.
    public var ids: [UInt16]?
    /// Detector network output (`NNNN.maps`), if asked for.
    public var maps: [Float]?

    public init(rgba: [UInt8], ids: [UInt16]? = nil, maps: [Float]? = nil) {
        self.rgba = rgba; self.ids = ids; self.maps = maps
    }
}

public struct ReplayError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A sweep folder on disk: sweep.json plus each frame's files.
public struct ReplayFolder {
    public let url: URL
    public let sweep: ReplaySweep

    public init(url: URL) throws {
        self.url = url
        let file = url.appendingPathComponent("sweep.json")
        guard let data = try? Data(contentsOf: file) else { throw ReplayError("cannot read \(file.path)") }
        do {
            sweep = try JSONDecoder().decode(ReplaySweep.self, from: data)
        } catch {
            throw ReplayError("\(file.path) is not a sweep: \(error)")
        }
    }

    /// Whether every frame has a piece-number map.
    public var hasPieceMaps: Bool { sweep.frames.allSatisfy { $0.ids != nil } }

    /// - Parameter maps: also read the frame's detector output, `NNNN.maps`.
    public func load(frame index: Int, ids wantIDs: Bool, maps wantMaps: Bool) throws -> ReplayFrameData {
        let frame = sweep.frames[index]
        let work = sweep.work
        guard let name = frame.rgba else {
            throw ReplayError("frame \(frame.file) has no raw pixels; run: python3 ml/sweep_frames.py \(url.path)")
        }
        let rgba = [UInt8](try read(name))
        guard rgba.count == work.width * work.height * 4 else {
            throw ReplayError("\(name) holds \(rgba.count) bytes, expected \(work.width) x \(work.height) x 4")
        }
        var result = ReplayFrameData(rgba: rgba)
        if wantIDs, let name = frame.ids {
            let ids = ReplayFolder.uint16(try read(name))
            guard ids.count == work.width * work.height else {
                throw ReplayError("\(name) holds \(ids.count) values, expected \(work.width) x \(work.height)")
            }
            result.ids = ids
        }
        if wantMaps {
            result.maps = ReplayFolder.float32(try read(frame.stem + ".maps"))
        }
        return result
    }

    private func read(_ name: String) throws -> Data {
        let file = url.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else { throw ReplayError("cannot read \(file.path)") }
        return data
    }

    static func uint16(_ data: Data) -> [UInt16] {
        let bytes = [UInt8](data)
        return (0..<bytes.count / 2).map { UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8 }
    }

    static func float32(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        return (0..<bytes.count / 4).map { i in
            let b = 4 * i
            return Float(bitPattern: UInt32(bytes[b]) | UInt32(bytes[b + 1]) << 8 | UInt32(bytes[b + 2]) << 16 | UInt32(bytes[b + 3]) << 24)
        }
    }
}
