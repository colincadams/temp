import Foundation

/// The depth maps of a sweep rendered with `ml/render_sweep.py --depth`: per frame `NNNN.depth` (little-endian float32
/// metres) and `NNNN.conf` (one ARConfidenceLevel byte per pixel), `depthWidth` x `depthHeight` (256 x 192), rows top
/// to bottom, the same field of view as the frame, as ARKit's `sceneDepth` gives them.
public struct DepthReplayFiles {
    private struct Meta: Decodable {
        struct Frame: Decodable {
            let file: String
            let depth: String?
            let confidence: String?
        }
        let depthWidth: Int?
        let depthHeight: Int?
        let frames: [Frame]
    }

    public let url: URL
    public let width: Int
    public let height: Int
    private let names: [(depth: String, confidence: String?)]

    public init(folder: ReplayFolder) throws {
        url = folder.url
        let data = try Data(contentsOf: folder.url.appendingPathComponent("sweep.json"))
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        guard let w = meta.depthWidth, let h = meta.depthHeight, meta.frames.allSatisfy({ $0.depth != nil }) else {
            throw ReplayError("this sweep has no depth maps; render it with: python3 ml/render_sweep.py ... --depth")
        }
        width = w; height = h
        names = meta.frames.map { ($0.depth!, $0.confidence) }
    }

    public func load(frame index: Int) throws -> DepthMap {
        let entry = names[index]
        let depth = ReplayFolder.float32(try read(entry.depth))
        let confidence = try entry.confidence.map { [UInt8](try read($0)) }
        guard let map = DepthMap(width: width, height: height, depth: depth, confidence: confidence) else {
            throw ReplayError("\(entry.depth) does not hold \(width) x \(height) depth values (and confidences)")
        }
        return map
    }

    private func read(_ name: String) throws -> Data {
        let file = url.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else { throw ReplayError("cannot read \(file.path)") }
        return data
    }
}
