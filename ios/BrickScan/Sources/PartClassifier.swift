import BrickCore
import CoreImage
import CoreML
import CoreVideo
import Foundation

/// The class list written by `ml/export.py`. `ShapeClass` is defined in BrickCore.
private struct ClassFile: Codable {
    let imageSize: Int
    let classes: [ShapeClass]
}

/// What the bundled `classes.json` says about each shape's part: name, picture and colours (`OfflineCatalog`,
/// in BrickCore), so pieces can be described without the server. Read once, on first use.
enum BundledParts {
    static let catalog: OfflineCatalog? = {
        guard Bundle.main.url(forResource: "PartNet", withExtension: "mlmodelc") != nil,
              let url = Bundle.main.url(forResource: "classes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = OfflineCatalog.decode(data), !catalog.isEmpty else { return nil }
        return catalog
    }()

    /// True when the phone can recognise and describe pieces by itself, so a scan can be finished offline.
    static var available: Bool { catalog != nil }
}

/// Runs the part recognition model on the phone.
///
/// The model and class list are optional resources (`PartNet.mlpackage` and `classes.json` in `Sources/Model/`).
/// Without them `init` returns nil and the app falls back to the server's recognition service.
/// Not thread-safe: use from one queue.
final class PartClassifier {
    let classes: [ShapeClass]
    /// Names, pictures and colours of the shapes' parts, when the class file carries them.
    let offline: OfflineCatalog?
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
        self.offline = BundledParts.catalog
        self.imageSize = file.imageSize
        self.model = model
        self.context = context
        self.input = buffer
    }

    /// Log-probability of each shape for one square crop of a piece. `ShapeFusion.fuse` combines them across views.
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
        return ShapeFusion.logSoftmax(logits)
    }
}
