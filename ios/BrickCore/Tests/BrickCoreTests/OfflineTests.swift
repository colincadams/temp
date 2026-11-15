import XCTest
@testable import BrickCore

/// Expected rankings computed by the server's own code; see ml/color_golden.js and the generated
/// ColorRankingGoldenReal.swift (real Rebrickable catalog) and ColorRankingGoldenFixture.swift (test/fixtures).
enum ColorRankingGolden {
    struct Case {
        let part: String
        /// Measured colour; nil ranks by how common each colour is.
        let rgb: String?
        /// Colour ids, best first: the server's ranking restricted to the colours the bundle keeps.
        let expected: [Int]
    }
}

final class ColorRankingTests: XCTestCase {
    func testLabMatchesServerConversion() throws {
        // Values printed by lib/color.js srgbToLab.
        let red = try XCTUnwrap(LabColor(hex: "C91A09"))
        XCTAssertEqual(red.l, 43.02727438290931, accuracy: 1e-9)
        XCTAssertEqual(red.a, 63.80755960902346, accuracy: 1e-9)
        XCTAssertEqual(red.b, 53.71959542575446, accuracy: 1e-9)
        let black = try XCTUnwrap(LabColor(hex: "05131d"))
        XCTAssertEqual(black.l, 5.299777639749514, accuracy: 1e-9)
        XCTAssertEqual(black.a, -1.6560577596649444, accuracy: 1e-9)
        XCTAssertEqual(black.b, -8.374460493002855, accuracy: 1e-9)
        let white = LabColor(r: 255, g: 255, b: 255)
        XCTAssertEqual(white.l, 100, accuracy: 1e-9)
        XCTAssertEqual(white.a, 0.00526049995830391, accuracy: 1e-9)
    }

    func testRejectsTextThatIsNotAColour() {
        XCTAssertNil(LabColor(hex: "12345"))
        XCTAssertNil(LabColor(hex: "zz0000"))
        XCTAssertNil(LabColor(hex: "+12345"))
        XCTAssertNil(LabColor(hex: "1234567"))
    }

    private let red = CatalogColor(id: 4, name: "Red", rgb: "C91A09", isTrans: false)
    private let darkRed = CatalogColor(id: 320, name: "Dark Red", rgb: "720E0F", isTrans: false)
    private let blue = CatalogColor(id: 1, name: "Blue", rgb: "0055BF", isTrans: false)

    func testNearestColourFirstAndCommonnessBreaksCloseCalls() {
        let entries = [ColorRanking.Entry(color: blue, uses: 900), ColorRanking.Entry(color: red, uses: 1000),
                       ColorRanking.Entry(color: darkRed, uses: 1)]
        XCTAssertEqual(ColorRanking.rank(entries, measuredHex: "c01a10").map(\.id), [4, 320, 1])
        XCTAssertEqual(ColorRanking.rank(entries, measuredHex: "1050c0").first?.id, 1)
        // Halfway between red and dark red: red is far more common, so it wins.
        XCTAssertEqual(ColorRanking.rank(entries, measuredHex: "9d140c").first?.id, 4)
    }

    func testWithoutAMeasuredColourMostCommonFirst() {
        let entries = [ColorRanking.Entry(color: darkRed, uses: 5), ColorRanking.Entry(color: red, uses: 50),
                       ColorRanking.Entry(color: blue, uses: 5)]
        XCTAssertEqual(ColorRanking.rank(entries, measuredHex: nil).map(\.id), [4, 320, 1])
        XCTAssertEqual(ColorRanking.rank(entries, measuredHex: "not a colour").map(\.id), [4, 320, 1])
        XCTAssertEqual(ColorRanking.rank([], measuredHex: "ffffff"), [])
    }

    private func checkGolden(bundle: String, cases: [ColorRankingGolden.Case], file: StaticString = #filePath, line: UInt = #line) throws {
        let catalog = try XCTUnwrap(OfflineCatalog.decode(Data(bundle.utf8)), file: file, line: line)
        XCTAssertFalse(cases.isEmpty, file: file, line: line)
        var checked = 0
        for golden in cases {
            let part = try XCTUnwrap(catalog.part(golden.part, measuredHex: golden.rgb), "\(golden.part)", file: file, line: line)
            XCTAssertEqual(part.colors.map(\.id), golden.expected, "\(golden.part) measured \(golden.rgb ?? "none")", file: file, line: line)
            checked += 1
        }
        XCTAssertEqual(checked, cases.count, file: file, line: line)
    }

    /// The phone ranks exactly as the server does, on the real catalog.
    func testMatchesServerOnRealCatalog() throws {
        try checkGolden(bundle: ColorRankingGolden.realCatalogBundle, cases: ColorRankingGolden.realCatalogCases)
    }

    /// And on the server's test fixtures.
    func testMatchesServerOnFixtures() throws {
        try checkGolden(bundle: ColorRankingGolden.fixtureBundle, cases: ColorRankingGolden.fixtureCases)
    }
}

