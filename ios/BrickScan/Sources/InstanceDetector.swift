import CoreML
import CoreVideo
import Foundation

/// Trained piece detector: separates every piece in a frame, including pieces that touch.
///
/// The network (`ml/detector.py`, exported as `PieceNet.mlpackage`) predicts for each pixel whether it is part
/// of a piece, how close it is to a piece's centre, and the offset to the centre of its piece. Pieces are
/// recovered by finding the centre peaks and giving each piece-pixel to the peak its offset points at.
/// This mirrors `group_instances` in `ml/detector.py`; keep the two in step.
///
/// The model is an optional resource. Without it `init` returns nil and the app uses `PieceDetector`,
/// which only separates pieces that do not touch. Not thread-safe: use from one queue.
final class InstanceDetector {
    private static let inputWidth = 640, inputHeight = 480, stride = 2
    private let pieceThreshold: Float = 0.5
    private let peakThreshold: Float = 0.3
    private let minArea = 6            // output pixels
    private let model: MLModel
    private let input: CVPixelBuffer

    init?() {
        guard let url = Bundle.main.url(forResource: "PieceNet", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, InstanceDetector.inputWidth, InstanceDetector.inputHeight,
                            kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { return nil }
        self.model = model
        self.input = buffer
    }

    /// - Parameter rgba: `width * height * 4` bytes, rows top to bottom. Returns nil if the frame does not fit the model.
    func detect(rgba: [UInt8], width w: Int, height h: Int) -> [DetectedBlob]? {
        let inW = InstanceDetector.inputWidth, inH = InstanceDetector.inputHeight, stride = InstanceDetector.stride
        guard w == inW, h >= stride * 4, h <= inH, rgba.count >= w * h * 4 else { return nil }

        // Copy the frame into the model's input. Frames shorter than the input repeat their last row.
        CVPixelBufferLockBaseAddress(input, [])
        if let base = CVPixelBufferGetBaseAddress(input) {
            let rowBytes = CVPixelBufferGetBytesPerRow(input)
            let dst = base.assumingMemoryBound(to: UInt8.self)
            rgba.withUnsafeBufferPointer { src in
                for y in 0..<inH {
                    let srcRow = min(y, h - 1) * w * 4
                    let dstRow = y * rowBytes
                    for x in 0..<inW {
                        let s = srcRow + x * 4, d = dstRow + x * 4
                        dst[d] = src[s + 2]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s]; dst[d + 3] = 255
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])

        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]),
              let output = try? model.prediction(from: features),
              let array = output.featureValue(for: "maps")?.multiArrayValue else { return nil }
        let maps = MLShapedArray<Float>(converting: array).scalars
        let ow = inW / stride, fullOH = inH / stride
        let plane = ow * fullOH
        guard maps.count == plane * 4 else { return nil }
        let oh = h / stride   // rows that show real image, not padding

        // Centre peaks: strongest value in their 3 x 3 neighbourhood.
        var found: [(x: Int, y: Int, value: Float)] = []
        for y in 0..<oh {
            for x in 0..<ow {
                let value = maps[plane + y * ow + x]
                if value <= peakThreshold { continue }
                var isPeak = true
                for ny in max(0, y - 1)...min(oh - 1, y + 1) where isPeak {
                    for nx in max(0, x - 1)...min(ow - 1, x + 1) where maps[plane + ny * ow + nx] > value {
                        isPeak = false
                        break
                    }
                }
                if isPeak { found.append((x, y, value)) }
            }
        }
        found.sort { $0.value > $1.value }
        // A broad peak can have several maxima: keep the strongest within 2.5 pixels.
        var peaks: [(x: Float, y: Float)] = []
        let cell = 16
        let gridW = ow / cell + 1, gridH = oh / cell + 1
        var grid = [[Int]](repeating: [], count: gridW * gridH)
        for candidate in found {
            let px = Float(candidate.x), py = Float(candidate.y)
            let gx = candidate.x / cell, gy = candidate.y / cell
            var duplicate = false
            for ny in max(0, gy - 1)...min(gridH - 1, gy + 1) where !duplicate {
                for nx in max(0, gx - 1)...min(gridW - 1, gx + 1) where !duplicate {
                    for index in grid[ny * gridW + nx] {
                        let dx = peaks[index].x - px, dy = peaks[index].y - py
                        if dx * dx + dy * dy <= 6.25 { duplicate = true; break }
                    }
                }
            }
            if duplicate { continue }
            grid[gy * gridW + gx].append(peaks.count)
            peaks.append((px, py))
        }
        if peaks.isEmpty { return [] }

        // Give every piece-pixel to the peak its offset points at, gathering each piece's statistics as we go.
        struct Stats {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, area = 0
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            var samples: [Int] = []
        }
        var stats = [Stats](repeating: Stats(), count: peaks.count)
        for y in 0..<oh {
            for x in 0..<ow {
                let i = y * ow + x
                if maps[i] <= pieceThreshold { continue }
                let vx = Float(x) + maps[2 * plane + i], vy = Float(y) + maps[3 * plane + i]
                if !vx.isFinite || !vy.isFinite { continue }
                var best = -1
                var bestDistance = Float.greatestFiniteMagnitude
                let gx = min(gridW - 1, max(0, Int(vx) / cell)), gy = min(gridH - 1, max(0, Int(vy) / cell))
                for ny in max(0, gy - 1)...min(gridH - 1, gy + 1) {
                    for nx in max(0, gx - 1)...min(gridW - 1, gx + 1) {
                        for index in grid[ny * gridW + nx] {
                            let dx = peaks[index].x - vx, dy = peaks[index].y - vy
                            let d = dx * dx + dy * dy
                            if d < bestDistance { bestDistance = d; best = index }
                        }
                    }
                }
                if best < 0 {   // no peak nearby: fall back to searching them all
                    for index in 0..<peaks.count {
                        let dx = peaks[index].x - vx, dy = peaks[index].y - vy
                        let d = dx * dx + dy * dy
                        if d < bestDistance { bestDistance = d; best = index }
                    }
                }
                let fx = Double(x), fy = Double(y)
                stats[best].area += 1
                stats[best].minX = min(stats[best].minX, x); stats[best].maxX = max(stats[best].maxX, x)
                stats[best].minY = min(stats[best].minY, y); stats[best].maxY = max(stats[best].maxY, y)
                stats[best].sx += fx; stats[best].sy += fy
                stats[best].sxx += fx * fx; stats[best].syy += fy * fy; stats[best].sxy += fx * fy
                if stats[best].samples.count < 600 || stats[best].area % 5 == 0 { stats[best].samples.append(i) }
            }
        }

        // Report in input-frame pixels, the same units PieceDetector uses.
        let scale = Float(stride)
        let maxArea = ow * oh / 6
        var blobs: [DetectedBlob] = []
        for s in stats where s.area >= minArea && s.area <= maxArea {
            // Cut off by the frame edge: wait for a frame that shows the whole piece.
            if s.minX <= 0 || s.minY <= 0 || s.maxX >= ow - 1 || s.maxY >= oh - 1 { continue }
            let count = Double(s.area)
            let mx = s.sx / count, my = s.sy / count
            let vxx = max(0, s.sxx / count - mx * mx), vyy = max(0, s.syy / count - my * my)
            let vxy = s.sxy / count - mx * my
            let half = (vxx + vyy) / 2
            let root = max(0, half * half - (vxx * vyy - vxy * vxy)).squareRoot()
            let major = Float((12 * (half + root)).squareRoot()) * scale
            let minor = Float((12 * max(0, half - root)).squareRoot()) * scale

            var rs = [UInt8](), gs = [UInt8](), bs = [UInt8]()
            for i in s.samples {
                let p = ((i / ow) * stride * w + (i % ow) * stride) * 4
                rs.append(rgba[p]); gs.append(rgba[p + 1]); bs.append(rgba[p + 2])
            }
            rs.sort(); gs.sort(); bs.sort()
            let mid = s.samples.count / 2
            blobs.append(DetectedBlob(minX: s.minX * stride, minY: s.minY * stride,
                                      maxX: s.maxX * stride + stride - 1, maxY: s.maxY * stride + stride - 1,
                                      area: s.area * stride * stride,
                                      cx: (Float(mx) + 0.5) * scale, cy: (Float(my) + 0.5) * scale,
                                      major: max(major, 1), minor: max(minor, 1),
                                      r: rs[mid], g: gs[mid], b: bs[mid]))
        }
        return blobs
    }
}
