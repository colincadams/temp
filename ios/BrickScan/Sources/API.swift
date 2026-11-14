import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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

    private var baseURL: URL? {
        var text = (UserDefaults.standard.string(forKey: API.serverKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                                       body: Data? = nil, contentType: String? = nil) async throws -> T {
        guard let base = baseURL, var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError(message: "Set the server address in Settings first.")
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
            throw APIError(message: "Can't reach the server at \(base.absoluteString). Is it running with HOST=0.0.0.0, and is the phone on the same Wi-Fi?")
        }
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "Unexpected response from the server.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError(message: message ?? "The server returned an error (\(http.statusCode)).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError(message: "Could not read the server's reply.")
        }
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

    func add(_ items: [NewItem]) async throws -> InventoryResponse {
        try await request("api/inventory/add", method: "POST", body: try json(NewItems(items: items)), contentType: "application/json")
    }

    func setQuantity(partNum: String, colorId: Int, qty: Int) async throws -> InventoryResponse {
        try await request("api/inventory/set", method: "POST", body: try json(NewItem(partNum: partNum, colorId: colorId, qty: qty)), contentType: "application/json")
    }

    func builds(search: String, ignoreColor: Bool, variants: Bool, offset: Int, limit: Int = 40) async throws -> BuildsResponse {
        try await request("api/builds", query: [
            URLQueryItem(name: "q", value: search),
            URLQueryItem(name: "ignoreColor", value: ignoreColor ? "1" : "0"),
            URLQueryItem(name: "variants", value: variants ? "1" : "0"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    func buildDetail(setNum: String, ignoreColor: Bool, variants: Bool) async throws -> BuildDetail {
        try await request("api/builds/\(setNum)", query: [
            URLQueryItem(name: "ignoreColor", value: ignoreColor ? "1" : "0"),
            URLQueryItem(name: "variants", value: variants ? "1" : "0"),
        ])
    }
}