final class OfflineCatalogTests: XCTestCase {
    func testReadsDetailsFromClassFile() throws {
        let json = """
        {"imageSize": 224,
         "classes": [
           {"partNum": "3001", "name": "Brick 2 x 4", "members": ["3001"], "sizeMm": [31.8, 15.8, 11.4],
            "details": {"name": "Brick 2 x 4", "img": "https://example.com/3001.jpg", "colors": [[4, 100], [1, 50], [999, 3]]}},
           {"partNum": "3023", "name": "Plate 1 x 2", "members": ["3023"], "sizeMm": [15.8, 7.8, 3.2]}
         ],
         "colors": [{"id": 4, "name": "Red", "rgb": "C91A09", "isTrans": false},
                    {"id": 1, "name": "Blue", "rgb": "0055BF", "isTrans": false}]}
        """
        let catalog = try XCTUnwrap(OfflineCatalog.decode(Data(json.utf8)))
        XCTAssertEqual(catalog.count, 1)
        XCTAssertTrue(catalog.contains("3001"))
        XCTAssertFalse(catalog.contains("3023"))
        XCTAssertNil(catalog.part("3023", measuredHex: "ffffff"))
        let brick = try XCTUnwrap(catalog.part("3001", measuredHex: "1a50b8"))
        XCTAssertEqual(brick.name, "Brick 2 x 4")
        XCTAssertEqual(brick.img, "https://example.com/3001.jpg")
        // Colour 999 is not in the table and is left out.
        XCTAssertEqual(brick.colors.map(\.id), [1, 4])
        XCTAssertEqual(catalog.part("3001", measuredHex: nil)?.colors.map(\.id), [4, 1])

        // The same file still decodes as the model's class list.
        struct ClassFile: Decodable { let imageSize: Int; let classes: [ShapeClass] }
        let classes = try JSONDecoder().decode(ClassFile.self, from: Data(json.utf8))
        XCTAssertEqual(classes.classes.map(\.partNum), ["3001", "3023"])
    }

    func testClassFileWithoutDetailsIsEmpty() throws {
        let json = #"{"imageSize": 224, "classes": [{"partNum": "3001", "name": "Brick 2 x 4", "members": [], "sizeMm": []}]}"#
        let catalog = try XCTUnwrap(OfflineCatalog.decode(Data(json.utf8)))
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertNil(OfflineCatalog.decode(Data("not json".utf8)))
    }
}

final class PendingScanQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func items(_ qty: Int...) -> [PendingItem] {
        qty.enumerated().map { PendingItem(partNum: "300\($0.offset)", colorId: 4, qty: $0.element, name: "Brick", colorName: "Red", rgb: "C91A09") }
    }

    func testAddKeepsOnlyItemsWithPieces() {
        var queue = PendingScanQueue()
        XCTAssertNil(queue.add(items: items(0), source: "scan", at: t0))
        XCTAssertTrue(queue.isEmpty)
        let scan = queue.add(items: items(2, 0, 3), source: "scan", at: t0)
        XCTAssertEqual(scan?.items.count, 2)
        XCTAssertEqual(queue.pieces, 5)
        XCTAssertEqual(queue.scans.first?.createdAt, t0)
    }

    func testFileRoundTrip() throws {
        var queue = PendingScanQueue()
        let first = try XCTUnwrap(queue.add(items: items(2, 1), source: "scan", at: t0))
        queue.add(items: items(4), source: "scan", at: t0.addingTimeInterval(60))
        queue.record(.unreachable("Can't reach the server"), for: first.id, at: t0.addingTimeInterval(120))
        let data = try queue.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"version\":1"))
        XCTAssertTrue(text.contains("2027-01-15T08:00:00Z"))
        XCTAssertEqual(try PendingScanQueue.decode(data), queue)
    }

    func testDamagedOrNewerFileIsRefused() {
        XCTAssertThrowsError(try PendingScanQueue.decode(Data("{".utf8)))
        XCTAssertThrowsError(try PendingScanQueue.decode(Data(#"{"version": 99, "scans": []}"#.utf8)))
        XCTAssertEqual(try PendingScanQueue.decode(Data(#"{"scans": []}"#.utf8)), PendingScanQueue())
    }

    func testUnreachableStopsTheRoundAndKeepsTheScan() throws {
        var queue = PendingScanQueue()
        let a = try XCTUnwrap(queue.add(items: items(1), source: "scan", at: t0))
        let b = try XCTUnwrap(queue.add(items: items(2), source: "scan", at: t0))
        XCTAssertEqual(queue.toRetry.map(\.id), [a.id, b.id])
        XCTAssertFalse(queue.record(.unreachable("offline"), for: a.id, at: t0))
        XCTAssertEqual(queue.scans.count, 2)
        XCTAssertEqual(queue.scans[0].attempts, 1)
        XCTAssertEqual(queue.scans[0].lastError, "offline")
        XCTAssertEqual(queue.scans[0].lastAttemptAt, t0)
        XCTAssertFalse(queue.scans[0].rejected)
        XCTAssertEqual(queue.toRetry.count, 2)
    }

    func testAddedScansLeaveAndRefusedOnesWait() throws {
        var queue = PendingScanQueue()
        let a = try XCTUnwrap(queue.add(items: items(1), source: "scan", at: t0))
        let b = try XCTUnwrap(queue.add(items: items(2), source: "scan", at: t0))
        XCTAssertTrue(queue.record(.rejected("Unknown part \"3000\""), for: a.id, at: t0))
        XCTAssertTrue(queue.record(.added, for: b.id, at: t0))
        XCTAssertEqual(queue.scans.map(\.id), [a.id])
        XCTAssertTrue(queue.scans[0].rejected)
        XCTAssertTrue(queue.toRetry.isEmpty)
        queue.clearRejections()
        XCTAssertEqual(queue.toRetry.map(\.id), [a.id])
        queue.discard(id: a.id)
        XCTAssertTrue(queue.isEmpty)
    }

    func testOutcomeForADiscardedScan() {
        var queue = PendingScanQueue()
        XCTAssertTrue(queue.record(.added, for: UUID(), at: t0))
        XCTAssertFalse(queue.record(.unreachable("offline"), for: UUID(), at: t0))
    }
}
