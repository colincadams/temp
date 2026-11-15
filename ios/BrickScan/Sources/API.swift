import Foundation

struct APIError: LocalizedError {
    let message: String
    /// True when no server answered at all (no address yet, or nothing reachable there), as opposed to
    /// a server that answered with an error. Scans that fail this way are kept on the phone and sent later.
    var unreachable = false
    var errorDescription: String? { message }

    /// Whether `error` means the server could not be reached.
    static func isUnreachable(_ error: Error) -> Bool {
        if let error = error as? APIError { return error.unreachable }
        return error is URLError
    }
}

/// Client for the Brick Inventory server (`server.js`) running on your computer.
final class API {
    static let shared = API()
    static let serverKey = "serverURL"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 40
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    var isConfigured: Bool { baseURL != nil }

    /// Turns what the user typed ("192.168.1.20:3000") into a base address.
    static func url(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    /// True when a Brick Inventory server answers at `address`. Used to check a saved or discovered address.
    static func reachable(address: String) async -> Bool {
        guard let base = url(from: address) else { return false }
        var req = URLRequest(url: base.appendingPathComponent("api/meta"))
        req.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            return (try? JSONDecoder().decode(MetaResponse.self, from: data)) != nil
        } catch {
            return false
        }
    }

    private var baseURL: URL? {
        API.url(from: UserDefaults.standard.string(forKey: API.serverKey) ?? "")
    }

