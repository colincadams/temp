import SwiftUI

// MARK: - Inventory

struct InventoryView: View {
    @State private var items: [InventoryItem] = []
    @State private var pieces = 0
    @State private var error: String?
    @State private var filter = ""

    private var shown: [InventoryItem] {
        let text = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return items }
        return items.filter { "\($0.name) \($0.partNum) \($0.colorName)".lowercased().contains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if items.isEmpty {
                    Text("Nothing here yet. Scan some pieces to get started.").foregroundStyle(.secondary)
                }
                ForEach(shown) { item in
                    HStack(spacing: 10) {
                        PartImage(url: item.img)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.subheadline.weight(.semibold))
                            HStack(spacing: 6) {
                                Swatch(rgb: item.rgb)
                                Text("\(item.colorName) · \(item.partNum)").font(.caption).foregroundStyle(.secondary)
                            }
                            Stepper("× \(item.qty)", onIncrement: { change(item, by: 1) }, onDecrement: { change(item, by: -1) })
                                .font(.subheadline)
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "Filter inventory")
            .navigationTitle("\(pieces) pieces")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func apply(_ response: InventoryResponse) {
        items = response.items
        pieces = response.pieces
        error = nil
    }

    private func load() async {
        do { apply(try await API.shared.inventory()) } catch { self.error = error.localizedDescription }
    }

    private func change(_ item: InventoryItem, by delta: Int) {
        Task {
            do {
                apply(try await API.shared.setQuantity(partNum: item.partNum, colorId: item.colorId, qty: max(0, item.qty + delta)))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - What can I build?

struct BuildsView: View {
    @State private var sets: [BuildSet] = []
    @State private var count = 0
    @State private var complete = 0
    @State private var search = ""
    @State private var ignoreColor = false
    @State private var variants = true
    @State private var error: String?
    @State private var loading = false

    private var queryKey: String { "\(search)|\(ignoreColor)|\(variants)" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Ignore colour", isOn: $ignoreColor)
                    Toggle("Prints & mould variants count as the same part", isOn: $variants)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("You can fully build \(complete) of \(count) sets. Closest first.")
                    }
                }
                Section {
                    ForEach(sets) { set in
                        NavigationLink {
                            SetDetailView(set: set, ignoreColor: ignoreColor, variants: variants)
                        } label: {
                            SetRow(set: set)
                        }
                    }
                    if sets.count < count {
                        Button(loading ? "Loading…" : "Show more") { Task { await load(reset: false) } }
                            .disabled(loading)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search sets")
            .navigationTitle("What can I build?")
            .refreshable { await load(reset: true) }
            .task(id: queryKey) {
                try? await Task.sleep(nanoseconds: 250_000_000)   // debounce typing
                if !Task.isCancelled { await load(reset: true) }
            }
        }
    }

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        do {
            let out = try await API.shared.builds(search: search, ignoreColor: ignoreColor, variants: variants, offset: reset ? 0 : sets.count)
            sets = reset ? out.sets : sets + out.sets
            count = out.count
            complete = out.complete
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SetRow: View {
    let set: BuildSet

    var body: some View {
        HStack(spacing: 10) {
            PartImage(url: set.img, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(set.name).font(.subheadline.weight(.semibold))
                Text("\(set.setNum) · \(set.theme) · \(String(set.year))").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: set.fraction).tint(set.complete ? .green : .orange)
                Text(set.complete ? "You can build this!" : "\(Int(set.fraction * 100))% · missing \(set.total - set.owned) of \(set.total)")
                    .font(.caption)
                    .foregroundStyle(set.complete ? Color.green : Color.primary)
            }
        }
    }
}

struct SetDetailView: View {
    let set: BuildSet
    let ignoreColor: Bool
    let variants: Bool
    @State private var detail: BuildDetail?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if let detail {
                let missing = detail.parts.filter { $0.missing > 0 }
                let have = detail.parts.filter { $0.missing == 0 }
                Section {
                    Text("You have \(detail.owned) of \(detail.total) pieces.")
                    if let url = URL(string: "https://rebrickable.com/sets/\(set.setNum)/") {
                        Link("Instructions and details on Rebrickable", destination: url)
                    }
                }
                if !missing.isEmpty {
                    Section("Missing (\(detail.total - detail.owned) pieces)") {
                        ForEach(missing) { PartRow(part: $0) }
                    }
                }
                if !have.isEmpty {
                    Section("Already have") {
                        ForEach(have) { PartRow(part: $0) }
                    }
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .navigationTitle(set.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                detail = try await API.shared.buildDetail(setNum: set.setNum, ignoreColor: ignoreColor, variants: variants)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct PartRow: View {
    let part: BuildPart

    var body: some View {
        HStack(spacing: 10) {
            PartImage(url: part.img)
            VStack(alignment: .leading, spacing: 4) {
                Text(part.name).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Swatch(rgb: part.rgb)
                    Text("\(part.colorName) · \(part.partNum)").font(.caption).foregroundStyle(.secondary)
                }
                Text(part.missing > 0 ? "Need \(part.missing) more (have \(part.have) of \(part.need))" : "Have \(part.need) of \(part.need)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(part.missing > 0 ? Color.red : Color.green)
            }
        }
    }
}
