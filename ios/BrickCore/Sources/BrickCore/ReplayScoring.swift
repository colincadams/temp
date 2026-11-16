import Foundation

/// Compares the pieces a replayed scan counted with the pieces really on the table.
///
/// Matching: a counted piece and a true piece can be paired when the counted position lies within the true piece's
/// tolerance (its radius, at least `minToleranceMm`). Pairs are made one to one, nearest first. Then:
/// - an unpaired counted piece within tolerance of a true piece that already has its pair is that piece **counted twice**;
/// - a counted piece whose measured outline (half its measured length around its position) reaches the middle of
///   other true pieces left unpaired has **merged** them (they are then "missed, merged into a neighbour"); an unpaired
///   counted piece merges when it reaches two or more;
/// - any other unpaired counted piece is a **phantom**.
public enum ReplayScoring {
    public struct Settings {
        public var minToleranceMm: Float = 8
        /// Processed frames that must show a piece whole for it to count as one the scan could have found.
        public var minWholeFrames = 3

        public init() {}
    }

    /// What one tracked piece turned out to be.
    public enum Verdict: String, Codable {
        case found
        case countedTwice = "counted twice"
        case merged
        case phantom
    }

    /// What became of one true piece.
    public enum Outcome: String, Codable {
        case found
        case merged = "missed, merged into a neighbour"
        case missed
    }

    public struct TruePieceRow: Codable, Equatable {
        public var id: Int
        public var partNum: String
        public var wholeFrames: Int
        public var couldBeSeen: Bool
        public var outcome: Outcome
        /// Index into `Report.trackedPieces` of the piece it was paired with or merged into.
        public var tracked: Int?
        public var distanceMm: Float?
        public var trueLongMm: Float?
        public var trueShortMm: Float?
        public var measuredLongMm: Float?
        public var measuredShortMm: Float?
        public var trueRGB: String?
        public var measuredRGB: String?
    }

    public struct TrackedRow: Codable, Equatable {
        public var x: Float
        public var z: Float
        public var longMm: Float
        public var shortMm: Float
        public var rgb: String
        public var sightings: Int
        public var verdict: Verdict
        /// True pieces it was paired with (first) or merged.
        public var truePieces: [Int]
    }

    public struct Summary: Codable, Equatable {
        public var count = 0
        public var mean: Float = 0
        public var median: Float = 0
        public var meanAbsolute: Float = 0
    }

    public struct Report: Codable, Equatable {
        public var detector: String
        public var framesInSweep: Int
        public var framesProcessed: Int
        public var framesSkipped: [String: Int]
        public var visibilityMethod: String
        public var matching: String
        public var minWholeFrames: Int

        public var piecesOnTable: Int
        public var piecesCouldBeSeen: Int
        public var piecesCounted: Int
        public var unconfirmedLeft: Int

        /// Of the pieces that could be seen.
        public var found: Int
        public var missed: Int
        public var missedMergedIntoNeighbour: Int
        /// True pieces found that were not seen whole often enough to count against the scan.
        public var foundOutsideFairSet: Int
        /// Counted pieces.
        public var countedTwice: Int
        public var merged: Int
        public var phantom: Int

        /// Measured minus true, millimetres, over pieces found and not merged.
        public var lengthSource: String
        public var longError: Summary
        public var shortError: Summary
        /// Measured length over true length.
        public var longRatio: Summary
        /// Measured lengths, whatever the truth source.
        public var measuredLong: Summary
        /// Distance in RGB (0-255 per channel) between measured and true colour; mean per-channel measured minus true.
        public var colourDistance: Summary
        public var colourBias: [Float]?
        /// Distance between counted and true position, millimetres.
        public var positionError: Summary

        public var pieces: [TruePieceRow]
        public var trackedPieces: [TrackedRow]

