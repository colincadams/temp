import BrickCore
import SwiftUI
import UIKit

/// All scanned pieces that look like the same part in the same colour, with the same level of certainty.
struct ReviewGroup: Identifiable {
    /// A top score at or above this is accepted without asking.
    static let confidentScore = 0.8

    let id: String
    /// The part and colour that will be saved. They start as the prediction and the user can change them.
    var candidate: Candidate
    var color: ColorInfo
    var count: Int
    /// True while the group is in the "Check these" list.
    var needsCheck: Bool
    /// True once the user has said these are not Lego pieces.
    var removed = false
    /// Lowest confidence among the pieces in the group.
    var confidence: Double
    /// The scanned pieces behind this group; their crops are sent with corrections.
    var pieces: [PieceSnapshot]
    /// Up to three candidates offered as choices, best first.
    let alternatives: [Candidate]
    let predictedPartNum: String
    let predictedColorId: Int

    var thumbnail: Data? {
        for piece in pieces {
            if let data = piece.thumbnail { return data }
        }
        return nil
    }

    /// True when the user chose a different part or colour from the one predicted.
    var changed: Bool { candidate.partNum != predictedPartNum || color.id != predictedColorId }

    /// Colours offered in the picker. Always includes the current one.
    var colorOptions: [ColorInfo] {
        var options = Array(candidate.colors.prefix(20))
        if !options.contains(color) { options.insert(color, at: 0) }
        return options
    }

    /// Switches to another candidate, keeping the colour when that part is made in it.
    mutating func choose(_ alternative: Candidate) {
        candidate = alternative
        let currentId = color.id
        if let same = alternative.colors.first(where: { (option: ColorInfo) in option.id == currentId }) {
            color = same
        } else if let first = alternative.colors.first {
            color = first
        }
    }

    /// Groups pieces by predicted part, colour and whether the prediction is confident.
    /// Pieces without a candidate (or without a colour) are left out; see `unidentifiedCount`.
    static func make(from pieces: [PieceSnapshot]) -> [ReviewGroup] {
        var groups: [String: ReviewGroup] = [:]
        for piece in pieces {
            guard let top = piece.candidates.first, let color = top.colors.first else { continue }
            let confident = top.score >= confidentScore
            let key = "\(top.partNum)|\(color.id)|\(confident ? "sure" : "check")"
            if var group = groups[key] {
                group.count += 1
                group.confidence = min(group.confidence, top.score)
                group.pieces.append(piece)
                groups[key] = group
            } else {
                groups[key] = ReviewGroup(id: key, candidate: top, color: color, count: 1, needsCheck: !confident,
                                          confidence: top.score, pieces: [piece],
                                          alternatives: Array(piece.candidates.prefix(3)),
                                          predictedPartNum: top.partNum, predictedColorId: color.id)
            }
        }
        return groups.values.sorted { (a: ReviewGroup, b: ReviewGroup) in
            if a.candidate.name != b.candidate.name { return a.candidate.name < b.candidate.name }
            if a.color.name != b.color.name { return a.color.name < b.color.name }
            return a.id < b.id
        }
    }

    static func unidentifiedCount(in pieces: [PieceSnapshot]) -> Int {
        var count = 0
        for piece in pieces {
            if let top = piece.candidates.first, !top.colors.isEmpty { continue }
            count += 1
        }
        return count
    }
}

/// One crop to send to the server with the part and colour the user chose for it.
struct PendingCorrection {
    let jpeg: Data
    let partNum: String
    let colorId: Int
    let predicted: String
    let longMm: Float
}

