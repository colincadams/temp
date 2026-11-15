import SwiftUI

// MARK: - What can I build?

struct BuildsView: View {
    private let service: any BrickService
    @State private var sets: [BuildSet] = []
    @State private var count = 0
    @State private var complete = 0
    @State private var search = ""
    @State private var ignoreColor = false
    @State private var variants = true
    @State private var sort = BuildSort.percent
    @State private var favouritesOnly = false
    @State private var minYearText = ""
    @State private var maxYearText = ""
    @State private var error: String?
    @State private var loading = false
    @State private var loaded = false

    init(service: any BrickService = API.shared) {
        self.service = service
    }

    /// A year typed by the user, or nil while the field is empty or not a plausible year.
    private func year(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value >= 1940, value <= 2100 else { return nil }
        return value
    }

    private var query: BuildQuery {
        BuildQuery(search: search, ignoreColor: ignoreColor, variants: variants, sort: sort,
                   favouritesOnly: favouritesOnly, minYear: year(minYearText), maxYear: year(maxYearText))
    }

    private var summary: String {
        let order = sort == .percent ? "Most complete first." : "Fewest missing pieces first."
        return "You can fully build \(complete) of \(count) sets. \(order)"
    }

    private var emptyText: String {
        favouritesOnly ? "No favourites match. Tap the star on a set to make it a favourite." : "No sets match."
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Sort by", selection: $sort) {
                        ForEach(BuildSort.allCases) { (option: BuildSort) in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("Favourites only", isOn: $favouritesOnly)
                    TextField("From year (optional)", text: $minYearText)
                        .keyboardType(.numberPad)
                    TextField("To year (optional)", text: $maxYearText)
                        .keyboardType(.numberPad)
                    Toggle("Ignore colour", isOn: $ignoreColor)
                    Toggle("Prints & mould variants count as the same part", isOn: $variants)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if loaded {
                        Text(summary)
                    }
                }
                Section {
                    if loaded && sets.isEmpty && error == nil {
                        Text(emptyText).foregroundStyle(.secondary)
                    }
                    ForEach(sets) { (set: BuildSet) in
                        NavigationLink {
                            SetDetailView(set: set, ignoreColor: ignoreColor, variants: variants, service: service) { (on: Bool) in
                                markFavourite(set.setNum, on)
                            }
                        } label: {
                            SetRow(set: set) { toggleFavourite(set) }
                        }
                    }
                    if sets.count < count {
                        Button(loading ? "Loading…" : "Show more") { Task { await load(reset: false) } }
                            .disabled(loading)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $search, prompt: "Search sets")
            .navigationTitle("What can I build?")
            .refreshable { await load(reset: true) }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 250_000_000)   // debounce typing
                if !Task.isCancelled { await load(reset: true) }
            }
        }
    }

    private func load(reset: Bool) async {
        loading = true
        defer { loading = false }
        do {
            let out = try await service.builds(query: query, offset: reset ? 0 : sets.count)
            sets = reset ? out.sets : sets + out.sets
            count = out.count
            complete = out.complete
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func markFavourite(_ setNum: String, _ on: Bool) {
        for index in sets.indices where sets[index].setNum == setNum {
            sets[index].favourite = on
        }
    }

    private func toggleFavourite(_ set: BuildSet) {
        let on = !set.isFavourite
        Task {
            do {
                _ = try await service.setFavourite(setNum: set.setNum, on: on)
                markFavourite(set.setNum, on)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A star that marks a set as a favourite. Says what it will do, not just what it shows.
private struct FavouriteButton: View {
    let on: Bool
    let name: String
    let action: () -> Void

    private var label: String {
        on ? "Remove \(name) from favourites" : "Add \(name) to favourites"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "star.fill" : "star")
                .foregroundStyle(on ? Color.yellow : Color.secondary)
                .imageScale(.large)
                .padding(6)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

private struct SetRow: View {
    let set: BuildSet
    let onFavourite: () -> Void

    private var progressText: String {
        set.complete ? "You can build this!" : "\(Int(set.fraction * 100))% · missing \(set.total - set.owned) of \(set.total)"
    }

    var body: some View {
        HStack(spacing: 10) {
            PartImage(url: set.img, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(set.name).font(.subheadline.weight(.semibold))
                Text("\(set.setNum) · \(set.theme) · \(String(set.year))").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: set.fraction)
                    .tint(set.complete ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Label(progressText, systemImage: set.complete ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            FavouriteButton(on: set.isFavourite, name: set.name, action: onFavourite)
        }
    }
}

// MARK: - One set

struct SetDetailView: View {
    let set: BuildSet
    let ignoreColor: Bool
    let variants: Bool
    private let service: any BrickService
    private let onFavouriteChanged: (Bool) -> Void
    @State private var detail: BuildDetail?
    @State private var favourite: Bool
    @State private var error: String?
    /// The missing parts as a CSV file, ready to share.
    @State private var missingFile: URL?

    init(set: BuildSet, ignoreColor: Bool, variants: Bool, service: any BrickService = API.shared,
         onFavouriteChanged: @escaping (Bool) -> Void = { (_: Bool) in }) {
        self.set = set
        self.ignoreColor = ignoreColor
        self.variants = variants
        self.service = service
        self.onFavouriteChanged = onFavouriteChanged
        _favourite = State(initialValue: set.isFavourite)
    }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if let detail {
                SetDetailSections(set: set, detail: detail)
            } else if error == nil {
                ProgressView()
            }
        }
        .navigationTitle(set.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let missingFile {
                    ShareLink(item: missingFile) {
                        Label("Share the missing parts list", systemImage: "square.and.arrow.up")
                    }
                }
                FavouriteButton(on: favourite, name: set.name) { toggleFavourite() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let loadedDetail = try await service.buildDetail(setNum: set.setNum, ignoreColor: ignoreColor, variants: variants)
            detail = loadedDetail
            if let value = loadedDetail.favourite { favourite = value }
            error = nil
            guard loadedDetail.owned < loadedDetail.total else { return }
            if let text = try? await service.missingCSV(setNum: set.setNum, ignoreColor: ignoreColor, variants: variants) {
                missingFile = ExportFile.write(text, named: "missing-\(set.setNum).csv")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggleFavourite() {
        let on = !favourite
        Task {
            do {
                _ = try await service.setFavourite(setNum: set.setNum, on: on)
                favourite = on
                onFavouriteChanged(on)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct SetDetailSections: View {
    let set: BuildSet
    let detail: BuildDetail

    private var missing: [BuildPart] { detail.parts.filter { (part: BuildPart) in part.missing > 0 } }
    private var have: [BuildPart] { detail.parts.filter { (part: BuildPart) in part.missing == 0 } }

    var body: some View {
        Section {
            Text("You have \(detail.owned) of \(detail.total) pieces.")
            if let url = URL(string: "https://rebrickable.com/sets/\(set.setNum)/") {
                Link("Instructions and details on Rebrickable", destination: url)
            }
        }
        if !missing.isEmpty {
            Section("Missing (\(BatchText.pieces(detail.total - detail.owned)))") {
                ForEach(missing) { (part: BuildPart) in PartRow(part: part) }
            }
        }
        if !have.isEmpty {
            Section("Already have") {
                ForEach(have) { (part: BuildPart) in PartRow(part: part) }
            }
        }
    }
}

private struct PartRow: View {
    let part: BuildPart

    private var statusText: String {
        part.missing > 0 ? "Need \(part.missing) more (have \(part.have) of \(part.need))" : "Have \(part.need) of \(part.need)"
    }

    var body: some View {
        HStack(spacing: 10) {
            PartImage(url: part.img)
            VStack(alignment: .leading, spacing: 4) {
                Text(part.name).font(.subheadline.weight(.semibold))
                ColorLabel(rgb: part.rgb, text: "\(part.colorName) · \(part.partNum)")
                Label(statusText, systemImage: part.missing > 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(part.missing > 0 ? Color.red : Color.green)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Builds") {
    BuildsView(service: PreviewService())
}

#Preview("Set") {
    NavigationStack {
        SetDetailView(set: SampleData.sets[1], ignoreColor: false, variants: true, service: PreviewService())
    }
}
#endif