        /// The techniques switched on for the run (`ReplayRunner.Run.techniques`).
        public var techniques: [String]?
        /// Confirmed pieces left out of the count by negative evidence, and by the end-of-scan consolidation.
        public var setAsideDoubtful: SetAside?
        public var setAsideMerged: SetAside?
        /// Negative evidence: of the views that showed a counted real piece well inside the frame, the share in which
        /// it was not detected (what `VisibilityLedger.Settings.detectorMissRate` should be).
        public var realPieceMissRate: Float?
        /// One minus detections per true piece shown whole, over all processed frames: the per-view miss rate of the
        /// detector over every piece, including the ones it never tracked (a merged blob is one detection for two).
        public var viewMissRate: Float?
        /// Phantom detections injected, and how many of the scan's counted phantoms are those.
        public var phantomsInjected: Int?
        /// Sharpness: frames the gate rejected, milliseconds per frame spent on it, and, if the sweep records motion
        /// blur, how many processed frames were blurred and how many counted pieces got their best view from one.
        public var framesRejectedBlurred: Int?
        public var sharpnessFrameMs: Double?
        public var sharpnessRegionsMs: Double?
        public var blurredFramesProcessed: Int?
        public var bestViewBlurred: Int?
    }

    /// What the confirmed pieces left out of the count turned out to be.
    public struct SetAside: Codable, Equatable {
        public var pieces = 0
        /// A second track of a true piece that the count still has: rightly left out.
        public var duplicate = 0
        /// Nothing there: rightly left out.
        public var phantom = 0
        /// The only track of a true piece: wrongly left out, the piece is now missed.
        public var realPieceLost = 0
    }

    /// A frame counts as blurred for the report when its smear is at least this many working pixels.
    public static let blurredFromPx: Float = 2

    static func summary(_ values: [Float]) -> Summary {
        guard !values.isEmpty else { return Summary() }
        let n = Float(values.count)
        return Summary(count: values.count, mean: values.reduce(0, +) / n, median: TableMath.median(values),
                       meanAbsolute: values.map { abs($0) }.reduce(0, +) / n)
    }

    static func rgb(_ hex: String?) -> SIMD3<Float>? {
        guard let hex, hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return SIMD3(Float(v >> 16 & 255), Float(v >> 8 & 255), Float(v & 255))
    }