    /// Sends a request and returns the raw body of a successful reply.
    private func send(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                      body: Data? = nil, contentType: String? = nil) async throws -> Data {
        guard let base = baseURL, var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError(message: "The app is not connected to the server yet. Check Settings.", unreachable: true)
        }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw APIError(message: "The server address is not valid.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError(message: "Can't reach the server at \(base.absoluteString). Is it running, and is the phone on the same Wi-Fi?",
                           unreachable: true)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "Unexpected response from the server.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError(message: message ?? "The server returned an error (\(http.statusCode)).")
        }
        return data
    }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                                       body: Data? = nil, contentType: String? = nil) async throws -> T {
        let data = try await send(path, query: query, method: method, body: body, contentType: contentType)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError(message: "Could not read the server's reply.")
        }
    }

    private func text(_ path: String, query: [URLQueryItem] = []) async throws -> String {
        let data = try await send(path, query: query)
        guard let text = String(data: data, encoding: .utf8) else { throw APIError(message: "Could not read the server's reply.") }
        return text
    }

    private func json<B: Encodable>(_ value: B) throws -> Data { try JSONEncoder().encode(value) }

    func meta() async throws -> MetaResponse { try await request("api/meta") }

    /// - Parameters:
    ///   - rgbHex: measured colour of the piece, "rrggbb".
    ///   - longMm: measured longest side, used by the server to separate same-shape parts of different sizes.
    func identify(jpeg: Data, rgbHex: String, longMm: Float?) async throws -> [Candidate] {
        var query = [URLQueryItem(name: "rgb", value: rgbHex)]
        if let longMm, longMm > 0 { query.append(URLQueryItem(name: "longMm", value: String(format: "%.1f", longMm))) }
        let out: IdentifyResponse = try await request("api/identify", query: query, method: "POST", body: jpeg, contentType: "image/jpeg")
        return out.candidates
    }

    /// Names, images and colour rankings for parts recognised on the phone.
    func partInfo(partNums: [String], rgbHex: String) async throws -> [Candidate] {
        let out: PartInfoResponse = try await request("api/parts/info", query: [
            URLQueryItem(name: "nums", value: partNums.joined(separator: ",")),
            URLQueryItem(name: "rgb", value: rgbHex),
        ])
        return out.parts
    }

    func inventory() async throws -> InventoryResponse { try await request("api/inventory") }

    func inventoryCSV() async throws -> String { try await text("api/inventory.csv") }

    func add(_ items: [NewItem], source: String, clientId: String) async throws -> InventoryResponse {
        let body = NewItems(items: items, source: source, clientId: clientId)
        return try await request("api/inventory/add", method: "POST", body: try json(body), contentType: "application/json")
    }

    func setQuantity(partNum: String, colorId: Int, qty: Int) async throws -> InventoryResponse {
        try await request("api/inventory/set", method: "POST", body: try json(NewItem(partNum: partNum, colorId: colorId, qty: qty)), contentType: "application/json")
    }

    // MARK: Batches

    /// Everything added to the inventory, newest first.
    func batches() async throws -> [BatchInfo] {
        let out: BatchesResponse = try await request("api/batches")
        return out.batches
    }

    /// Takes a batch's pieces back out of the inventory.
    func undoBatch(id: String) async throws -> InventoryResponse {
        try await request("api/batches/\(id)", method: "DELETE")
    }

    /// An earlier batch these items closely resemble, if there is one.
    func checkBatch(_ items: [NewItem]) async throws -> SimilarBatch? {
        let out: BatchCheckResponse = try await request("api/batches/check", method: "POST", body: try json(NewItems(items: items)), contentType: "application/json")
        return out.similar
    }

    /// Tells the server what a scanned piece really was, with its crop, so recognition can be improved.
    func sendCorrection(jpeg: Data, partNum: String, colorId: Int, predicted: String, longMm: Float) async throws {
        _ = try await send("api/corrections", query: [
            URLQueryItem(name: "partNum", value: partNum),
            URLQueryItem(name: "colorId", value: String(colorId)),
            URLQueryItem(name: "predicted", value: predicted),
            URLQueryItem(name: "longMm", value: String(format: "%.1f", longMm)),
        ], method: "POST", body: jpeg, contentType: "image/jpeg")
    }

    // MARK: Builds

    func builds(query: BuildQuery, offset: Int) async throws -> BuildsResponse {
        var items = [
            URLQueryItem(name: "q", value: query.search),
            URLQueryItem(name: "ignoreColor", value: query.ignoreColor ? "1" : "0"),
            URLQueryItem(name: "variants", value: query.variants ? "1" : "0"),
            URLQueryItem(name: "sort", value: query.sort.rawValue),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: "40"),
        ]
        if query.favouritesOnly { items.append(URLQueryItem(name: "favourites", value: "1")) }
        if let minYear = query.minYear { items.append(URLQueryItem(name: "minYear", value: String(minYear))) }
        if let maxYear = query.maxYear { items.append(URLQueryItem(name: "maxYear", value: String(maxYear))) }
        return try await request("api/builds", query: items)
    }

    func buildDetail(setNum: String, ignoreColor: Bool, variants: Bool) async throws -> BuildDetail {
        try await request("api/builds/\(setNum)", query: [
            URLQueryItem(name: "ignoreColor", value: ignoreColor ? "1" : "0"),
            URLQueryItem(name: "variants", value: variants ? "1" : "0"),
        ])
    }

    func missingCSV(setNum: String, ignoreColor: Bool, variants: Bool) async throws -> String {
        try await text("api/builds/\(setNum)/missing.csv", query: [
            URLQueryItem(name: "ignoreColor", value: ignoreColor ? "1" : "0"),
            URLQueryItem(name: "variants", value: variants ? "1" : "0"),
        ])
    }

    /// Marks or unmarks a set as a favourite. Returns every favourite set number.
    func setFavourite(setNum: String, on: Bool) async throws -> [String] {
        let out: FavouritesResponse = try await request("api/favourites/\(setNum)", method: on ? "PUT" : "DELETE")
        return out.sets
    }
}

/// What the screens need from the server. `API` is the real thing; previews pass sample data instead.
protocol BrickService {
    func inventory() async throws -> InventoryResponse
    func inventoryCSV() async throws -> String
    /// `clientId` identifies the save: the server ignores a second save with the same id.
    func add(_ items: [NewItem], source: String, clientId: String) async throws -> InventoryResponse
    func setQuantity(partNum: String, colorId: Int, qty: Int) async throws -> InventoryResponse
    func batches() async throws -> [BatchInfo]
    func undoBatch(id: String) async throws -> InventoryResponse
    func checkBatch(_ items: [NewItem]) async throws -> SimilarBatch?
    func sendCorrection(jpeg: Data, partNum: String, colorId: Int, predicted: String, longMm: Float) async throws
    func builds(query: BuildQuery, offset: Int) async throws -> BuildsResponse
    func buildDetail(setNum: String, ignoreColor: Bool, variants: Bool) async throws -> BuildDetail
    func missingCSV(setNum: String, ignoreColor: Bool, variants: Bool) async throws -> String
    func setFavourite(setNum: String, on: Bool) async throws -> [String]
}

extension API: BrickService {}

enum ExportFile {
    /// Writes text to a temporary file so it can be shared as a file. Returns nil if it cannot be written.
    static func write(_ text: String, named name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