struct ReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ReviewGroup]
    @State private var saving = false
    /// One id for this review's save, whether it reaches the server now or is kept on the phone and retried later.
    @State private var saveID = UUID()
    @State private var error: String?
    @State private var showConfident = false
    @State private var confirmRepeat = false
    @State private var repeatMessage = ""
    @State private var keptOnPhone = false
    @State private var keptMessage = ""
    private let unidentified: Int
    private let service: any BrickService
    /// Where a scan goes when the computer cannot be reached. Without it, that is shown as an error.
    private let pending: PendingScans?
    private let onSaved: () -> Void

    init(pieces: [PieceSnapshot], service: any BrickService = API.shared, pending: PendingScans? = nil,
         onSaved: @escaping () -> Void) {
        _groups = State(initialValue: ReviewGroup.make(from: pieces))
        self.unidentified = ReviewGroup.unidentifiedCount(in: pieces)
        self.service = service
        self.pending = pending
        self.onSaved = onSaved
    }

    // MARK: Totals

    private var total: Int {
        var sum = 0
        for group in groups where !group.removed { sum += group.count }
        return sum
    }

    private var confidentPieces: Int {
        var sum = 0
        for group in groups where !group.removed && !group.needsCheck { sum += group.count }
        return sum
    }

    private var checkGroups: Int {
        var sum = 0
        for group in groups where !group.removed && group.needsCheck { sum += 1 }
        return sum
    }

    private var removedPieces: Int {
        var sum = 0
        for group in groups where group.removed { sum += group.pieces.count }
        return sum
    }

    private var unidentifiedText: String {
        unidentified == 1
            ? "1 piece could not be identified and is left out."
            : "\(unidentified) pieces could not be identified and are left out."
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            List {
                confidentSection
                checkSection
                notesSection
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .alert("Kept on this phone", isPresented: $keptOnPhone) {
                Button("OK") { finish() }
            } message: {
                Text(keptMessage)
            }
            .navigationTitle("Add \(BatchText.pieces(total))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep scanning") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add") { save(confirmed: false) }
                        .disabled(total == 0 || saving)
                }
            }
            .alert("Add it again?", isPresented: $confirmRepeat) {
                Button("Add again") { save(confirmed: true) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(repeatMessage)
            }
        }
    }

    @ViewBuilder private var confidentSection: some View {
        if confidentPieces > 0 {
            Section {
                DisclosureGroup(isExpanded: $showConfident) {
                    ForEach($groups) { $group in
                        if !group.removed && !group.needsCheck {
                            ConfidentRow(group: group) { group.needsCheck = true }
                        }
                    }
                } label: {
                    Label("\(BatchText.pieces(confidentPieces)) identified with confidence", systemImage: "checkmark.circle")
                }
            } footer: {
                Text("These will be added as they are. Open the list to see them, or to change one.")
            }
        }
    }

    @ViewBuilder private var checkSection: some View {
        if checkGroups > 0 {
            Section {
                ForEach($groups) { $group in
                    if !group.removed && group.needsCheck {
                        CheckRow(group: $group)
                    }
                }
            } header: {
                Text("Check these")
            } footer: {
                Text("The app is less sure about these. Tap the picture that matches, fix the colour or the count, or say it is not a Lego piece.")
            }
        } else if confidentPieces > 0 {
            Section {
                Label("Nothing to check.", systemImage: "hand.thumbsup")
            }
        }
    }

    @ViewBuilder private var notesSection: some View {
        if unidentified > 0 || removedPieces > 0 {
            Section {
                if unidentified > 0 {
                    Text(unidentifiedText)
                }
                if removedPieces > 0 {
                    HStack {
                        Text("\(BatchText.pieces(removedPieces)) marked as not Lego.")
                        Spacer()
                        Button("Put back") { restoreRemoved() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func restoreRemoved() {
        for index in groups.indices where groups[index].removed {
            groups[index].removed = false
        }
    }

    /// What will be saved: one item per part and colour, however many groups ended up there.
    private func mergedItems() -> [NewItem] {
        var totals: [String: Int] = [:]
        var first: [String: NewItem] = [:]
        var order: [String] = []
        for group in groups where !group.removed && group.count > 0 {
            let key = "\(group.candidate.partNum)|\(group.color.id)"
            if first[key] == nil {
                first[key] = NewItem(partNum: group.candidate.partNum, colorId: group.color.id, qty: group.count)
                order.append(key)
            }
            totals[key, default: 0] += group.count
        }
        var items: [NewItem] = []
        for key in order {
            if let item = first[key], let qty = totals[key] {
                items.append(NewItem(partNum: item.partNum, colorId: item.colorId, qty: qty))
            }
        }
        return items
    }

    /// The same items as `mergedItems`, with names kept for showing the scan while it waits on the phone.
    private func itemsToKeep() -> [PendingItem] {
        var totals: [String: Int] = [:]
        var first: [String: ReviewGroup] = [:]
        var order: [String] = []
        for group in groups where !group.removed && group.count > 0 {
            let key = "\(group.candidate.partNum)|\(group.color.id)"
            if first[key] == nil {
                first[key] = group
                order.append(key)
            }
            totals[key, default: 0] += group.count
        }
        var items: [PendingItem] = []
        for key in order {
            if let group = first[key], let qty = totals[key] {
                items.append(PendingItem(partNum: group.candidate.partNum, colorId: group.color.id, qty: qty,
                                         name: group.candidate.name, colorName: group.color.name, rgb: group.color.rgb))
            }
        }
        return items
    }

    /// The computer cannot be reached: keep the scan on the phone and say so. False if there is nowhere to keep it.
    private func keepOnPhone() -> Bool {
        guard let pending, pending.add(itemsToKeep(), source: "scan", id: saveID) else { return false }
        let what = total == 1 ? "this piece is" : "these \(total) pieces are"
        keptMessage = "Your computer can't be reached right now, so \(what) kept on this phone. "
            + "\(total == 1 ? "It" : "They") will be added to your inventory as soon as the computer is reachable. "
            + "You can see the scan in the Inventory tab."
        saving = false
        keptOnPhone = true
        return true
    }

    private func finish() {
        onSaved()
        dismiss()
    }

    /// A correction for every piece with a crop in a group whose part or colour the user changed.
    private func pendingCorrections() -> [PendingCorrection] {
        var out: [PendingCorrection] = []
        for group in groups where !group.removed && group.changed {
            for piece in group.pieces {
                guard let jpeg = piece.thumbnail else { continue }
                out.append(PendingCorrection(jpeg: jpeg, partNum: group.candidate.partNum, colorId: group.color.id,
                                             predicted: group.predictedPartNum, longMm: piece.longMm))
            }
        }
        return out
    }

    private func save(confirmed: Bool) {
        let items = mergedItems()
        guard !items.isEmpty else { return }
        let corrections = pendingCorrections()
        let service = self.service
        saving = true
        error = nil
        Task {
            if !confirmed {
                // If the check itself fails, carry on: it must not stop a save.
                var similar: SimilarBatch?
                do {
                    similar = try await service.checkBatch(items)
                } catch {
                    // No point waiting for the save to time out as well.
                    if APIError.isUnreachable(error), keepOnPhone() { return }
                }
                if let similar {
                    repeatMessage = "This looks like the scan you added on \(BatchText.when(similar.at)). Add it again?"
                    saving = false
                    confirmRepeat = true
                    return
                }
            }
            do {
                _ = try await service.add(items, source: "scan", clientId: saveID.uuidString)
            } catch {
                // Corrections are dropped in this case, as when they fail to send.
                if APIError.isUnreachable(error), keepOnPhone() { return }
                self.error = error.localizedDescription
                saving = false
                return
            }
            saving = false
            // Corrections are a favour to future recognition; send them in the background and ignore failures.
            Task {
                for correction in corrections {
                    _ = try? await service.sendCorrection(jpeg: correction.jpeg, partNum: correction.partNum,
                                                          colorId: correction.colorId, predicted: correction.predicted,
                                                          longMm: correction.longMm)
                }
            }
            finish()
        }
    }
}

// MARK: - Rows

/// The crop taken during the scan.
private struct CropImage: View {
    let data: Data?
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Your scanned piece")
    }
}

/// A confident group: read-only, with a way to move it to the check list.
private struct ConfidentRow: View {
    let group: ReviewGroup
    let onCheck: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PartImage(url: group.candidate.img, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.candidate.name).font(.subheadline.weight(.semibold))
                ColorLabel(rgb: group.color.rgb, text: "\(group.color.name) · \(group.candidate.partNum)")
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Text("× \(group.count)")
                .font(.subheadline)
                .accessibilityLabel("Count \(group.count)")
            Button("Change", action: onCheck)
                .font(.caption)
                .buttonStyle(.borderless)
                .accessibilityLabel("Change \(group.candidate.name)")
        }
    }
}

/// An uncertain group: the crop, candidate pictures to choose from, colour, count and "not Lego".
private struct CheckRow: View {
    @Binding var group: ReviewGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                CropImage(data: group.thumbnail)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.candidate.name).font(.subheadline.weight(.semibold))
                    Text("Part \(group.candidate.partNum)").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int(group.confidence * 100))% sure").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .top, spacing: 8) {
                ForEach(group.alternatives, id: \.partNum) { (alternative: Candidate) in
                    CandidateChoice(candidate: alternative, selected: alternative.partNum == group.candidate.partNum) {
                        group.choose(alternative)
                    }
                }
            }

            HStack(spacing: 8) {
                Swatch(rgb: group.color.rgb)
                Picker("Colour", selection: $group.color) {
                    ForEach(group.colorOptions) { (option: ColorInfo) in
                        Text(option.name).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer()
            }

            Stepper("× \(group.count)", value: $group.count, in: 0...9999)
                .font(.subheadline)
                .accessibilityLabel("Count")
                .accessibilityValue("\(group.count)")

            Button(role: .destructive) {
                group.removed = true
            } label: {
                Label("Not a Lego piece", systemImage: "xmark.circle")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// A catalog picture of one candidate, tappable to choose it.
private struct CandidateChoice: View {
    let candidate: Candidate
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let traits: AccessibilityTraits = selected ? [.isSelected] : []
        Button(action: action) {
            VStack(spacing: 4) {
                PartImage(url: candidate.img, size: 56)
                Text(candidate.name)
                    .font(.caption2)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                Text(candidate.partNum)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.name), part \(candidate.partNum)")
        .accessibilityAddTraits(traits)
    }
}

#if DEBUG
#Preview("Review") {
    ReviewView(pieces: SampleData.scan, service: PreviewService(), pending: PendingScans(fileURL: nil), onSaved: { })
}

#Preview("Review, nothing to check") {
    ReviewView(pieces: SampleData.confidentScan, service: PreviewService(), onSaved: { })
}
#endif
