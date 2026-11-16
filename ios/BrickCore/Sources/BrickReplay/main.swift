import BrickCore
import Foundation

let usage = """
Usage: brick-replay <sweep folder> [--detector colour|truth|maps] [--manifest <manifest.json>] [--out <report.json>] [--match one|frame] [--list] [--depth on|off]
       [--sharpness off|gate|views|on] [--negative-evidence [--miss-rate <r>]] [--consolidate] [--phantoms <n>] [--phantom-seed <n>]
       [--drift <mm> [--drift-at <frame>]] [--anchors] [--hand [--hand-at <frame>] [--hand-masking]]

Plays a sweep rendered by ml/render_sweep.py through the app's scan pipeline (detect, place on the table, track,
count once) and compares the pieces it counts with the pieces really on the table.

  --detector colour   the colour threshold the app uses without a trained model (default)
             truth    perfect detection from the per-frame piece maps (render the sweep with --ids)
             maps     the trained detector's output per frame, NNNN.maps (ml/sweep_maps.py)
  --manifest          ml/manifest.json, for true sizes when the sweep does not record them
  --out               where to write the report as JSON (default: <sweep folder>/replay-<detector>.json)
  --match one         match each detection to known pieces one at a time (default; the app used to)
          frame       match a frame's detections all at once, closest pairs first, as the app does (PieceTracker.observe(frame:))
  --list              also list every piece
  --depth on          measure each piece's height from the sweep's LiDAR depth maps (render_sweep.py --depth), as a
                      phone with LiDAR does
          off         work from the pictures alone, as a phone without LiDAR does (default)

Techniques the app uses, off in the replay unless asked for (the report file name gains a suffix for each):
  --sharpness gate    skip frames much less sharp than the recent ones (SharpnessGate)
              views   fold each piece's region sharpness into its view quality, so its best view is a sharp one
              on      both
  --negative-evidence leave out pieces the camera keeps looking at without finding (VisibilityLedger)
  --consolidate       merge tracks that are probably one piece when the scan ends (TrackConsolidation)
  --miss-rate <r>     the detector's miss rate negative evidence assumes (default 0.6 for colour, 0.2 otherwise)
  --phantoms <n>      inject n phantom detections, each in 3 processed frames and never again (--phantom-seed, default 1)

ARKit's map drift (DriftSimulation):
  --drift <mm>        the reported world starts the sweep drifted by this much (a shift, and a turn of 0.25 degrees per cm),
                      as after a long scan, plus 1% of the camera's travel; ARKit corrects its map at the middle frame (the
                      first of the second row) or --drift-at <frame>, and drifts by 1% of travel again after
  --hand              a hand put down on the table (a 4 cm disc in the middle of the pieces) two thirds of the way through,
                      or at --hand-at <frame>: it hides the pieces under it, and a fingertip is detected as a piece
  --hand-masking      use the hand's person mask as the app does: drop detections under it, no misses for hidden pieces
  --anchors           store each piece against an anchor made near it (AnchorSet) and move it with the anchor, as the app does
  --anchor-reach <m>, --anchor-travel <m>   how near (default 0.10) and how recently in camera travel (0.15) an anchor
                      must have been made for a new piece to be stored against it
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var folderPath: String?
var detector = ReplayDetector.colour
var manifestPath: String?
var outPath: String?
var listPieces = false
var settings = ReplayRunner.Settings()
var missRate: Float?
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("\(argument) needs a value\n\n\(usage)") }
        return arguments.removeFirst()
    }
    switch argument {
    case "--detector":
        let name = value()
        guard let kind = ReplayDetector(rawValue: name) else { fail("unknown detector \(name)\n\n\(usage)") }
        detector = kind
    case "--manifest": manifestPath = value()
    case "--out": outPath = value()
    case "--match":
        switch value() {
        case "one": settings.matchWholeFrame = false
        case "frame": settings.matchWholeFrame = true
        default: fail("--match takes one or frame\n\n\(usage)")
        }
    case "--list": listPieces = true
    case "--depth":
        switch value() {
        case "on": settings.useDepth = true
        case "off": settings.useDepth = false
        default: fail("--depth takes on or off\n\n\(usage)")
        }
    case "--sharpness":
        switch value() {
        case "off": settings.sharpnessGate = false; settings.sharpnessViews = false
        case "gate": settings.sharpnessGate = true; settings.sharpnessViews = false
        case "views": settings.sharpnessGate = false; settings.sharpnessViews = true
        case "on": settings.sharpnessGate = true; settings.sharpnessViews = true
        default: fail("--sharpness takes off, gate, views or on\n\n\(usage)")
        }
    case "--negative-evidence": settings.negativeEvidence = true
    case "--miss-rate":
        guard let rate = Float(value()), rate > 0, rate < 1 else { fail("--miss-rate takes a number between 0 and 1\n\n\(usage)") }
        missRate = rate
    case "--consolidate": settings.consolidate = true
    case "--phantoms":
        guard let n = Int(value()), n >= 0 else { fail("--phantoms takes a number\n\n\(usage)") }
        settings.phantoms = n
    case "--phantom-seed":
        guard let n = UInt64(value()) else { fail("--phantom-seed takes a number\n\n\(usage)") }
        settings.phantomSeed = n
    case "--drift":
        guard let mm = Float(value()), mm >= 0 else { fail("--drift takes millimetres\n\n\(usage)") }
        var drift = settings.drift ?? DriftSimulation.Settings()
        drift.initialDrift = mm / 1000
        settings.drift = drift
    case "--drift-at":
        guard let frame = Int(value()), frame >= 0 else { fail("--drift-at takes a frame number\n\n\(usage)") }
        var drift = settings.drift ?? DriftSimulation.Settings()
        drift.correctionFrame = frame
        settings.drift = drift
    case "--anchors": settings.anchoring = true
    case "--anchor-reach":
        guard let m = Float(value()), m > 0 else { fail("--anchor-reach takes metres\n\n\(usage)") }
        settings.anchors.reach = m
    case "--anchor-travel":
        guard let m = Float(value()), m > 0 else { fail("--anchor-travel takes metres\n\n\(usage)") }
        settings.anchors.maxTravel = m
    case "--hand": settings.hand = settings.hand ?? HandSimulation()
    case "--hand-at":
        guard let frame = Int(value()), frame >= 0 else { fail("--hand-at takes a frame number\n\n\(usage)") }
        settings.hand = HandSimulation(firstFrame: frame)
    case "--hand-masking": settings.handMasking = true
    case "-h", "--help": print(usage); exit(0)
    default:
        guard folderPath == nil, !argument.hasPrefix("-") else { fail("unexpected \(argument)\n\n\(usage)") }
        folderPath = argument
    }
}
guard let folderPath else { fail(usage) }
// The colour threshold merges touching pieces, so it misses a piece in view far more often than the trained detector.
settings.visibility.detectorMissRate = missRate ?? (detector == .colour ? 0.6 : 0.2)

/// True extents by shape class id, from the manifest written by ml/build_manifest.py.
func loadCatalogSizes(_ path: String) throws -> [Int: [Float]] {
    struct Manifest: Decodable {
        struct Class: Decodable {
            let class_id: Int
            let size_mm: [Float]?
        }
        let classes: [Class]
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var sizes: [Int: [Float]] = [:]
    for c in manifest.classes { if let size = c.size_mm { sizes[c.class_id] = size } }
    return sizes
}

do {
    let folder = try ReplayFolder(url: URL(fileURLWithPath: folderPath))
    let catalogSize = try manifestPath.map(loadCatalogSizes) ?? [:]
    let run = try ReplayRunner.run(folder: folder, detector: detector, settings: settings)
    let report = ReplayScoring.report(sweep: folder.sweep, run: run, detector: detector, catalogSize: catalogSize)
    print(ReplayScoring.text(report, listPieces: listPieces))
    print("\nHeight: " + (settings.useDepth ? "from the LiDAR depth maps" : "from the pictures alone (no depth)"))
    print(HeightReport.text(HeightReport.bands(report: report, run: run, sweep: folder.sweep)))
    if let frame = run.driftCorrectionFrame {
        print(String(format: "\nMap drift: corrected at frame %d; %.1f mm of background drift left at the end (undone before scoring).", frame,
                     (run.driftAtEnd ?? 0) * 1000))
        if settings.anchoring { print("Anchors: \(run.anchorsMade) made, \(run.anchorMoves) piece moves applied.") }
    }
    if settings.hand != nil {
        print("\nHand: in \(run.handFrames) processed frames" + (settings.handMasking ? "; \(run.handDropped) detections dropped by the mask." : "."))
    }
    var suffix = settings.matchWholeFrame ? "-frame" : ""
    if settings.useDepth { suffix += "-depth" }
    if settings.sharpnessGate { suffix += "-sharpgate" }
    if settings.sharpnessViews { suffix += "-sharpviews" }
    if settings.negativeEvidence { suffix += "-negative" }
    if settings.consolidate { suffix += "-consolidate" }
    if settings.phantoms > 0 { suffix += "-phantoms\(settings.phantoms)" }
    if let drift = settings.drift { suffix += "-drift\(Int((drift.initialDrift * 1000).rounded()))" }
    if settings.anchoring { suffix += "-anchors" }
    if settings.hand != nil { suffix += "-hand" }
    if settings.handMasking { suffix += "-masked" }
    let out = outPath.map { URL(fileURLWithPath: $0) } ?? folder.url.appendingPathComponent("replay-\(detector.rawValue)\(suffix).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: out)
    print("\nReport written to \(out.path)")
} catch {
    fail("brick-replay: \(error)")
}
