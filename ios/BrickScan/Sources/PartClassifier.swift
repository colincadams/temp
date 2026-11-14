import CoreImage
import CoreML
import CoreVideo
import Foundation

/// One shape the model knows, as written by `ml/export.py`.
struct ShapeClass: Codable {
    let partNum: String
    let name: String
    /// Every catalog part number with this shape (prints and mould variants).
    let members: [String]
    /// Bounding-box extents in millimetres, largest first.
    let sizeMm: [Float]
}

private struct ClassFile: Codable {
    let imageSize: Int
    let classes: [ShapeClass]
}

/// Runs the part recognition model on the phone.
///
/// The model and class list are optional resources (`PartNet.mlpackage` and `classes.json` in `Sources/Model/`).
/// Without them `init` returns nil and the app falls back to the server's recognition service.
/// Not thread-safe: use from one queue.
final class PartClassifier {
    let classes: [ShapeClass]
    private let imageSize: Int
    private let model: MLModel
    private let context: CIContext
    private let input: CVPixelBuffer
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    /// Sharpness used in training (`margin_loss` scale in ml/model.py).
    private let similarityScale: Float = 30

    init?(context: CIContext) {
        guard let modelURL = Bundle.main.url(forResource: "PartNet", withExtension: "mlmodelc"),
              let classURL = Bundle.main.url(forResource: "classes", withExtension: "json"),
              let data = try? Data(contentsOf: classURL),
              let file = try? JSONDecoder().decode(ClassFile.self, from: data),
              !file.classes.isEmpty else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelURL, configuration: configuration) else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, file.imageSize, file.imageSize, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { return nil }
        self.classes = file.classes
        self.imageSize = file.imageSize
        self.model = model
        self.context = context
        self.input = buffer
    }

    /// Log-probability of each shape for one square crop of a piece. Add these across views to fuse them.
    func classify(_ crop: CIImage) -> [Float]? {
        let extent = crop.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        let side = CGFloat(imageSize)
        let scaled = crop
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: side / extent.width, y: side / extent.height))
        context.render(scaled, to: input, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: colorSpace)

        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]),
              let output = try? model.prediction(from: features),
              let similarity = output.featureValue(for: "similarity")?.multiArrayValue,
              similarity.count == classes.count else { return nil }

        var logits = [Float](repeating: 0, count: classes.count)
        for i in 0..<logits.count { logits[i] = similarity[i].floatValue * similarityScale }
        return PartClassifier.logSoftmax(logits)
    }

    /// How well each shape's true dimensions fit a measured footprint, as a log-likelihood.
    ///
    /// A crop is resized before recognition, so the image alone cannot tell a 1 x 2 plate from a 1 x 4.
    /// A piece can rest on any face, so the footprint is compared with each pair of the shape's three extents.
    func sizeLogPrior(longMm: Float, shortMm: Float) -> [Float] {
        classes.map { shape in
            guard shape.sizeMm.count == 3, longMm > 0 else { return 0 }
            let a = shape.sizeMm[0], b = shape.sizeMm[1], c = shape.sizeMm[2]
            var best: Float = -.infinity
            for (long, short) in [(a, b), (a, c), (b, c)] {
                let sl = max(3, 0.15 * long), ss = max(3, 0.2 * short)
                let dl = (longMm - long) / sl, ds = (shortMm - short) / ss
                best = max(best, -0.5 * (dl * dl + 0.5 * ds * ds))   // the short side is measured less reliably
            }
            return max(best, -6)   // never rule a shape out on size alone
        }
    }

    static func logSoftmax(_ values: [Float]) -> [Float] {
        guard let peak = values.max() else { return [] }
        var sum: Float = 0
        for v in values { sum += exp(v - peak) }
        let offset = peak + log(sum)
        return values.map { $0 - offset }
    }
}
