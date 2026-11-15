import Foundation

/// One shape the recognition model knows, as written by `ml/export.py`.
public struct ShapeClass: Codable, Equatable {
    public let partNum: String
    public let name: String
    /// Every catalog part number with this shape (prints and mould variants).
    public let members: [String]
    /// Bounding-box extents in millimetres, largest first.
    public let sizeMm: [Float]

    public init(partNum: String, name: String, members: [String], sizeMm: [Float]) {
        self.partNum = partNum
        self.name = name
        self.members = members
        self.sizeMm = sizeMm
    }
}

/// One entry of a fused recognition result.
public struct FusedShape: Equatable {
    /// Position of the shape in the model's class list.
    public let index: Int
    public let shape: ShapeClass
    public let probability: Double

    public init(index: Int, shape: ShapeClass, probability: Double) {
        self.index = index
        self.shape = shape
        self.probability = probability
    }
}

/// Combines the recognition model's output over several views of a piece with the piece's measured size.
public enum ShapeFusion {
    public static func logSoftmax(_ values: [Float]) -> [Float] {
        guard let peak = values.max() else { return [] }
        var sum: Float = 0
        for v in values { sum += exp(v - peak) }
        let offset = peak + log(sum)
        return values.map { $0 - offset }
    }

    /// How well each shape's true dimensions fit a measured footprint, as a log-likelihood.
    ///
    /// A crop is resized before recognition, so the image alone cannot tell a 1 x 2 plate from a 1 x 4.
    /// A piece can rest on any face, so the footprint is compared with each pair of the shape's three extents.
    public static func sizeLogPrior(classes: [ShapeClass], longMm: Float, shortMm: Float) -> [Float] {
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

    /// The most likely shapes for a piece, best first: views averaged, then weighed against its measured size.
    ///
    /// - Parameters:
    ///   - logSum: per-shape log-probabilities added up over `views` views.
    ///   - limit: how many shapes to return at most.
    /// - Returns: empty if there are no views or `logSum` does not match `classes`.
    public static func fuse(logSum: [Float], views: Int, classes: [ShapeClass],
                            longMm: Float, shortMm: Float, limit: Int = 4) -> [FusedShape] {
        guard views > 0, !classes.isEmpty, logSum.count == classes.count else { return [] }
        let prior = sizeLogPrior(classes: classes, longMm: longMm, shortMm: shortMm)
        var scores = [Float](repeating: 0, count: prior.count)
        // Averaging rather than summing keeps near-identical views from producing false certainty.
        for i in 0..<scores.count { scores[i] = logSum[i] / Float(views) + prior[i] }
        let logProbabilities = logSoftmax(scores)
        // Ties keep class-list order so the result does not depend on the sort's internals.
        let order = logProbabilities.indices
            .sorted { logProbabilities[$0] != logProbabilities[$1] ? logProbabilities[$0] > logProbabilities[$1] : $0 < $1 }
            .prefix(max(0, limit))
        return order.map { FusedShape(index: $0, shape: classes[$0], probability: Double(exp(logProbabilities[$0]))) }
    }
}
