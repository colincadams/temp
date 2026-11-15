import Foundation
import SwiftUI

// MARK: - Server responses

struct ColorInfo: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let rgb: String
    let isTrans: Bool
}

struct Candidate: Codable, Hashable {
    let partNum: String
    let name: String
    let img: String?
    let colors: [ColorInfo]
    var score: Double
}

struct IdentifyResponse: Codable {
    let candidates: [Candidate]
}

struct PartInfoResponse: Codable {
    let parts: [Candidate]
}

struct InventoryItem: Codable, Identifiable, Hashable {
    let partNum: String
    let name: String
    let colorId: Int
    let colorName: String
    let rgb: String
    var qty: Int
    let img: String?
    var id: String { "\(partNum)|\(colorId)" }
}

struct InventoryResponse: Codable {
    let items: [InventoryItem]
    let pieces: Int
    let lots: Int
}

struct BuildSet: Codable, Identifiable, Hashable {
    let setNum: String
    let name: String
    let year: Int
    let theme: String
    let img: String?
    let total: Int
    let owned: Int
    /// Missing from replies of servers that predate favourites.
    var favourite: Bool?
    var id: String { setNum }
    var fraction: Double { total > 0 ? Double(owned) / Double(total) : 0 }
    var complete: Bool { owned >= total }
    var isFavourite: Bool { favourite ?? false }
}

struct BuildsResponse: Codable {
    let count: Int
    let complete: Int
    let sets: [BuildSet]
}

struct BuildPart: Codable, Identifiable, Hashable {
    let partNum: String
    let name: String
    let colorId: Int
    let colorName: String
    let rgb: String
    let img: String?
    let need: Int
    let have: Int
    var id: String { "\(partNum)|\(colorId)" }
    var missing: Int { max(0, need - have) }
}

struct BuildDetail: Codable {
    let setNum: String
    let name: String
    let total: Int
    let owned: Int
    let parts: [BuildPart]
    var favourite: Bool?
}

struct FavouritesResponse: Codable {
    let sets: [String]
}

enum BuildSort: String, CaseIterable, Identifiable, Hashable {
    case percent
    case missing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .percent: return "Most complete"
        case .missing: return "Fewest missing"
        }
    }
}

/// Everything that decides which sets `GET /api/builds` returns, and in what order.
struct BuildQuery: Hashable {
    var search = ""
    var ignoreColor = false
    var variants = true
    var sort = BuildSort.percent
    var favouritesOnly = false
    var minYear: Int?
    var maxYear: Int?
}

// MARK: - Batches (everything added to the inventory)

struct BatchInfo: Codable, Identifiable, Hashable {
    let id: String
    let at: String
    let source: String
    let lots: Int
    let pieces: Int
}

struct BatchesResponse: Codable {
    let batches: [BatchInfo]
}

/// An earlier batch that a new scan closely resembles.
struct SimilarBatch: Codable, Hashable {
    let id: String
    let at: String
    let source: String?
    let pieces: Int?
    let overlap: Double?
}

struct BatchCheckResponse: Codable {
    let similar: SimilarBatch?
}

enum BatchText {
    /// The server sends times as ISO-8601 with milliseconds, e.g. "2026-11-15T00:17:00.000Z".
    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func when(_ text: String) -> String {
        guard let date = parse(text) else { return text }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "scan" becomes "Scan", "set 31058-1 Name" becomes "Set 31058-1 Name".
    static func source(_ text: String) -> String {
        if text == "manual" { return "Added by hand" }
        guard let first = text.first else { return "Addition" }
        return String(first).uppercased() + String(text.dropFirst())
    }

    static func pieces(_ count: Int) -> String {
        count == 1 ? "1 piece" : "\(count) pieces"
    }
}

struct MetaResponse: Codable {
    let setCount: Int
    let partCount: Int
}

struct NewItem: Codable {
    let partNum: String
    let colorId: Int
    let qty: Int
}

struct NewItems: Codable {
    let items: [NewItem]
    /// Where the items came from, e.g. "scan". Left out of the JSON when nil.
    var source: String?
}

// MARK: - Scan state shown in the UI

enum PieceState {
    case seen          // detected, not yet sent for recognition
    case identifying
    case identified
    case unknown       // recognition returned nothing usable
}

/// Immutable copy of a tracked piece, safe to hand to the UI.
struct PieceSnapshot: Identifiable {
    let id: UUID
    /// Position on the table in ARKit world space (metres).
    let position: SIMD3<Float>
    let state: PieceState
    /// Longest side in millimetres, measured on the table plane.
    let longMm: Float
    let thumbnail: Data?
    /// Best match first; scores are averaged over every view of the piece.
    let candidates: [Candidate]
}

// MARK: - Helpers

extension Color {
    /// `hex` is "RRGGBB".
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0xCCCCCC
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

/// A colour chip. It is decorative: always show the colour's name next to it (see `ColorLabel`).
struct Swatch: View {
    let rgb: String
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(hex: rgb))
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.6), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A colour chip with the colour's name, so colour is never the only cue.
struct ColorLabel: View {
    let rgb: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Swatch(rgb: rgb)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A catalog picture. Pass `label` when the picture says something the text beside it does not;
/// otherwise it is hidden from VoiceOver.
struct PartImage: View {
    let url: String?
    var size: CGFloat = 52
    var label: String? = nil
    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Color.white
            }
        }
        .frame(width: size, height: size)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(Text(label ?? ""))
        .accessibilityHidden(label == nil)
    }
}
