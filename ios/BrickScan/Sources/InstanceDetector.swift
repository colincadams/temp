import BrickCore
import CoreML
import CoreVideo
import Foundation

/// Trained piece detector: separates every piece in a frame, including pieces that touch.
///
/// The network (`ml/detector.py`, exported as `PieceNet.mlpackage`) predicts for each pixel whether it is part
/// of a piece, how close it is to a piece's centre, and the offset to the centre of its piece. Pieces are
/// recovered by finding the centre peaks and giving each piece-pixel to the peak its offset points at.
/// That grouping is `InstanceGrouping` in the BrickCore package; this class only runs the model.
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

        return InstanceGrouping.group(maps: maps, outputWidth: ow, validRows: oh, rgba: rgba, frameWidth: w, stride: stride,
                                      pieceThreshold: pieceThreshold, peakThreshold: peakThreshold, minArea: minArea)
    }
}
