#if DEBUG
import SwiftUI
import UIKit

// Sample data for Xcode previews only. Nothing here is compiled into a release build
// or used by the running app.

enum SampleData {
    static let red = ColorInfo(id: 4, name: "Red", rgb: "C91A09", isTrans: false)
    static let blue = ColorInfo(id: 1, name: "Blue", rgb: "0055BF", isTrans: false)
    static let yellow = ColorInfo(id: 14, name: "Yellow", rgb: "F2CD37", isTrans: false)
    static let grey = ColorInfo(id: 71, name: "Light Bluish Gray", rgb: "A0A5A9", isTrans: false)

    static func candidate(_ partNum: String, _ name: String, _ score: Double, _ colors: [ColorInfo]) -> Candidate {
        Candidate(partNum: partNum, name: name, img: nil, colors: colors, score: score)
    }

    /// A plain coloured square standing in for a camera crop.
    static func crop(_ color: UIColor) -> Data? {
        let size = CGSize(width: 96, height: 96)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { (context: UIGraphicsImageRendererContext) in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    static func piece(_ candidates: [Candidate], longMm: Float, crop color: UIColor) -> PieceSnapshot {
        PieceSnapshot(id: UUID(), position: SIMD3<Float>(0, 0, 0), state: candidates.isEmpty ? .unknown : .identified,
                      longMm: longMm, thumbnail: crop(color), candidates: candidates)
    }

    static let brick2x4 = candidate("3001", "Brick 2 x 4", 0.96, [red, blue, yellow])
    static let plate1x2 = candidate("3023", "Plate 1 x 2", 0.91, [grey, blue])

    static var confidentScan: [PieceSnapshot] {
        [
            piece([brick2x4], longMm: 31.8, crop: .systemRed),
            piece([brick2x4], longMm: 31.9, crop: .systemRed),
            piece([plate1x2], longMm: 15.9, crop: .systemGray),
        ]
    }

    static var scan: [PieceSnapshot] {
        let unsureBrick = [
            candidate("3003", "Brick 2 x 2", 0.52, [yellow, red]),
            candidate("3002", "Brick 2 x 3", 0.31, [yellow, red]),
            candidate("3001", "Brick 2 x 4", 0.09, [red, blue, yellow]),
        ]
        let unsureSlope = [
            candidate("3040", "Slope 45° 2 x 1", 0.44, [blue, grey]),
            candidate("3039", "Slope 45° 2 x 2", 0.40, [blue, grey]),
        ]
        return confidentScan + [
            piece(unsureBrick, longMm: 16.1, crop: .systemYellow),
            piece(unsureBrick, longMm: 15.8, crop: .systemYellow),
            piece(unsureSlope, longMm: 16.0, crop: .systemBlue),
            piece([], longMm: 9.0, crop: .systemGreen),
        ]
    }

    static let inventory = InventoryResponse(items: [
        InventoryItem(partNum: "3001", name: "Brick 2 x 4", colorId: 4, colorName: "Red", rgb: "C91A09", qty: 12, img: nil),
        InventoryItem(partNum: "3003", name: "Brick 2 x 2", colorId: 14, colorName: "Yellow", rgb: "F2CD37", qty: 7, img: nil),
        InventoryItem(partNum: "3023", name: "Plate 1 x 2", colorId: 71, colorName: "Light Bluish Gray", rgb: "A0A5A9", qty: 30, img: nil),
    ], pieces: 49, lots: 3)

    static let emptyInventory = InventoryResponse(items: [], pieces: 0, lots: 0)

    static let batches = [
        BatchInfo(id: "b3", at: "2026-11-14T18:20:00.000Z", source: "scan", lots: 14, pieces: 214),
        BatchInfo(id: "b2", at: "2026-11-12T09:05:00.000Z", source: "set 31058-1 Mighty Dinosaurs", lots: 61, pieces: 174),
        BatchInfo(id: "b1", at: "2026-11-10T16:40:00.000Z", source: "manual", lots: 1, pieces: 4),
        BatchInfo(id: "b0", at: "2026-11-09T11:00:00.000Z", source: "scan", lots: 9, pieces: 57),
    ]

    static let sets = [
        BuildSet(setNum: "30510-1", name: "90 Years of Cars", year: 2022, theme: "Creator", img: nil, total: 71, owned: 71, favourite: true),
        BuildSet(setNum: "31058-1", name: "Mighty Dinosaurs", year: 2017, theme: "Creator", img: nil, total: 174, owned: 151, favourite: false),
        BuildSet(setNum: "10696-1", name: "Medium Creative Brick Box", year: 2015, theme: "Classic", img: nil, total: 484, owned: 212, favourite: nil),
    ]

    static let detail = BuildDetail(setNum: "31058-1", name: "Mighty Dinosaurs", total: 174, owned: 151, parts: [
        BuildPart(partNum: "3001", name: "Brick 2 x 4", colorId: 4, colorName: "Red", rgb: "C91A09", img: nil, need: 6, have: 2),
        BuildPart(partNum: "3040", name: "Slope 45° 2 x 1", colorId: 1, colorName: "Blue", rgb: "0055BF", img: nil, need: 4, have: 0),
        BuildPart(partNum: "3023", name: "Plate 1 x 2", colorId: 71, colorName: "Light Bluish Gray", rgb: "A0A5A9", img: nil, need: 8, have: 8),
    ], favourite: false)
}

/// Answers every request from `SampleData`, so screens can be previewed without a server.
struct PreviewService: BrickService {
    var empty = false

    func inventory() async throws -> InventoryResponse {
        empty ? SampleData.emptyInventory : SampleData.inventory
    }

    func inventoryCSV() async throws -> String {
        "Part,Color,Quantity\n3001,4,12\n3003,14,7\n3023,71,30\n"
    }

    func add(_ items: [NewItem], source: String) async throws -> InventoryResponse {
        SampleData.inventory
    }

    func setQuantity(partNum: String, colorId: Int, qty: Int) async throws -> InventoryResponse {
        SampleData.inventory
    }

    func batches() async throws -> [BatchInfo] {
        empty ? [] : SampleData.batches
    }

    func undoBatch(id: String) async throws -> InventoryResponse {
        SampleData.inventory
    }

    func checkBatch(_ items: [NewItem]) async throws -> SimilarBatch? {
        SimilarBatch(id: "b3", at: "2026-11-14T18:20:00.000Z", source: "scan", pieces: 214, overlap: 0.93)
    }

    func sendCorrection(jpeg: Data, partNum: String, colorId: Int, predicted: String, longMm: Float) async throws {
    }

    func builds(query: BuildQuery, offset: Int) async throws -> BuildsResponse {
        let sets = query.favouritesOnly ? SampleData.sets.filter { (set: BuildSet) in set.isFavourite } : SampleData.sets
        return BuildsResponse(count: sets.count, complete: 1, sets: offset == 0 ? sets : [])
    }

    func buildDetail(setNum: String, ignoreColor: Bool, variants: Bool) async throws -> BuildDetail {
        SampleData.detail
    }

    func missingCSV(setNum: String, ignoreColor: Bool, variants: Bool) async throws -> String {
        "Part,Color,Quantity\n3001,4,4\n3040,1,4\n"
    }

    func setFavourite(setNum: String, on: Bool) async throws -> [String] {
        on ? [setNum] : []
    }
}
#endif