    /// - Parameters:
    ///   - truth: the pieces on the table.
    ///   - tracked: the pieces the scan counted (confirmed only).
    ///   - wholeFrames: per true piece id, processed frames that showed it whole.
    ///   - catalogSize: true extents (mm, largest first) by shape class id, used when the sweep has no footprint size.
    public static func score(truth: [ReplaySweep.Piece], tracked: [ReplayRunner.TrackedResult], wholeFrames: [Int: Int],
                             catalogSize: [Int: [Float]] = [:], settings: Settings = Settings()) -> (pieces: [TruePieceRow], tracked: [TrackedRow]) {
        func distanceMm(_ t: ReplayRunner.TrackedResult, _ p: ReplaySweep.Piece) -> Float {
            let dx = t.x - p.x, dz = t.z - p.z
            return (dx * dx + dz * dz).squareRoot() * 1000
        }
        func tolerance(_ p: ReplaySweep.Piece) -> Float { max(settings.minToleranceMm, p.radiusMm) }

        // One to one, nearest first.
        var pairs: [(t: Int, p: Int, d: Float)] = []
        for (ti, t) in tracked.enumerated() {
            for (pi, p) in truth.enumerated() {
                let d = distanceMm(t, p)
                if d <= tolerance(p) { pairs.append((ti, pi, d)) }
            }
        }
        pairs.sort { $0.d != $1.d ? $0.d < $1.d : ($0.t, $0.p) < ($1.t, $1.p) }
        var pairOfTracked = [Int?](repeating: nil, count: tracked.count)
        var pairOfTrue = [Int?](repeating: nil, count: truth.count)
        for pair in pairs where pairOfTracked[pair.t] == nil && pairOfTrue[pair.p] == nil {
            pairOfTracked[pair.t] = pair.p
            pairOfTrue[pair.p] = pair.t
        }

        var mergedInto = [Int?](repeating: nil, count: truth.count)
        var verdicts = [Verdict](repeating: .phantom, count: tracked.count)
        var covers = [[Int]](repeating: [], count: tracked.count)
        /// Unpaired, unclaimed true pieces whose middle lies within `reach` of the tracked piece.
        func reached(_ ti: Int, extra: (ReplaySweep.Piece) -> Float) -> [Int] {
            let t = tracked[ti]
            return truth.indices.filter { pi in
                pairOfTrue[pi] == nil && mergedInto[pi] == nil
                    && distanceMm(t, truth[pi]) <= max(t.longMm / 2, extra(truth[pi]))
            }.sorted { distanceMm(t, truth[$0]) < distanceMm(t, truth[$1]) }
        }

        // Paired pieces first: found, or merged with unpaired neighbours under the same outline.
        for ti in tracked.indices {
            guard let pi = pairOfTracked[ti] else { continue }
            let others = reached(ti) { _ in 0 }
            verdicts[ti] = others.isEmpty ? .found : .merged
            covers[ti] = [pi] + others
            for other in others { mergedInto[other] = ti }
        }
        // Then the unpaired ones.
        for ti in tracked.indices where pairOfTracked[ti] == nil {
            let t = tracked[ti]
            let twin = truth.indices.filter { pairOfTrue[$0] != nil && distanceMm(t, truth[$0]) <= tolerance(truth[$0]) }
                .min { distanceMm(t, truth[$0]) < distanceMm(t, truth[$1]) }
            if let twin {
                verdicts[ti] = .countedTwice
                covers[ti] = [twin]
                continue
            }
            let reach = reached(ti) { tolerance($0) }
            if reach.count >= 2 {
                verdicts[ti] = .merged
                covers[ti] = reach
                for other in reach { mergedInto[other] = ti }
            }
        }

        let pieceRows: [TruePieceRow] = truth.enumerated().map { pi, p in
            let frames = wholeFrames[p.id] ?? 0
            var row = TruePieceRow(id: p.id, partNum: p.partNum, wholeFrames: frames, couldBeSeen: frames >= settings.minWholeFrames,
                                   outcome: .missed, tracked: nil, distanceMm: nil,
                                   trueLongMm: p.longMm ?? p.classId.flatMap { catalogSize[$0]?.first },
                                   trueShortMm: p.longMm != nil ? p.shortMm : p.classId.flatMap { catalogSize[$0].flatMap { $0.count > 1 ? $0[1] : nil } },
                                   measuredLongMm: nil, measuredShortMm: nil, trueRGB: p.rgb, measuredRGB: nil)
            let ti = pairOfTrue[pi] ?? mergedInto[pi]
            if let ti {
                let t = tracked[ti]
                row.outcome = pairOfTrue[pi] != nil ? .found : .merged
                row.tracked = ti
                row.distanceMm = distanceMm(t, p)
                row.measuredLongMm = t.longMm
                row.measuredShortMm = t.shortMm
                row.measuredRGB = t.rgb
            }
            return row
        }
        let trackedRows: [TrackedRow] = tracked.enumerated().map { ti, t in
            TrackedRow(x: t.x, z: t.z, longMm: t.longMm, shortMm: t.shortMm, rgb: t.rgb, sightings: t.sightings,
                       verdict: verdicts[ti], truePieces: covers[ti].map { truth[$0].id })
        }
        return (pieceRows, trackedRows)
    }

