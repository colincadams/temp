import SwiftUI

enum AppTab: Hashable {
    case scan
    case inventory
    case builds
    case settings
}

@main
struct BrickScanApp: App {
    @StateObject private var engine = ScanEngine()
    @StateObject private var discovery = ServerDiscovery()
    /// Scans kept on the phone while the computer could not be reached.
    @StateObject private var pending = PendingScans()
    @AppStorage(IntroView.shownKey) private var introShown = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.scan

    /// The introduction covers the app until it has been read once.
    private var showIntro: Binding<Bool> {
        Binding<Bool>(
            get: { !introShown },
            set: { (show: Bool) in
                if !show { introShown = true }
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                ScanView(openSettings: { tab = AppTab.settings })
                    .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                    .tag(AppTab.scan)
                InventoryView()
                    .tabItem { Label("Inventory", systemImage: "square.grid.2x2") }
                    .tag(AppTab.inventory)
                BuildsView()
                    .tabItem { Label("Builds", systemImage: "hammer") }
                    .tag(AppTab.builds)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag(AppTab.settings)
            }
            .environmentObject(engine)
            .environmentObject(discovery)
            .environmentObject(pending)
            .fullScreenCover(isPresented: showIntro) {
                IntroView(onDone: { introShown = true })
            }
            .task { await MainActor.run { discovery.refresh() } }
            .onChange(of: scenePhase) { (_: ScenePhase, newPhase: ScenePhase) in
                // Back in the foreground: check the saved server again, or look for one on the network,
                // and send any scans kept on the phone.
                if newPhase == .active {
                    discovery.refresh()
                    pending.retry(using: API.shared)
                }
            }
            .onChange(of: discovery.state) { (_: ConnectionState, newState: ConnectionState) in
                // The server has been found: send scans kept while it could not be reached.
                if case .connected = newState { pending.retry(using: API.shared) }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var discovery: ServerDiscovery
    @AppStorage(API.serverKey) private var serverURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ConnectionStatusRow(state: discovery.state)
                    Button("Look again") { discovery.refresh() }
                        .disabled(discovery.state == .checking)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("The app finds Brick Inventory by itself when it is running on a computer on the same Wi-Fi.")
                }

                Section {
                    TextField("192.168.1.20:3000", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Server address")
                    Button("Connect to this address") { discovery.refresh() }
                        .disabled(serverURL.trimmingCharacters(in: .whitespaces).isEmpty || discovery.state == .checking)
                } header: {
                    Text("Server address")
                } footer: {
                    Text("Only needed if the server is not found. On your computer, run “HOST=0.0.0.0 npm start” in the project folder, then enter the computer's address and port here. If nothing answers at this address, the app looks for the server on the network instead.")
                }

                Section("Scanning tips") {
                    Text("Spread pieces in a single layer on a plain surface whose colour differs from the pieces.")
                    Text("Hold the phone flat about 30 cm above the table and sweep slowly in overlapping rows.")
                    Text("Dots show progress: white is seen, yellow is being identified, green is identified, red is not recognised.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Says in words (and with a symbol, not colour alone) whether the app has a server.
struct ConnectionStatusRow: View {
    let state: ConnectionState

    private var text: String {
        switch state {
        case .checking:
            return "Checking the connection…"
        case .connected(let address):
            return "Connected to \(address)"
        case .searching:
            return "Looking for the server on this network…"
        case .notFound:
            return "Not found. Check that Brick Inventory is running on your computer and that the phone is on the same Wi-Fi."
        }
    }

    private var symbol: String {
        switch state {
        case .checking, .searching:
            return "wifi"
        case .connected:
            return "checkmark.circle.fill"
        case .notFound:
            return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Label(text, systemImage: symbol)
    }
}

#if DEBUG
#Preview("Connection states") {
    Form {
        ConnectionStatusRow(state: ConnectionState.connected("http://192.168.1.20:3000"))
        ConnectionStatusRow(state: ConnectionState.searching)
        ConnectionStatusRow(state: ConnectionState.notFound)
    }
}
#endif
