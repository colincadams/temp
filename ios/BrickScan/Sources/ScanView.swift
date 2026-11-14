import ARKit
import Combine
import SceneKit
import SwiftUI

/// Live camera view with a dot floating over every piece found so far.
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
    @AppStorage(API.serverKey) private var serverURL = ""
    @State private var reviewing = false

    private var identified: Int { engine.pieces.filter { $0.state == .identified }.count }

    var body: some View {
        ZStack {
            ARScanView(engine: engine).ignoresSafeArea(edges: .top)

            VStack(spacing: 8) {
                Text(serverURL.isEmpty ? "Set the server address in Settings to identify pieces" : engine.hint)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                if let error = engine.lastError {
                    Text(error)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        engine.torchOn.toggle()
                    } label: {
                        Image(systemName: engine.torchOn ? "flashlight.on.fill" : "flashlight.off.fill").frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Light")

                    Button("Start over") { engine.reset() }
                        .disabled(engine.pieces.isEmpty)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(engine.pieces.count) pieces").font(.headline)
                        Text("\(identified) identified").font(.caption)
                    }

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
        .onAppear { engine.start() }
        .onDisappear { engine.pause() }
        .sheet(isPresented: $reviewing) {
            ReviewView(pieces: engine.pieces) { engine.reset() }
        }
    }
}
