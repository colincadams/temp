import SwiftUI
import UIKit

/// All scanned pieces that look like the same part in the same colour.
struct ReviewGroup: Identifiable {
    let id: String
    var candidate: Candidate
    var color: ColorInfo
    var count: Int
    var include: Bool
    /// Lowest confidence among the pieces in the group.
    let confidence: Double
    let thumbnail: Data?
    let alternatives: [Candidate]

    static func make(from pieces: [PieceSnapshot]) -> [ReviewGroup] {
        var groups: [String: ReviewGroup] = [:]
        for piece in pieces {
            guard let top = piece.candidates.first, let color = top.colors.first else { continue }
            let key = "\(top.partNum)|\(color.id)"
            if var group = groups[key] {
                group.count += 1
                groups[key] = ReviewGroup(id: key, candidate: group.candidate, color: group.color, count: group.count,
                                          include: min(group.confidence, top.score) >= 0.4,
                                          confidence: min(group.confidence, top.score),
                                          thumbnail: group.thumbnail ?? piece.thumbnail, alternatives: group.alternatives)
            } else {
                groups[key] = ReviewGroup(id: key, candidate: top, color: color, count: 1, include: top.score >= 0.4,
                                          confidence: top.score, thumbnail: piece.thumbnail,
                                          alternatives: Array(piece.candidates.prefix(4)))
            }
        }
        return groups.values.sorted { ($0.candidate.name, $0.color.name) < ($1.candidate.name, $1.color.name) }
    }
}

struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ReviewGroup]
    @State private var saving = false
    @State private var error: String?
    private let unidentified: Int
    private let onSaved: () -> Void

    init(pieces: [PieceSnapshot], onSaved: @escaping () -> Void) {
        let groups = ReviewGroup.make(from: pieces)
        _groups = State(initialValue: groups)
        unidentified = pieces.count - groups.reduce(0) { $0 + $1.count }
        self.onSaved = onSaved
    }

    private var total: Int { groups.filter(\.include).reduce(0) { $0 + $1.count } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($groups) { $group in
                        ReviewRow(group: $group)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Matches are best guesses. Unticked rows had low confidence; check them before including.")
                        if unidentified > 0 {
                            Text("\(unidentified) pieces were not identified and are left out.")
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Review \(total) pieces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep scanning") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(total == 0 || saving)
                }
            }
        }
    }

    private func save() {
        let items = groups.filter { $0.include && $0.count > 0 }
            .map { NewItem(partNum: $0.candidate.partNum, colorId: $0.color.id, qty: $0.count) }
        saving = true
        error = nil
        Task {
            do {
                _ = try await API.shared.add(items)
                onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

private struct ReviewRow: View {
    @Binding var group: ReviewGroup

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let data = group.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.white
                }
            }
            .frame(width: 52, height: 52)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    ForEach(group.alternatives, id: \.partNum) { alternative in
                        Button("\(alternative.name) (\(alternative.partNum)) · \(Int(alternative.score * 100))%") {
                            group.candidate = alternative
                            if !alternative.colors.contains(group.color), let first = alternative.colors.first { group.color = first }
                        }
                    }
                } label: {
                    Text("\(group.candidate.name) (\(group.candidate.partNum))")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                }

                Menu {
                    ForEach(group.candidate.colors.prefix(15)) { color in
                        Button(color.name) { group.color = color }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Swatch(rgb: group.color.rgb)
                        Text(group.color.name).font(.caption)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }

                HStack {
                    Stepper("× \(group.count)", value: $group.count, in: 0...9999)
                        .font(.subheadline)
                    if group.confidence < 0.6 {
                        Text("\(Int(group.confidence * 100))% sure")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.8), in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
            }

            Toggle("Include", isOn: $group.include).labelsHidden()
        }
        .opacity(group.include ? 1 : 0.5)
    }
}
