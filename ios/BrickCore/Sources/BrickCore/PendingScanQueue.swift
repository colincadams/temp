import Foundation

/// One part and colour of a scan waiting to be added to the inventory.
public struct PendingItem: Codable, Hashable, Sendable {
    public let partNum: String
    public let colorId: Int
    public let qty: Int
    /// For showing the scan while it waits; the server only needs the three fields above.
    public let name: String?
    public let colorName: String?
    public let rgb: String?

    public init(partNum: String, colorId: Int, qty: Int, name: String? = nil, colorName: String? = nil, rgb: String? = nil) {
        self.partNum = partNum
        self.colorId = colorId
        self.qty = qty
        self.name = name
        self.colorName = colorName
        self.rgb = rgb
    }
}

/// A reviewed scan that could not be saved because the server was out of reach.
public struct PendingScan: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let items: [PendingItem]
    /// Batch source sent with the items, e.g. "scan".
    public let source: String
    /// When the scan was reviewed.
    public let createdAt: Date
    /// Attempts to send it that failed.
    public internal(set) var attempts: Int
    public internal(set) var lastAttemptAt: Date?
    public internal(set) var lastError: String?
    /// The server answered and refused the scan (for example a part it does not know). Such a scan is not
    /// retried by itself, since the same answer would come back; the user can try again or discard it.
    public internal(set) var rejected: Bool

    public init(id: UUID = UUID(), items: [PendingItem], source: String, createdAt: Date,
                attempts: Int = 0, lastAttemptAt: Date? = nil, lastError: String? = nil, rejected: Bool = false) {
        self.id = id
        self.items = items
        self.source = source
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.rejected = rejected
    }

    public var pieces: Int { items.reduce(0) { $0 + $1.qty } }
}

/// Reviewed scans kept on the phone until the server can be reached (plan step A7).
///
/// This is the queue's logic and file format; the app keeps it in a JSON file in Application Support and
/// drives `retry` order and `record` from its network calls.
public struct PendingScanQueue: Codable, Equatable, Sendable {
    /// The file layout version written by `encoded()`.
    public static let formatVersion = 1

    /// What happened when a scan was sent.
    public enum Outcome: Equatable, Sendable {
        /// The server added it to the inventory.
        case added
        /// The server could not be reached; nothing was saved.
        case unreachable(String)
        /// The server answered with an error.
        case rejected(String)
    }

    /// Oldest first.
    public private(set) var scans: [PendingScan]

    public init(scans: [PendingScan] = []) {
        self.scans = scans
    }

    public var isEmpty: Bool { scans.isEmpty }
    public var pieces: Int { scans.reduce(0) { $0 + $1.pieces } }

    /// Keep a scan. Items with no pieces are left out; returns nil (and keeps nothing) if none remain.
    @discardableResult
    public mutating func add(items: [PendingItem], source: String, at date: Date, id: UUID = UUID()) -> PendingScan? {
        let kept = items.filter { $0.qty > 0 }
        guard !kept.isEmpty else { return nil }
        let scan = PendingScan(id: id, items: kept, source: source, createdAt: date)
        scans.append(scan)
        return scan
    }

    /// The user does not want this scan after all.
    public mutating func discard(id: UUID) {
        scans.removeAll { $0.id == id }
    }

    /// Scans to send now, oldest first: every one the server has not refused.
    public var toRetry: [PendingScan] { scans.filter { !$0.rejected } }

    /// Let refused scans be sent again (the user asked to try again, or the server may have changed).
    public mutating func clearRejections() {
        for i in scans.indices { scans[i].rejected = false }
    }

    /// Record how sending one scan went.
    ///
    /// - Returns: whether to go on to the next scan. After `unreachable` the rest would fail the same way.
    @discardableResult
    public mutating func record(_ outcome: Outcome, for id: UUID, at date: Date) -> Bool {
        // The scan may have been discarded while it was being sent.
        guard let i = scans.firstIndex(where: { $0.id == id }) else { return !isUnreachable(outcome) }
        switch outcome {
        case .added:
            scans.remove(at: i)
            return true
        case .unreachable(let message):
            scans[i].attempts += 1
            scans[i].lastAttemptAt = date
            scans[i].lastError = message
            return false
        case .rejected(let message):
            scans[i].attempts += 1
            scans[i].lastAttemptAt = date
            scans[i].lastError = message
            scans[i].rejected = true
            return true
        }
    }

    private func isUnreachable(_ outcome: Outcome) -> Bool {
        if case .unreachable = outcome { return true }
        return false
    }

    // MARK: File

    private enum CodingKeys: String, CodingKey { case version, scans }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= PendingScanQueue.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Written by a newer version of the app")
        }
        scans = try c.decode([PendingScan].self, forKey: .scans)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(PendingScanQueue.formatVersion, forKey: .version)
        try c.encode(scans, forKey: .scans)
    }

    /// The queue as the JSON file the app keeps. Times are stored to the second.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads the file written by `encoded()`. Throws if it is damaged or from a newer app.
    public static func decode(_ data: Data) throws -> PendingScanQueue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PendingScanQueue.self, from: data)
    }
}
