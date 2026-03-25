import ARKit
import RealityKit
import SwiftUI
import simd

/// LiDAR scene mesh capture: tap on a foot; we cluster mesh vertices near the hit and
/// derive **foot length** (heel–toe, longer horizontal span) and **ball width** (shorter span)
/// in millimeters — aligned with Mondopoint length + forefoot width used for fitting.
final class FootScanARViewController: UIViewController, ARSessionDelegate {
    var onCaptured: ((FootSideMeasurement) -> Void)?
    var onError: ((String) -> Void)?

    private var arView: ARView!
    private var statusLabel: UILabel!
    private var captureButton: UIButton!
    private var debugTextView: UITextView!

    private var lastDebugTextUpdate: TimeInterval = 0
    private var meshOverlayReapplyCount = 0
    private var sessionInterrupted = false
    private var lastSessionError: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            onError?("This device does not support LiDAR scene mesh. Use a Pro model iPhone/iPad or enter measurements manually.")
            return
        }

        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.translatesAutoresizingMaskIntoConstraints = false
        arView.session.delegate = self
        view.addSubview(arView)
        NSLayoutConstraint.activate([
            arView.topAnchor.constraint(equalTo: view.topAnchor),
            arView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic
        arView.session.run(config)

        ensureMeshDebugOverlay()

        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.text = "You should see the 3D mesh overlay on surfaces. Point at your feet, tap a foot, then Capture."
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])

        captureButton = UIButton(type: .system)
        captureButton.setTitle("Capture foot region", for: .normal)
        captureButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        captureButton.backgroundColor = UIColor.systemBlue
        captureButton.setTitleColor(.white, for: .normal)
        captureButton.layer.cornerRadius = 12
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        view.addSubview(captureButton)
        NSLayoutConstraint.activate([
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            captureButton.widthAnchor.constraint(equalToConstant: 240),
            captureButton.heightAnchor.constraint(equalToConstant: 48),
        ])

        debugTextView = UITextView()
        debugTextView.translatesAutoresizingMaskIntoConstraints = false
        debugTextView.isEditable = false
        debugTextView.isScrollEnabled = true
        debugTextView.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        debugTextView.textColor = .white
        debugTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        debugTextView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        debugTextView.text = "Debug: starting session…"
        view.addSubview(debugTextView)
        NSLayoutConstraint.activate([
            debugTextView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            debugTextView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            debugTextView.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -12),
            debugTextView.heightAnchor.constraint(equalToConstant: 150),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(screenTapped(_:)))
        arView.addGestureRecognizer(tap)
    }

    /// RealityKit can clear `debugOptions` when the session reconfigures; re-applying fixes “mesh vanished”.
    private func ensureMeshDebugOverlay() {
        if !arView.debugOptions.contains(.showSceneUnderstanding) {
            arView.debugOptions.insert(.showSceneUnderstanding)
            meshOverlayReapplyCount += 1
        }
    }

    private func appendDebugLine(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.debugTextView.text = (self.debugTextView.text ?? "") + "\n" + line
            let len = (self.debugTextView.text as NSString).length
            if len > 0 {
                let bottom = NSRange(location: len - 1, length: 1)
                self.debugTextView.scrollRangeToVisible(bottom)
            }
        }
    }

    private var lastTapScreenPoint: CGPoint?

    @objc private func screenTapped(_ gr: UITapGestureRecognizer) {
        lastTapScreenPoint = gr.location(in: arView)
        statusLabel.text = "Tap Capture to sample mesh near this point."
    }

    @objc private func captureTapped() {
        guard let point = lastTapScreenPoint else {
            statusLabel.text = "Tap on the foot in the AR view first."
            return
        }

        guard let ray = arView.ray(through: point) else {
            onError?("Could not cast a ray through the tap point.")
            return
        }

        let worldOrigin = ray.origin
        let worldDir = simd_normalize(ray.direction)

        guard let hit = closestMeshPoint(toRayOrigin: worldOrigin, direction: worldDir) else {
            onError?("No mesh hit. Aim at the foot and tap again.")
            return
        }

        let center = hit
        let radius: Float = 0.2
        var worldVertices: [SIMD3<Float>] = []
        worldVertices.reserveCapacity(4096)

        for anchor in arView.session.currentFrame?.anchors ?? [] {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let verts = meshVertexWorldPositions(anchor: meshAnchor)
            for v in verts where simd_distance(v, center) <= radius {
                worldVertices.append(v)
            }
        }

        guard worldVertices.count >= 80 else {
            onError?("Not enough mesh near the tap (\(worldVertices.count) pts). Move closer, improve lighting, and try again.")
            return
        }

        let xs = worldVertices.map(\.x)
        let zs = worldVertices.map(\.z)
        guard let minX = xs.min(), let maxX = xs.max(), let minZ = zs.min(), let maxZ = zs.max() else {
            onError?("Could not compute bounds.")
            return
        }

        let dx = Double(maxX - minX) * 1000.0
        let dz = Double(maxZ - minZ) * 1000.0
        let lengthMm = max(dx, dz)
        let widthMm = min(dx, dz)

        guard lengthMm > 80, lengthMm < 400, widthMm > 30, widthMm < 200 else {
            onError?("Unrealistic dimensions (\(Int(lengthMm)) × \(Int(widthMm)) mm). Tap closer to a single foot.")
            return
        }

        let measurement = FootSideMeasurement(lengthMm: lengthMm, ballWidthMm: widthMm)
        onCaptured?(measurement)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        if now - lastDebugTextUpdate < 0.25 { return }
        lastDebugTextUpdate = now

        ensureMeshDebugOverlay()

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }.count
        let tracking = describeTracking(frame.camera.trackingState)
        let light = frame.lightEstimate.map { est in
            String(format: "%.0f lx", est.ambientIntensity)
        } ?? "n/a"

        let overlayOn = arView.debugOptions.contains(.showSceneUnderstanding)
        let lines = """
        t=\(String(format: "%.2f", now)) tracking=\(tracking)
        anchors mesh=\(meshAnchors) total=\(frame.anchors.count)
        mesh overlay flag=\(overlayOn) reapplies=\(meshOverlayReapplyCount)
        light=\(light) interrupted=\(sessionInterrupted)
        session err: \(lastSessionError ?? "none")
        """
        DispatchQueue.main.async { [weak self] in
            self?.debugTextView.text = lines
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        sessionInterrupted = true
        appendDebugLine("sessionWasInterrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        sessionInterrupted = false
        appendDebugLine("sessionInterruptionEnded — resuming (no reset; reset clears mesh)")
        if let config = session.configuration {
            session.run(config, options: [])
        }
        ensureMeshDebugOverlay()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        lastSessionError = error.localizedDescription
        appendDebugLine("didFailWithError: \(error.localizedDescription)")
    }

    private func describeTracking(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "limited(excessiveMotion)"
            case .insufficientFeatures: return "limited(insufficientFeatures)"
            case .initializing: return "limited(initializing)"
            case .relocalizing: return "limited(relocalizing)"
            @unknown default: return "limited(unknown)"
            }
        @unknown default:
            return "unknown"
        }
    }

    /// Nearest scene-mesh vertex to the camera ray (within a tube), used as the foot region center.
    private func closestMeshPoint(toRayOrigin origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        let dir = simd_normalize(direction)
        var bestPerp: Float = 0.18
        var best: SIMD3<Float>?
        for anchor in arView.session.currentFrame?.anchors ?? [] {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let verts = meshVertexWorldPositions(anchor: meshAnchor)
            for i in stride(from: 0, to: verts.count, by: 2) {
                let v = verts[i]
                let t = simd_dot(v - origin, dir)
                guard t > 0.08, t < 4.0 else { continue }
                let proj = origin + dir * t
                let perp = simd_distance(v, proj)
                if perp < bestPerp {
                    bestPerp = perp
                    best = v
                }
            }
        }
        return best
    }

    private func meshVertexWorldPositions(anchor: ARMeshAnchor) -> [SIMD3<Float>] {
        let geometry = anchor.geometry
        let src = geometry.vertices
        let count = src.count
        let stride = src.stride
        let offset = src.offset
        let buffer = src.buffer.contents()
        let transform = anchor.transform
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let byteOffset = offset + stride * i
            let ptr = buffer.advanced(by: byteOffset).assumingMemoryBound(to: SIMD3<Float>.self)
            let local = ptr.pointee
            let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            out.append(SIMD3<Float>(world.x, world.y, world.z))
        }
        return out
    }
}

struct ARFootScannerSheet: UIViewControllerRepresentable {
    var onCaptured: (FootSideMeasurement) -> Void
    var onError: (String) -> Void
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> FootScanARViewController {
        let c = FootScanARViewController()
        c.onCaptured = { m in
            onCaptured(m)
            onDismiss()
        }
        c.onError = { msg in
            onError(msg)
        }
        return c
    }

    func updateUIViewController(_ uiViewController: FootScanARViewController, context: Context) {}
}
