import Combine
import Foundation
import Network

enum ConnectionState: Equatable {
    /// Asking the saved address whether a server is there.
    case checking
    case connected(String)
    /// Browsing the local network for the server.
    case searching
    case notFound
}

/// Finds the Brick Inventory server without the user typing an address.
///
/// The server advertises itself on the local network as a Bonjour service. When no address is saved, or
/// the saved one does not answer, this browses for that service, resolves it to a host and port, checks
/// that a server really answers there, and saves the address under `API.serverKey`.
///
/// Everything here runs on the main thread: call `refresh()` from the main thread, Network framework
/// callbacks are delivered on the main queue, and the asynchronous steps run in main-actor tasks.
final class ServerDiscovery: ObservableObject, @unchecked Sendable {
    static let serviceType = "_brickinventory._tcp"

    @Published private(set) var state: ConnectionState = .checking

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var resolving = false
    /// Bumped on every `refresh()` so results of an older attempt are ignored.
    private var generation = 0

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Checks the saved address and, if no server answers there, looks for one on the network.
    func refresh() {
        generation += 1
        let current = generation
        stopBrowsing()
        state = .checking
        let saved = (UserDefaults.standard.string(forKey: API.serverKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor [weak self] in
            var ok = false
            if !saved.isEmpty { ok = await API.reachable(address: saved) }
            guard let self, current == self.generation else { return }
            if ok {
                self.state = .connected(saved)
            } else {
                self.startBrowsing(generation: current)
            }
        }
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        resolving = false
    }

    private func startBrowsing(generation current: Int) {
        state = .searching
        let descriptor = NWBrowser.Descriptor.bonjour(type: ServerDiscovery.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: NWParameters.tcp)
        browser.browseResultsChangedHandler = { [weak self] (results: Set<NWBrowser.Result>, _: Set<NWBrowser.Result.Change>) in
            let endpoints: [NWEndpoint] = results.map { (result: NWBrowser.Result) in result.endpoint }
            self?.found(endpoints, generation: current)
        }
        browser.stateUpdateHandler = { [weak self] (newState: NWBrowser.State) in
            switch newState {
            case .failed, .waiting:
                // Typically the user has not allowed local network access.
                self?.giveUp(generation: current)
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: DispatchQueue.main)

        // Keep browsing after this, but stop saying "looking" when nothing has turned up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.giveUp(generation: current)
        }
    }

    private func giveUp(generation current: Int) {
        guard current == generation, state == .searching, !resolving else { return }
        state = .notFound
    }

    /// Resolves a browse result by connecting to it and reading the address the connection ended up at.
    private func found(_ endpoints: [NWEndpoint], generation current: Int) {
        guard current == generation, !resolving, !isConnected, let endpoint = endpoints.first else { return }
        resolving = true
        let parameters = NWParameters.tcp
        // The server listens on IPv4, and an IPv4 address needs no interface suffix in a URL.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] (newState: NWConnection.State) in
            switch newState {
            case .ready:
                var address: String?
                if let remote = connection?.currentPath?.remoteEndpoint {
                    address = serverAddress(from: remote)
                }
                connection?.cancel()
                self?.resolved(address, generation: current)
            case .failed, .waiting:
                connection?.cancel()
                self?.resolved(nil, generation: current)
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: DispatchQueue.main)
    }

    private func resolved(_ address: String?, generation current: Int) {
        guard current == generation, resolving, connection != nil else { return }
        connection = nil
        guard let address else {
            resolving = false
            state = .notFound
            return
        }
        Task { @MainActor [weak self] in
            let ok = await API.reachable(address: address)
            guard let self, current == self.generation else { return }
            self.resolving = false
            if ok {
                UserDefaults.standard.set(address, forKey: API.serverKey)
                self.stopBrowsing()
                self.state = .connected(address)
            } else {
                self.state = .notFound
            }
        }
    }
}

/// "http://host:port" for a resolved endpoint, or nil if it is not a host and port.
private func serverAddress(from endpoint: NWEndpoint) -> String? {
    guard case let NWEndpoint.hostPort(host, port) = endpoint else { return nil }
    var text: String
    var isIPv6 = false
    switch host {
    case .name(let name, _):
        text = name
    case .ipv4(let address):
        text = "\(address)"
    case .ipv6(let address):
        text = "\(address)"
        isIPv6 = true
    @unknown default:
        return nil
    }
    // Addresses can carry the network interface, as in "192.168.1.20%en0".
    if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
    if text.isEmpty { return nil }
    if isIPv6 { text = "[" + text + "]" }
    return "http://\(text):\(port.rawValue)"
}
