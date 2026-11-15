import BrickCore
import SwiftUI

// The "What can I build?" screens are in Views/BuildsViews.swift.

// MARK: - Inventory

struct InventoryView: View {
    private let service: any BrickService
    @EnvironmentObject private var pending: PendingScans
    /// The kept scan the user has asked to discard, while the confirmation is shown.
    @State private var discarding: PendingScan?
    @State private var items: [InventoryItem] = []
    @State private var pieces = 0
    @State private var batches: [BatchInfo] = []
    @State private var showAllBatches = false
    @State private var loaded = false
    @State private var error: String?
    @State private var filter = ""
    /// The inventory as a CSV file, ready to share. Rewritten whenever the inventory changes.
    @State private var csvFile: URL?
    @State private var csvVersion = 0

    private let batchesShownAtFirst = 3

    init(service: any BrickService = API.shared) {
        self.service = service
    }

    private var shown: [InventoryItem] {
        let text = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return items }
        return items.filter { (item: InventoryItem) in
            "\(item.name) \(item.partNum) \(item.colorName)".lowercased().contains(text)
        }
    }

    private var shownBatches: [BatchInfo] {
        showAllBatches ? batches : Array(batches.prefix(batchesShownAtFirst))
    }

    private var discardShown: Binding<Bool> {
        Binding<Bool>(
            get: { discarding != nil },
            set: { (shown: Bool) in
                if !shown { discarding = nil }
            }
        )
    }

    private var batchToggleTitle: String {
        showAllBatches ? "Show fewer" : "Show all \(batches.count)"
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                if !pending.scans.isEmpty {
                    pendingSection
                }
                if !batches.isEmpty {
                    recentSection
                }
                Section {
                    if loaded && items.isEmpty && error == nil && pending.scans.isEmpty {
                        Text("Nothing here yet. Scan some pieces to get started.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { (item: InventoryItem) in
                        InventoryRow(item: item) { (delta: Int) in change(item, by: delta) }
                    }
                } header: {
                    if !items.isEmpty { Text("All pieces") }
                }
            }
            .searchable(text: $filter, prompt: "Filter inventory")
            .navigationTitle(BatchText.pieces(pieces))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let csvFile {
                        ShareLink(item: csvFile) {
                            Label("Export inventory as CSV", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .task(id: csvVersion) { await writeCSV() }
            .onChange(of: pending.delivered) { (_: Int, _: Int) in
                // A scan kept on the phone has just been added on the server.
                Task { await load() }
            }
            .confirmationDialog("Discard this scan?", isPresented: discardShown, titleVisibility: .visible,
                                presenting: discarding) { (scan: PendingScan) in
                Button("Discard \(BatchText.pieces(scan.pieces))", role: .destructive) { pending.discard(scan) }
                Button("Keep it", role: .cancel) { }
            } message: { (_: PendingScan) in
                Text("Its pieces will not be added to your inventory.")
            }
        }
    }

    /// Scans kept on the phone because the computer could not be reached when they were added.
    private var pendingSection: some View {
        Section {
            ForEach(pending.scans) { (scan: PendingScan) in
                PendingScanRow(scan: scan)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            discarding = scan
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                    }
            }
            Button(pending.sending ? "Sending…" : "Try sending now") {
                pending.retry(using: service, includingRefused: true)
            }
            .disabled(pending.sending)
        } header: {
            Text("Waiting to be added")
        } footer: {
            Text("Kept on this phone because your computer could not be reached. Swipe one to the left to discard it.")
        }
    }

    private var recentSection: some View {
        Section {
            ForEach(shownBatches) { (batch: BatchInfo) in
                BatchRow(batch: batch)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            undo(batch)
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                    }
            }
            if batches.count > batchesShownAtFirst {
                Button(batchToggleTitle) {
                    showAllBatches.toggle()
                }
            }
        } header: {
            Text("Recent additions")
        } footer: {
            Text("Swipe an addition to the left to undo it.")
        }
    }

    private func apply(_ response: InventoryResponse) {
        items = response.items
        pieces = response.pieces
        error = nil
        loaded = true
        csvVersion += 1
    }

    private func load() async {
        do {
            apply(try await service.inventory())
        } catch {
            self.error = error.localizedDescription
            loaded = true
            return
        }
        await loadBatches()
    }

    /// An older server has no batch list; the inventory is still useful without it.
    private func loadBatches() async {
        if let list = try? await service.batches() { batches = list }
    }

    private func writeCSV() async {
        guard !items.isEmpty else {
            csvFile = nil
            return
        }
        guard let text = try? await service.inventoryCSV() else { return }
        if Task.isCancelled { return }
        csvFile = ExportFile.write(text, named: "lego-inventory.csv")
    }

    private func change(_ item: InventoryItem, by delta: Int) {
        Task {
            do {
                apply(try await service.setQuantity(partNum: item.partNum, colorId: item.colorId, qty: max(0, item.qty + delta)))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func undo(_ batch: BatchInfo) {
        Task {
            do {
                apply(try await service.undoBatch(id: batch.id))
                batches.removeAll { (other: BatchInfo) in other.id == batch.id }
                await loadBatches()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct InventoryRow: View {
    let item: InventoryItem
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            PartImage(url: item.img)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    ColorLabel(rgb: item.rgb, text: "\(item.colorName) · \(item.partNum)")
                }
                .accessibilityElement(children: .combine)
                Stepper("× \(item.qty)", onIncrement: { onChange(1) }, onDecrement: { onChange(-1) })
                    .font(.subheadline)
                    .accessibilityLabel("Quantity of \(item.name), \(item.colorName)")
                    .accessibilityValue("\(item.qty)")
            }
        }
    }
}

private struct PendingScanRow: View {
    let scan: PendingScan

    /// The first few parts, so the scan can be recognised.
    private var contents: String {
        let names: [String] = scan.items.prefix(3).map { (item: PendingItem) -> String in
            let name = item.name ?? item.partNum
            if let colorName = item.colorName { return "\(item.qty) × \(name), \(colorName)" }
            return "\(item.qty) × \(name)"
        }
        let more = scan.items.count - names.count
        return names.joined(separator: "; ") + (more > 0 ? "; and \(more) more" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(scan.summary, systemImage: scan.rejected ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
            Text(contents)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(scan.status)
                .font(.caption)
                .foregroundStyle(scan.rejected ? Color.red : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BatchRow: View {
    let batch: BatchInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(BatchText.source(batch.source)).font(.subheadline.weight(.semibold))
            Text("\(BatchText.when(batch.at)) · \(BatchText.pieces(batch.pieces))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Inventory") {
    InventoryView(service: PreviewService())
        .environmentObject(PendingScans(fileURL: nil))
}

#Preview("Inventory, scans waiting") {
    InventoryView(service: PreviewService())
        .environmentObject(SampleData.pendingScans())
}

#Preview("Inventory, empty") {
    InventoryView(service: PreviewService(empty: true))
        .environmentObject(PendingScans(fileURL: nil))
}
#endif
