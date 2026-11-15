import Foundation

/// What the review shows for one candidate part, worked out on the phone.
public struct OfflinePart: Equatable, Sendable {
    public let partNum: String
    public let name: String
    /// A catalog picture of the part, if the catalog has one.
    public let img: String?
    /// Colours the part is made in, best match for the measured colour first.
    public let colors: [CatalogColor]

    public init(partNum: String, name: String, img: String?, colors: [CatalogColor]) {
        self.partNum = partNum
        self.name = name
        self.img = img
        self.colors = colors
    }
}

/// Names, pictures and colours of the shapes the phone's model knows, from the `details` that
/// `ml/export.py` (ml/part_details.py) writes into `classes.json` (plan step A7).
///
/// With these the phone can describe a recognised piece without asking the server's `GET /api/parts/info`,
/// so a scan can be finished and reviewed offline. Decode it from the whole `classes.json`; a file written
/// before part details existed decodes to an empty catalog.
public struct OfflineCatalog: Decodable, Sendable {
    struct Part: Sendable {
        let name: String
        let img: String?
        let colors: [ColorRanking.Entry]
    }

    private let parts: [String: Part]

    /// Parts described.
    public var count: Int { parts.count }
    public var isEmpty: Bool { parts.isEmpty }

    /// - Parameters:
    ///   - parts: per part number, its name, picture and colours as (colour id, uses), most common first.
    ///     Colour ids missing from `colors` are left out.
    public init(colors: [CatalogColor], parts: [String: (name: String, img: String?, colors: [(id: Int, uses: Int)])]) {
        var table: [Int: CatalogColor] = [:]
        for color in colors where table[color.id] == nil { table[color.id] = color }
        var out: [String: Part] = [:]
        for (partNum, details) in parts {
            let entries = details.colors.compactMap { (entry: (id: Int, uses: Int)) -> ColorRanking.Entry? in
                guard let color = table[entry.id] else { return nil }
                return ColorRanking.Entry(color: color, uses: entry.uses)
            }
            out[partNum] = Part(name: details.name, img: details.img, colors: entries)
        }
        self.parts = out
    }

    private enum FileKeys: String, CodingKey { case classes, colors }
    private enum ClassKeys: String, CodingKey { case partNum, details }
    private struct Details: Decodable {
        let name: String
        let img: String?
        /// [colour id, uses] pairs.
        let colors: [[Int]]
    }

    public init(from decoder: Decoder) throws {
        let file = try decoder.container(keyedBy: FileKeys.self)
        let colors = try file.decodeIfPresent([CatalogColor].self, forKey: .colors) ?? []
        var list = try file.nestedUnkeyedContainer(forKey: .classes)
        var parts: [String: (name: String, img: String?, colors: [(id: Int, uses: Int)])] = [:]
        while !list.isAtEnd {
            let entry = try list.nestedContainer(keyedBy: ClassKeys.self)
            let partNum = try entry.decode(String.self, forKey: .partNum)
            guard let details = try entry.decodeIfPresent(Details.self, forKey: .details), parts[partNum] == nil else { continue }
            let pairs = details.colors.compactMap { (pair: [Int]) -> (id: Int, uses: Int)? in
                pair.count == 2 ? (id: pair[0], uses: pair[1]) : nil
            }
            parts[partNum] = (name: details.name, img: details.img, colors: pairs)
        }
        self.init(colors: colors, parts: parts)
    }

    /// Reads `classes.json`. Nil if the data is not a class file.
    public static func decode(_ data: Data) -> OfflineCatalog? {
        try? JSONDecoder().decode(OfflineCatalog.self, from: data)
    }

    public func contains(_ partNum: String) -> Bool { parts[partNum] != nil }

    /// The part's name, picture and colours ranked for a measured colour ("rrggbb"), as the server would rank
    /// the colours kept in the file. Nil if the part is not described.
    public func part(_ partNum: String, measuredHex: String?) -> OfflinePart? {
        guard let part = parts[partNum] else { return nil }
        return OfflinePart(partNum: partNum, name: part.name, img: part.img,
                           colors: ColorRanking.rank(part.colors, measuredHex: measuredHex))
    }
}
