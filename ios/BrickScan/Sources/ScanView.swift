import ARKit
import AVFoundation
import Combine
import SceneKit
import SwiftUI
import UIKit

/// Live camera view with a dot floating over every piece found so far.
/// Dot colours (white seen, yellow identifying, green identified, red unknown) match `CoverageMapView`.
struct ARScanView: UIViewRepresentable {
    let engine: ScanEngine

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.scene = SCNScene()
        view.session = engine.session
        view.automaticallyUpdatesLighting = false
        context.coordinator.attach(to: view, engine: engine)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    final class Coordinator {
        private weak var view: ARSCNView?
        private var nodes: [UUID: SCNNode] = [:]
        private var subscription: AnyCancellable?
        private let markers: [PieceState: SCNGeometry] = {
            func dot(_ color: UIColor) -> SCNGeometry {
                let sphere = SCNSphere(radius: 0.0035)
                sphere.firstMaterial?.diffuse.contents = color
                sphere.firstMaterial?.lightingModel = .constant
                return sphere
            }
            return [.seen: dot(.white), .identifying: dot(.systemYellow), .identified: dot(.systemGreen), .unknown: dot(.systemRed)]
        }()

        func attach(to view: ARSCNView, engine: ScanEngine) {
            self.view = view
            subscription = engine.$pieces.receive(on: DispatchQueue.main).sink { [weak self] in self?.sync($0) }
        }

        private func sync(_ pieces: [PieceSnapshot]) {
            guard let root = view?.scene.rootNode else { return }
            var live = Set<UUID>()
            for piece in pieces {
                live.insert(piece.id)
                let node: SCNNode
                if let existing = nodes[piece.id] {
                    node = existing
                } else {
                    node = SCNNode()
                    nodes[piece.id] = node
                    root.addChildNode(node)
                }
                node.geometry = markers[piece.state]
                node.simdPosition = piece.position + SIMD3<Float>(0, 0.02, 0)
            }
            for (id, node) in nodes where !live.contains(id) {
                node.removeFromParentNode()
                nodes[id] = nil
            }
        }
    }
}

struct ScanView: View {
    @EnvironmentObject private var engine: ScanEngine
    @EnvironmentObject private var discovery: ServerDiscovery
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(IntroView.shownKey) private var introShown = false
    @State private var reviewing = false
    @State private var visible = false
    @State private var camera: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    /// Switches to the Settings tab.
    let openSettings: () -> Void

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
    }

    private var identified: Int { engine.pieces.filter { $0.state == .identified }.count }
    private var cameraBlocked: Bool { camera == .denied || camera == .restricted }

    /// True when the app knows it has no server: it is looking for one, or has given up.
    private var serverMissing: Bool {
        discovery.state == .searching || discovery.state == .notFound
    }

    var body: some View {
        Group {
            if cameraBlocked {
                CameraDeniedView()
            } else {
                scanner
            }
        }
        .onAppear {
            visible = true
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            startIfAllowed()
        }
        .onDisappear {
            visible = false
            engine.pause()
        }
        .onChange(of: scenePhase) { (_: ScenePhase, newPhase: ScenePhase) in
            // Coming back from the Settings app, or from the camera permission prompt.
            guard newPhase == .active else { return }
            let wasBlocked = cameraBlocked
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            if cameraBlocked {
                engine.pause()
            } else if wasBlocked && visible {
                startIfAllowed()
            }
        }
        .onChange(of: introShown) { (_: Bool, _: Bool) in
            if visible { startIfAllowed() }
        }
        .sheet(isPresented: $reviewing) {
            ReviewView(pieces: engine.pieces, service: API.shared) { engine.reset() }
        }
    }

    /// The camera starts only after the introduction, so its permission prompt is not the first thing shown.
    private func startIfAllowed() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if introShown && status != .denied && status != .restricted { engine.start() }
    }

    private var scanner: some View {
        ZStack {
            ARScanView(engine: engine).ignoresSafeArea(edges: .top)

            VStack(spacing: 8) {
                if serverMissing {
                    ServerMissingBanner(searching: discovery.state == .searching, openSettings: openSettings)
                } else {
                    Text(engine.hint)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if let error = engine.lastError {
                    Text(error)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 10) {
                    if engine.coverage.guess != .noPieces {
                        CoverageStatusView(guess: engine.coverage.guess, canReview: identified > 0) { reviewing = true }
                    }
                    Spacer(minLength: 0)
                    if engine.tableFound || !engine.coverage.cells.isEmpty {
                        CoverageMapView(snapshot: engine.coverage)
                            .frame(width: 128, height: 128)
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        engine.torchOn.toggle()
                    } label: {
                        Image(systemName: engine.torchOn ? "flashlight.on.fill" : "flashlight.off.fill").frame(width: 24, height: 24)
                    }
                    .accessibilityLabel(engine.torchOn ? "Turn the light off" : "Turn the light on")

                    Button("Start over") { engine.reset() }
                        .disabled(engine.pieces.isEmpty)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(BatchText.pieces(engine.pieces.count)).font(.headline)
                        Text("\(identified) identified").font(.caption)
                    }
                    .accessibilityElement(children: .combine)

                    Button("Review") { reviewing = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(identified == 0)
                }
                .buttonStyle(.bordered)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding()
        }
        .onChange(of: engine.coverage.guess.looksComplete) { (_: Bool, complete: Bool) in
            // The prompt appears without moving focus, so say it.
            if complete {
                let text = CoverageStatusView.text(for: engine.coverage.guess, canReview: identified > 0)
                UIAccessibility.post(notification: .announcement, argument: text)
            }
        }
    }
}

/// Shown over the camera when there is no server to name the pieces.
private struct ServerMissingBanner: View {
    let searching: Bool
    let openSettings: () -> Void

    var body: some View {
        let title: String = searching ? "Looking for the server on this network…" : "Not connected to the server"
        let symbol: String = searching ? "wifi" : "wifi.slash"
        VStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            if !searching {
                Text("Pieces cannot be identified without it. Start Brick Inventory on your computer and keep the phone on the same Wi-Fi.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Shown instead of the camera when the app is not allowed to use it.
private struct CameraDeniedView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Brick Scan needs the camera")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("The camera is how the app finds and identifies your pieces. Allow camera access for Brick Scan in Settings, then come back.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

#if DEBUG
#Preview("Camera not allowed") {
    CameraDeniedView()
}

#Preview("Server not found") {
    ServerMissingBanner(searching: false, openSettings: { })
        .padding()
}
#endif
