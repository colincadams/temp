import Foundation

/// A replay's results by how tall the pieces are: tall pieces slide as the camera moves and look longer than they are.
public enum HeightReport {
    public struct Band: Codable, Equatable {
        /// True height range, millimetres: `low ..< high`.
        public var low: Float
        public var high: Float
        public var pieces = 0
        public var couldBeSeen = 0
        public var found = 0
        public var countedTwice = 0
        /// True pieces in the band that were merged into a neighbour, or had a neighbour merged into them.
        public var merged = 0
        /// Measured over true length, middle value, over pieces found and not merged.
        public var lengthRatio: Float?
        public var lengthCount = 0
        /// Height the tracker estimated, middle value (mm), and the true height's middle value, over the same pieces.
        public var measuredHeight: Float?
        public var trueHeight: Float?
    }

    public static let edges: [Float] = [0, 6, 10, 20, .infinity]

    public static func bands(report: ReplayScoring.Report, run: ReplayRunner.Run, sweep: ReplaySweep) -> [Band] {
        let confirmed = run.tracked.filter { $0.confirmed }
        let heightOf = Dictionary(sweep.pieces.map { ($0.id, $0.heightMm ?? 0) }, uniquingKeysWith: { a, _ in a })
        var bands = zip(edges, edges.dropFirst()).map { Band(low: $0, high: $1) }
        func band(_ height: Float) -> Int? { bands.firstIndex { height >= $0.low && height < $0.high } }
        var ratios = [[Float]](repeating: [], count: bands.count)
        var measured = [[Float]](repeating: [], count: bands.count)
        var truths = [[Float]](repeating: [], count: bands.count)
        for row in report.pieces {
            guard let b = band(heightOf[row.id] ?? 0) else { continue }
            bands[b].pieces += 1
            if row.couldBeSeen { bands[b].couldBeSeen += 1 }
            if row.couldBeSeen && row.outcome == .found { bands[b].found += 1 }
            if row.outcome == .merged { bands[b].merged += 1 }
            guard row.outcome == .found, let t = row.tracked else { continue }
            if report.trackedPieces[t].verdict == .merged { bands[b].merged += 1; continue }
            if let truth = row.trueLongMm, let m = row.measuredLongMm, truth > 0 { ratios[b].append(m / truth) }
            if t < confirmed.count, let h = confirmed[t].heightMm {
                measured[b].append(h)
                truths[b].append(heightOf[row.id] ?? 0)
            }
        }
        for row in report.trackedPieces where row.verdict == .countedTwice {
            if let first = row.truePieces.first, let b = band(heightOf[first] ?? 0) { bands[b].countedTwice += 1 }
        }
        for b in bands.indices {
            if !ratios[b].isEmpty { bands[b].lengthRatio = TableMath.median(ratios[b]); bands[b].lengthCount = ratios[b].count }
            if !measured[b].isEmpty {
                bands[b].measuredHeight = TableMath.median(measured[b])
                bands[b].trueHeight = TableMath.median(truths[b])
            }
        }
        return bands
    }

    public static func text(_ bands: [Band]) -> String {
        func f(_ v: Float?, _ digits: Int = 2) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "-" }
        var lines = ["By true height (mm): pieces, could be seen, found, counted twice, merged, length measured/true (pieces), height estimated/true (middle values)"]
        for b in bands {
            let range = b.high.isInfinite ? "\(Int(b.low))+" : "\(Int(b.low))-\(Int(b.high))"
            lines.append("  \(range.padding(toLength: 6, withPad: " ", startingAt: 0))\t\(b.pieces)\t\(b.couldBeSeen)\t\(b.found)\t\(b.countedTwice)\t\(b.merged)"
                         + "\t\(f(b.lengthRatio)) (\(b.lengthCount))\t\(f(b.measuredHeight, 1))/\(f(b.trueHeight, 1))")
        }
        return lines.joined(separator: "\n")
    }
}