    /// Score a finished replay.
    public static func report(sweep: ReplaySweep, run: ReplayRunner.Run, detector: ReplayDetector,
                              catalogSize: [Int: [Float]] = [:], settings: Settings = Settings()) -> Report {
        let confirmed = run.tracked.filter { $0.counted }
        let (pieces, tracked) = score(truth: sweep.pieces, tracked: confirmed, wholeFrames: run.wholeFrames,
                                      catalogSize: catalogSize, settings: settings)
        /// What the left-out tracks were, judged against the final count.
        func setAside(_ rows: [ReplayRunner.TrackedResult]) -> SetAside {
            var out = SetAside()
            let foundIDs = Set(pieces.filter { $0.outcome == .found }.map { $0.id })
            for t in rows {
                out.pieces += 1
                let near = sweep.pieces.filter { p in
                    let dx = t.x - p.x, dz = t.z - p.z
                    return (dx * dx + dz * dz).squareRoot() * 1000 <= max(settings.minToleranceMm, p.radiusMm)
                }
                if near.isEmpty { out.phantom += 1 }
                else if near.contains(where: { foundIDs.contains($0.id) }) { out.duplicate += 1 }
                else { out.realPieceLost += 1 }
            }
            return out
        }
        var skipped: [String: Int] = [:]
        for frame in run.frames { if let reason = frame.skipped { skipped[reason, default: 0] += 1 } }
        let fair = pieces.filter { $0.couldBeSeen }

        // Sizes and colours over pieces found and not merged with others.
        let clean = pieces.filter { row in row.outcome == .found && row.tracked.map { tracked[$0].verdict == .found } == true }
        var longErrors: [Float] = [], shortErrors: [Float] = [], ratios: [Float] = [], colours: [Float] = []
        var bias = SIMD3<Float>(repeating: 0)
        for row in clean {
            if let truth = row.trueLongMm, let measured = row.measuredLongMm, truth > 0 {
                longErrors.append(measured - truth)
                ratios.append(measured / truth)
            }
            if let truth = row.trueShortMm, let measured = row.measuredShortMm { shortErrors.append(measured - truth) }
            if let truth = rgb(row.trueRGB), let measured = rgb(row.measuredRGB) {
                let d = measured - truth
                colours.append((d * d).sum().squareRoot())
                bias += d
            }
        }
        let lengthSource = sweep.pieces.contains { $0.longMm != nil } ? "footprint from the renderer"
            : catalogSize.isEmpty ? "none" : "catalog size (largest extent; a piece on its side shows another)"

        var report = Report(
            detector: detector.rawValue,
            framesInSweep: run.frames.count,
            framesProcessed: run.frames.filter { $0.skipped == nil }.count,
            framesSkipped: skipped,
            visibilityMethod: run.visibilityMethod,
            matching: run.matching,
            minWholeFrames: settings.minWholeFrames,
            piecesOnTable: sweep.pieces.count,
            piecesCouldBeSeen: fair.count,
            piecesCounted: confirmed.count,
            unconfirmedLeft: run.tracked.filter { !$0.confirmed }.count,
            found: fair.filter { $0.outcome == .found }.count,
            missed: fair.filter { $0.outcome != .found }.count,
            missedMergedIntoNeighbour: fair.filter { $0.outcome == .merged }.count,
            foundOutsideFairSet: pieces.filter { !$0.couldBeSeen && $0.outcome == .found }.count,
            countedTwice: tracked.filter { $0.verdict == .countedTwice }.count,
            merged: tracked.filter { $0.verdict == .merged }.count,
            phantom: tracked.filter { $0.verdict == .phantom }.count,
            lengthSource: lengthSource,
            longError: summary(longErrors),
            shortError: summary(shortErrors),
            longRatio: summary(ratios),
            measuredLong: summary(tracked.filter { $0.verdict == .found }.map { $0.longMm }),
            colourDistance: summary(colours),
            colourBias: colours.isEmpty ? nil : [bias.x, bias.y, bias.z].map { $0 / Float(colours.count) },
            positionError: summary(clean.compactMap { $0.distanceMm }),
            pieces: pieces,
            trackedPieces: tracked)

        if !run.techniques.isEmpty { report.techniques = run.techniques }
        let techniques = Set(run.techniques)
        if techniques.contains("negative evidence") {
            report.setAsideDoubtful = setAside(run.tracked.filter { $0.confirmed && $0.doubtful })
            var hits = 0, misses = 0
            for (row, t) in zip(tracked, confirmed) where row.verdict == .found {
                hits += t.hits ?? 0
                misses += t.misses ?? 0
            }
            if hits + misses > 0 { report.realPieceMissRate = Float(misses) / Float(hits + misses) }
            let processed = run.frames.filter { $0.skipped == nil }
            let inView = processed.reduce(0) { $0 + $1.wholePieces.count }
            let observed = processed.reduce(0) { $0 + $1.observations - $1.phantoms }
            if inView > 0 { report.viewMissRate = max(0, 1 - Float(observed) / Float(inView)) }
        }
        if techniques.contains("consolidation") {
            report.setAsideMerged = setAside(run.tracked.filter { $0.confirmed && !$0.doubtful && $0.absorbed })
        }
        if run.phantomsPlaced > 0 { report.phantomsInjected = run.phantomsPlaced }
        if techniques.contains("sharpness gate") {
            report.framesRejectedBlurred = run.frames.filter { $0.skipped == ReplayRunner.skippedBlurred }.count
        }
        report.sharpnessFrameMs = run.sharpnessFrameMs
        report.sharpnessRegionsMs = run.sharpnessRegionsMs
        if run.frames.contains(where: { $0.blurPx != nil }) {
            report.blurredFramesProcessed = run.frames.filter { $0.skipped == nil && ($0.blurPx ?? 0) >= blurredFromPx }.count
            report.bestViewBlurred = confirmed.filter { ($0.bestViewBlurPx ?? 0) >= blurredFromPx }.count
        }
        return report
    }

