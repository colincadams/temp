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
    var id: String { setNum }
    var fraction: Double { total > 0 ? Double(owned) / Double(total) : 0 }
    var complete: Bool { owned >= total }
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

struct Swatch: View {
    let rgb: String
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(hex: rgb))
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.6), lineWidth: 1))
    }
}

struct PartImage: View {
    let url: String?
    var size: CGFloat = 52
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
    }
}
