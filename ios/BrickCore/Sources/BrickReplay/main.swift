import BrickCore
import Foundation

let usage = """
Usage: brick-replay <sweep folder> [--detector colour|truth|maps] [--manifest <manifest.json>] [--out <report.json>] [--match one|frame] [--list]

Plays a sweep rendered by ml/render_sweep.py through the app's scan pipeline (detect, place on the table, track,
count once) and compares the pieces it counts with the pieces really on the table.

  --detector colour   the colour threshold the app uses without a trained model (default)
             truth    perfect detection from the per-frame piece maps (render the sweep with --ids)
             maps     the trained detector's output per frame, NNNN.maps (ml/sweep_maps.py)
  --manifest          ml/manifest.json, for true sizes when the sweep does not record them
  --out               where to write the report as JSON (default: <sweep folder>/replay-<detector>.json)
  --match one         match each detection to known pieces one at a time, as the app does (default)
          frame       match a frame's detections all at once, closest pairs first (PieceTracker.observe(frame:))
  --list              also list every piece
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
    case "-h", "--help": print(usage); exit(0)
    default:
        guard folderPath == nil, !argument.hasPrefix("-") else { fail("unexpected \(argument)\n\n\(usage)") }
        folderPath = argument
    }
}
guard let folderPath else { fail(usage) }

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
    let out = outPath.map { URL(fileURLWithPath: $0) } ?? folder.url.appendingPathComponent("replay-\(detector.rawValue)\(settings.matchWholeFrame ? "-frame" : "").json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: out)
    print("\nReport written to \(out.path)")
} catch {
    fail("brick-replay: \(error)")
}