    /// The report in plain words.
    public static func text(_ r: Report, listPieces: Bool = false) -> String {
        func f(_ v: Float, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
        func pct(_ a: Int, _ b: Int) -> String { b > 0 ? " (\(f(Float(a) * 100 / Float(b), 0))%)" : "" }
        var lines: [String] = []
        lines.append("Detector: \(r.detector); detections matched to known pieces \(r.matching)")
        if let techniques = r.techniques { lines.append("With: \(techniques.joined(separator: ", "))") }
        let skipped = r.framesSkipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        lines.append("Frames: \(r.framesInSweep) in the sweep, \(r.framesProcessed) processed" + (skipped.isEmpty ? "" : "; skipped: \(skipped)"))
        lines.append("")
        lines.append("Pieces on the table:                 \(r.piecesOnTable)")
        lines.append("Seen whole in \(r.minWholeFrames)+ processed frames:  \(r.piecesCouldBeSeen)   (the pieces the scan could have found; decided by \(r.visibilityMethod))")
        lines.append("Pieces the scan counted:             \(r.piecesCounted)" + (r.unconfirmedLeft > 0 ? "   (plus \(r.unconfirmedLeft) seen too few times to count)" : ""))
        lines.append("")
        lines.append("Of the \(r.piecesCouldBeSeen) pieces it could have found:")
        lines.append("  found                              \(r.found)\(pct(r.found, r.piecesCouldBeSeen))")
        lines.append("  missed                             \(r.missed)\(pct(r.missed, r.piecesCouldBeSeen))"
                     + (r.missedMergedIntoNeighbour > 0 ? "   (\(r.missedMergedIntoNeighbour) of them merged into a neighbour)" : ""))
        if r.foundOutsideFairSet > 0 {
            lines.append("  also found, though seen whole fewer times: \(r.foundOutsideFairSet)")
        }
        lines.append("Of the \(r.piecesCounted) pieces it counted:")
        lines.append("  a real piece, once                 \(r.trackedPieces.filter { $0.verdict == .found }.count)")
        lines.append("  a piece counted twice              \(r.countedTwice)")
        lines.append("  two or more pieces taken as one    \(r.merged)")
        lines.append("  nothing there (phantom)            \(r.phantom)" + (r.phantomsInjected.map { "   (\($0) phantom detections were injected)" } ?? ""))
        func setAsideLine(_ s: SetAside) -> String {
            "\(s.pieces): \(s.duplicate) a piece's second track, \(s.phantom) nothing there, \(s.realPieceLost) a real piece now missed"
        }
        if let s = r.setAsideDoubtful {
            lines.append("Left out as doubtful (negative evidence): \(setAsideLine(s))"
                         + (r.realPieceMissRate.map { "; counted real pieces were missed in \(f($0 * 100, 0))% of the views that showed them well" } ?? "")
                         + (r.viewMissRate.map { "; detections per piece in view fall \(f($0 * 100, 0))% short" } ?? ""))
        }
        if let s = r.setAsideMerged { lines.append("Merged at the end (consolidation):        \(setAsideLine(s))") }
        if let rejected = r.framesRejectedBlurred {
            lines.append("Frames rejected as blurred: \(rejected)" + (r.sharpnessFrameMs.map { String(format: "; sharpness cost %.3f ms per frame", $0) } ?? ""))
        }
        if let ms = r.sharpnessRegionsMs { lines.append(String(format: "Piece-region sharpness: %.3f ms per processed frame", ms)) }
        if let blurred = r.blurredFramesProcessed {
            lines.append("Blurred frames processed (smear of \(f(blurredFromPx, 0))+ px): \(blurred); counted pieces whose best view is a blurred frame: \(r.bestViewBlurred ?? 0)")
        }
        lines.append("")
        if r.longError.count > 0 {
            lines.append("Length, measured minus true (\(r.lengthSource)), over \(r.longError.count) pieces found:")
            lines.append("  long side:  average \(f(r.longError.mean)) mm, middle value \(f(r.longError.median)) mm, typical size of the error \(f(r.longError.meanAbsolute)) mm;"
                         + " measured/true \(f(r.longRatio.median, 2)) (middle value)")
            if r.shortError.count > 0 {
                lines.append("  short side: average \(f(r.shortError.mean)) mm, middle value \(f(r.shortError.median)) mm, typical size of the error \(f(r.shortError.meanAbsolute)) mm")
            }
        } else if r.measuredLong.count > 0 {
            lines.append("Measured length (no true sizes available): average \(f(r.measuredLong.mean)) mm, middle value \(f(r.measuredLong.median)) mm")
        }
        if r.positionError.count > 0 {
            lines.append("Position, distance from the true spot: average \(f(r.positionError.mean)) mm, middle value \(f(r.positionError.median)) mm")
        }
        if r.colourDistance.count > 0, let b = r.colourBias {
            lines.append("Colour, distance from the catalog colour (0-255 per channel): average \(f(r.colourDistance.mean, 0)), middle value \(f(r.colourDistance.median, 0));"
                         + " measured minus true on average: red \(f(b[0], 0)), green \(f(b[1], 0)), blue \(f(b[2], 0))")
        }
        if listPieces {
            lines.append("")
            lines.append("Every piece on the table (id, part, frames seen whole, outcome, distance, length measured/true):")
            for p in r.pieces {
                let d = p.distanceMm.map { "\(f($0)) mm" } ?? "-"
                let len = p.measuredLongMm.map { "\(f($0))/\(p.trueLongMm.map { f($0) } ?? "?")" } ?? "-"
                lines.append("  \(p.id)\t\(p.partNum)\t\(p.wholeFrames)\t\(p.outcome.rawValue)\t\(d)\t\(len)")
            }
            lines.append("Every piece counted (position x,z in mm, length, sightings, verdict, true pieces):")
            for (i, t) in r.trackedPieces.enumerated() {
                lines.append("  #\(i)\t\(f(t.x * 1000)),\(f(t.z * 1000))\t\(f(t.longMm)) mm\t\(t.sightings)\t\(t.verdict.rawValue)\t\(t.truePieces)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
