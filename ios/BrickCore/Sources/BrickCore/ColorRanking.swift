import Foundation

/// A Rebrickable colour, as the server and `classes.json` describe it.
public struct CatalogColor: Codable, Hashable, Sendable {
    public let id: Int
    public let name: String
    /// "RRGGBB".
    public let rgb: String
    public let isTrans: Bool

    public init(id: Int, name: String, rgb: String, isTrans: Bool) {
        self.id = id
        self.name = name
        self.rgb = rgb
        self.isTrans = isTrans
    }
}

/// CIE L*a*b* (D65), the space colours are compared in.
public struct LabColor: Equatable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// The same conversion as the server's `srgbToLab` (lib/color.js).
    public init(r: Double, g: Double, b blue: Double) {
        func linear(_ c: Double) -> Double {
            let v = c / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let R = linear(r), G = linear(g), B = linear(blue)
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        let fx = f(x), fy = f(y), fz = f(z)
        self.init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// Red, green and blue (0...255) of "rrggbb", or nil if the text is not six hex digits.
    public static func components(hex: String) -> (r: Int, g: Int, b: Int)? {
        guard hex.utf8.count == 6, hex.allSatisfy({ $0.isHexDigit }), let v = Int(hex, radix: 16) else { return nil }
        return ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    }

    /// The colour of "rrggbb", or nil if the text is not six hex digits.
    public init?(hex: String) {
        guard let c = LabColor.components(hex: hex) else { return nil }
        self.init(r: Double(c.r), g: Double(c.g), b: Double(c.b))
    }
}

/// Orders the colours a part is made in by how likely each is to be a measured colour,
/// as the server's `colorsForPart` does (lib/catalog.js).
///
/// Photos shift colours (exposure, shadows), so lightness counts for less than hue, and colours the part
/// commonly comes in get a small head start over rare ones: the score is the Lab distance with lightness
/// weighted 0.7, minus 4·log10 of how many set inventories have the part in that colour. Lowest score first.
public enum ColorRanking {
    public static let lightnessWeight = 0.7
    public static let commonnessWeight = 4.0

    /// One colour a part comes in, ready to rank.
    public struct Entry: Sendable {
        public let color: CatalogColor
        /// Set inventory rows with the part in this colour.
        public let uses: Int
        public let lab: LabColor

        public init(color: CatalogColor, uses: Int) {
            self.color = color
            self.uses = uses
            self.lab = LabColor(hex: color.rgb) ?? LabColor(r: 0, g: 0, b: 0)
        }
    }

    /// The score of one colour for a measured colour; lower is a better match.
    public static func score(_ entry: Entry, measured: LabColor) -> Double {
        let dl = (entry.lab.l - measured.l) * lightnessWeight
        let da = entry.lab.a - measured.a, db = entry.lab.b - measured.b
        return (dl * dl + da * da + db * db).squareRoot() - commonnessWeight * log10(Double(max(entry.uses, 1)))
    }

    /// `entries` best match first. Equal scores keep the order given.
    /// Without a measured colour (nil, or not "rrggbb"), the most common colour comes first.
    public static func rank(_ entries: [Entry], measuredHex: String?) -> [CatalogColor] {
        let order: [Int]
        if let hex = measuredHex, let measured = LabColor(hex: hex) {
            let scores = entries.map { score($0, measured: measured) }
            order = entries.indices.sorted { scores[$0] != scores[$1] ? scores[$0] < scores[$1] : $0 < $1 }
        } else {
            order = entries.indices.sorted { entries[$0].uses != entries[$1].uses ? entries[$0].uses > entries[$1].uses : $0 < $1 }
        }
        return order.map { entries[$0].color }
    }
}
