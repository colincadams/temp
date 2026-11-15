import BrickCore
import Combine
import Foundation

/// Reviewed scans that could not be saved because the computer was out of reach, kept on the phone until
/// it can be reached again (plan step A7).
///
/// The queue's logic and file format are `PendingScanQueue` in BrickCore; this class keeps it in
/// `pending-scans.json` in the app's Application Support folder and sends it with `retry(using:)`.
/// Everything here runs on the main thread, like `ServerDiscovery`.
final class PendingScans: ObservableObject, @unchecked Sendable {
    static let fileName = "pending-scans.json"

    /// Oldest first.
    @Published private(set) var scans: [PendingScan] = []
    /// True while queued scans are being sent.
    @Published private(set) var sending = false
    /// Counts queued scans the server has added, so screens showing the inventory know to reload.
    @Published private(set) var delivered = 0

    private var queue: PendingScanQueue
    /// `retry` was called while a round was under way.
    private var retryRequested = false
    /// Nil keeps the queue in memory only (previews).
    private let fileURL: URL?

    init(fileURL: URL? = PendingScans.defaultFileURL()) {
        self.fileURL = fileURL
        let loaded = PendingScans.load(from: fileURL)
        queue = loaded
        scans = loaded.scans
    }

    static func defaultFileURL() -> URL? {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true) else { return nil }
        return folder.appendingPathComponent(fileName)
    }

    /// Pieces waiting, over every scan.
    var pieces: Int { queue.pieces }

    /// Keep a scan to send later. Returns false if there was nothing to keep.
    @discardableResult
    func add(_ items: [PendingItem], source: String) -> Bool {
        guard queue.add(items: items, source: source, at: Date()) != nil else { return false }
        changed()
        return true
    }

    func discard(_ scan: PendingScan) {
        queue.discard(id: scan.id)
        changed()
    }

    /// Send every waiting scan, oldest first. Stops at the first one the server cannot be reached for.
    /// - Parameter includingRefused: also send scans the server refused before (the user asked to try again).
    func retry(using service: any BrickService, includingRefused: Bool = false) {
        if includingRefused {
            queue.clearRejections()
            changed()
        }
        guard !queue.toRetry.isEmpty else { return }
        guard !sending else {
            // Asked again mid-round (say the server was just found at a new address): go round once more after.
            retryRequested = true
            return
        }
        sending = true
        retryRequested = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            for scan in self.queue.toRetry {
                let newItems: [NewItem] = scan.items.map { (item: PendingItem) -> NewItem in
                    NewItem(partNum: item.partNum, colorId: item.colorId, qty: item.qty)
                }
                let outcome: PendingScanQueue.Outcome
                do {
                    _ = try await service.add(newItems, source: scan.source)
                    outcome = .added
                } catch {
                    let message = error.localizedDescription
                    outcome = APIError.isUnreachable(error) ? .unreachable(message) : .rejected(message)
                }
                let goOn = self.queue.record(outcome, for: scan.id, at: Date())
                if outcome == .added { self.delivered += 1 }
                self.changed()
                if !goOn { break }
            }
            self.sending = false
            if self.retryRequested {
                self.retryRequested = false
                self.retry(using: service)
            }
        }
    }

    // MARK: File

    private func changed() {
        scans = queue.scans
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            if queue.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            } else {
                try queue.encoded().write(to: fileURL, options: [.atomic])
            }
        } catch {
            // Nothing better to do: the queue stays in memory and is written again on the next change.
        }
    }

    /// The saved queue. A damaged file, or one from a newer app, is moved aside rather than overwritten.
    private static func load(from fileURL: URL?) -> PendingScanQueue {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return PendingScanQueue() }
        do {
            return try PendingScanQueue.decode(data)
        } catch {
            let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return PendingScanQueue()
        }
    }
}

extension PendingScan {
    /// "Scan · 15 Nov 2026 at 14:05 · 23 pieces".
    var summary: String {
        "\(BatchText.source(source)) · \(createdAt.formatted(date: .abbreviated, time: .shortened)) · \(BatchText.pieces(pieces))"
    }

    /// Why it is still waiting, in plain words.
    var status: String {
        if rejected {
            return "The server did not accept this scan: \(lastError ?? "unknown error"). Discard it, or try again."
        }
        return "Will be added to your inventory when your computer is reachable."
    }
}
