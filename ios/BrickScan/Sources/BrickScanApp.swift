import SwiftUI

@main
struct BrickScanApp: App {
    @StateObject private var engine = ScanEngine()

    var body: some Scene {
        WindowGroup {
            TabView {
                ScanView()
                    .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                InventoryView()
                    .tabItem { Label("Inventory", systemImage: "square.grid.2x2") }
                BuildsView()
                    .tabItem { Label("Builds", systemImage: "hammer") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            .environmentObject(engine)
        }
    }
}

struct SettingsView: View {
    @AppStorage(API.serverKey) private var serverURL = ""
    @State private var status: String?
    @State private var ok = false
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.20:3000", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(testing ? "Testing…" : "Test connection") { test() }
                        .disabled(testing || serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let status {
                        Text(status).foregroundStyle(ok ? Color.green : Color.red)
                    }
                } header: {
                    Text("Server address")
                } footer: {
                    Text("On your computer, run “HOST=0.0.0.0 npm start” in the project folder, then enter the computer's address and port here. The phone must be on the same Wi-Fi.")
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

    private func test() {
        testing = true
        status = nil
        Task {
            do {
                let meta = try await API.shared.meta()
                ok = true
                status = "Connected. Catalog has \(meta.setCount) sets."
            } catch {
                ok = false
                status = error.localizedDescription
            }
            testing = false
        }
    }
}
