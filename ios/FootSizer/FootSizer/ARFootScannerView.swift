import ARKit
import RealityKit
import SwiftUI
import UIKit
import simd

/// LiDAR capture: tap on a foot, then **Capture**. We accumulate **dense scene-depth samples**
/// (plus nearby mesh vertices) in a sphere around the tap — much higher resolution than
/// `ARMeshAnchor` alone — then derive **foot length** and **ball width** (mm) from a horizontal AABB.
final class FootScanARViewController: UIViewController, ARSessionDelegate {
    var onCaptured: ((FootSideMeasurement) -> Void)?
    var onError: ((String) -> Void)?
    /// "left" / "right" — only used to label the recorded scan bundle.
    var side: String?
    /// Called on the main thread after a scan bundle has been written to disk.
    var onScanRecorded: (() -> Void)?

    private var arView: ARView!
    private var statusLabel: UILabel!
    private var trackingWarningLabel: UILabel!
    private var captureButton: UIButton!
    private var debugTextView: UITextView!

    private var lastDebugTextUpdate: TimeInterval = 0
    private var lastMeshSyncTime: TimeInterval = 0
    private var sessionInterrupted = false
    private var lastSessionError: String?
    private var lastMeshBuildError: String?
    private var lastDepthSampleCount: Int = 0

    /// RealityKit entities for scene mesh (bright blue); keyed by `ARMeshAnchor.identifier`.
    private var meshAnchorEntities = [UUID: AnchorEntity]()

    /// High-res depth accumulation (0 = idle).
    private var scanFramesRemaining: Int = 0
    private var scanCenter: SIMD3<Float> = .zero
    private var scanAccumPoints: [SIMD3<Float>] = []
    private var scanVoxelKeys: Set<String> = []
    /// Parallel to `scanAccumPoints`: which fused frame each point came from (recorded bundles).
    private var scanAccumFrame: [UInt8] = []
    private var scanFrames: [ScanBundleMeta.Frame] = []
    private let scanFrameCount = 10
    private let scanRadiusMeters: Float = 0.22
    private let maxScanPoints = 40_000
    private var footPointCloudAnchor: AnchorEntity?

    /// Unlit so the mesh stays visible in AR (lit `SimpleMaterial` can look black with no scene lights).
    private static func sceneMeshMaterial() -> RealityKit.Material {
        var mat = UnlitMaterial()
        mat.color = .init(
            tint: UIColor(red: 0.12, green: 0.55, blue: 1.0, alpha: 0.55),
            texture: nil
        )
        if #available(iOS 18.0, *) {
            mat.faceCulling = .none
        }
        return mat
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        guard supportsMesh else {
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
        // ARKit does not expose a “finer mesh” LOD; reconstruction detail is OS-defined.
        // Prefer classified mesh when available (same underlying density, adds face labels).
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else {
            config.sceneReconstruction = .mesh
        }
        // Skip HDR environment maps — reduces GPU work; not needed for foot mesh capture.
        config.environmentTexturing = .none
        // RealityKit scene graph updates must run on the main queue; default delegate queue is background.
        arView.session.delegateQueue = DispatchQueue.main
        arView.session.run(config)
        // Always show Apple’s scene mesh wireframe as fallback; custom blue mesh draws on top when it succeeds.
        arView.debugOptions.insert(.showSceneUnderstanding)

        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.text = "Scan the floor slowly first. Point at a foot, tap where it sits, then Capture — we fuse many LiDAR depth frames for a dense green point cloud."
        view.addSubview(statusLabel)

        trackingWarningLabel = UILabel()
        trackingWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        trackingWarningLabel.numberOfLines = 0
        trackingWarningLabel.font = .preferredFont(forTextStyle: .caption1)
        trackingWarningLabel.textColor = .white
        trackingWarningLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.92)
        trackingWarningLabel.layer.cornerRadius = 8
        trackingWarningLabel.layer.masksToBounds = true
        trackingWarningLabel.isHidden = true
        trackingWarningLabel.textAlignment = .center
        view.addSubview(trackingWarningLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            trackingWarningLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            trackingWarningLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            trackingWarningLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
        ])

        captureButton = UIButton(type: .system)
        captureButton.setTitle("Capture (high-res depth)", for: .normal)
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
        statusLabel.textColor = .white
        statusLabel.text = "Tap Capture to sample mesh near this point."
    }

    @objc private func captureTapped() {
        guard scanFramesRemaining == 0 else { return }

        guard let point = lastTapScreenPoint else {
            statusLabel.text = "Tap on the foot in the AR view first."
            return
        }

        // Prefer the scene mesh (cheap, already in world space). The mesh is often missing —
        // ARKit has not built it yet, or the foot is too close to mesh — so fall back to a
        // depth-backed ARKit raycast through the same screen point.
        var hitPoint: SIMD3<Float>?
        if let ray = arView.ray(through: point) {
            hitPoint = closestMeshPoint(toRayOrigin: ray.origin, direction: simd_normalize(ray.direction))
        }
        if hitPoint == nil {
            hitPoint = depthRaycastPoint(at: point)
        }
        guard let hit = hitPoint else {
            showProblem("Couldn't find a surface there. Move the phone slowly over the foot and floor for a second, then tap the foot and Capture again.")
            return
        }

        scanCenter = hit
        resetScanAccumulation()
        scanFramesRemaining = scanFrameCount
        lastDepthSampleCount = 0
        captureButton.isEnabled = false
        arView.debugOptions.remove(.showSceneUnderstanding)
        for e in meshAnchorEntities.values {
            e.isEnabled = false
        }
        statusLabel.textColor = .white
        statusLabel.text = "Hold still — fusing LiDAR depth (10 frames)…"
    }

    /// World point under a screen point from ARKit's raycast (LiDAR depth backed), nearest first.
    private func depthRaycastPoint(at point: CGPoint) -> SIMD3<Float>? {
        guard let query = arView.makeRaycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
              let first = arView.session.raycast(query).first else { return nil }
        let t = first.worldTransform.columns.3
        return SIMD3<Float>(t.x, t.y, t.z)
    }

    /// Recoverable problem: say it inside the scanner so the user can retry straight away.
    /// (An alert on the parent screen only appears after the scanner is closed.)
    private func showProblem(_ message: String) {
        statusLabel.textColor = .systemYellow
        statusLabel.text = message
    }

    private func quantKey(_ p: SIMD3<Float>) -> String {
        "\(Int(p.x * 250))_\(Int(p.y * 250))_\(Int(p.z * 250))"
    }

    /// Adds voxel-deduplicated points tagged with their source frame; returns how many were new.
    @discardableResult
    private func appendScanPoints(_ pts: [SIMD3<Float>], frameIndex: UInt8) -> Int {
        var added = 0
        for p in pts {
            let k = quantKey(p)
            if scanVoxelKeys.insert(k).inserted {
                scanAccumPoints.append(p)
                scanAccumFrame.append(frameIndex)
                added += 1
                if scanAccumPoints.count >= maxScanPoints { break }
            }
        }
        return added
    }

    private func resetScanAccumulation() {
        scanAccumPoints.removeAll(keepingCapacity: false)
        scanAccumFrame.removeAll(keepingCapacity: false)
        scanVoxelKeys.removeAll(keepingCapacity: false)
        scanFrames.removeAll(keepingCapacity: false)
    }

    /// Saves the fused cloud exactly as the engine saw it (accepted or rejected) so the
    /// capture can be replayed offline, then clears the accumulation buffers.
    private func recordScanAndReset(
        frame: ARFrame,
        seed: SIMD2<Float>?,
        result: FootMeasurementGeometry.Result?,
        rejectReason: String?
    ) {
        // ARKit's camera image is landscape; the app is portrait-only.
        let photo = ScanRecorder.jpegData(from: frame.capturedImage, orientation: .right)
        let meta = ScanBundleMeta(
            id: ScanRecorder.newScanID(),
            createdAt: ScanRecorder.timestamp(),
            capturePath: "lidar",
            side: side,
            deviceModel: ScanRecorder.deviceModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: ScanRecorder.appVersion(),
            algorithm: .current,
            verticalAxis: 1,
            seed: seed.map { [$0.x, $0.y] },
            tapCenter: [scanCenter.x, scanCenter.y, scanCenter.z],
            cropRadiusM: scanRadiusMeters,
            framesFused: scanFrames.count,
            pointCount: scanAccumPoints.count,
            frames: scanFrames,
            outcome: result == nil ? "rejected" : "measured",
            rejectReason: rejectReason,
            measurement: result?.measurement,
            isolatedPointCount: result?.isolatedPoints.count,
            hasPhoto: photo != nil
        )
        ScanRecorder.saveInBackground(
            meta: meta,
            points: scanAccumPoints,
            frameIndex: scanAccumFrame,
            photoJPEG: photo,
            completion: onScanRecorded
        )
        resetScanAccumulation()
    }

    private func restoreDebugMeshes() {
        arView.debugOptions.insert(.showSceneUnderstanding)
        for e in meshAnchorEntities.values {
            e.isEnabled = true
        }
    }

    private func removeFootPointCloud() {
        if let a = footPointCloudAnchor {
            arView.scene.removeAnchor(a)
            footPointCloudAnchor = nil
        }
    }

    private func showFootPointCloud(points: [SIMD3<Float>], cameraTransform: simd_float4x4) {
        removeFootPointCloud()
        do {
            let mesh = try FootDepthSampling.meshResource(
                from: points,
                cameraTransform: cameraTransform,
                quadHalfMeters: 0.0025
            )
            let model = ModelEntity(mesh: mesh, materials: [FootDepthSampling.pointCloudMaterial()])
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(model)
            arView.scene.addAnchor(anchor)
            footPointCloudAnchor = anchor
        } catch {
            // Visualization is optional; sizing still uses the same point set.
        }
    }

    private func finishFootScan(frame: ARFrame) {
        captureButton.isEnabled = true

        for anchor in frame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let verts = meshVertexWorldPositions(anchor: meshAnchor)
            for v in verts where simd_distance(v, scanCenter) <= scanRadiusMeters {
                appendScanPoints([v], frameIndex: ScanRecorder.meshFrameIndex)
            }
        }

        lastDepthSampleCount = scanAccumPoints.count

        let seed = SIMD2<Float>(scanCenter.x, scanCenter.z)

        guard scanAccumPoints.count >= 80 else {
            recordScanAndReset(frame: frame, seed: seed, result: nil, rejectReason: "too_few_points")
            restoreDebugMeshes()
            showProblem("Not enough fused points (\(lastDepthSampleCount)). Move closer, hold still, improve light, and try again.")
            return
        }

        // Isolate + measure the foot the user tapped (seed = tap in world X/Z). The engine
        // strips the floor, drops the leg, and keeps the connected foot cluster.
        guard let result = FootMeasurementGeometry.measure(
            points: scanAccumPoints, verticalAxis: 1, seed: seed
        ) else {
            removeFootPointCloud()
            recordScanAndReset(frame: frame, seed: seed, result: nil, rejectReason: "no_lock_on")
            restoreDebugMeshes()
            showProblem("Couldn't lock onto a single foot (\(lastDepthSampleCount) pts). Put the foot flat on the floor, tap right on it, hold still, and try again.")
            return
        }

        // Show ONLY the locked-on foot cluster (green) — visual confirmation of the lock.
        showFootPointCloud(points: result.isolatedPoints, cameraTransform: frame.camera.transform)
        recordScanAndReset(frame: frame, seed: seed, result: result, rejectReason: nil)
        let m = result.measurement
        statusLabel.textColor = .white
        statusLabel.text = String(
            format: "Locked on ✓  %.0f × %.0f mm · arch %.0f mm (%d pts)",
            m.lengthMm, m.ballWidthMm, m.archHeightMm, result.isolatedPoints.count
        )
        onCaptured?(m)
    }

    /// Custom blue mesh visualization (drawn in addition to `.showSceneUnderstanding` wireframe).
    private func upsertBlueMeshEntity(for meshAnchor: ARMeshAnchor) {
        do {
            let meshResource = try Self.meshResource(from: meshAnchor.geometry)
            let mat = Self.sceneMeshMaterial()
            lastMeshBuildError = nil
            if let existing = meshAnchorEntities[meshAnchor.identifier],
               let modelEntity = existing.children.first as? ModelEntity {
                modelEntity.model = ModelComponent(mesh: meshResource, materials: [mat])
            } else {
                let modelEntity = ModelEntity(mesh: meshResource, materials: [mat])
                let anchorEntity = AnchorEntity(anchor: meshAnchor)
                anchorEntity.addChild(modelEntity)
                arView.scene.addAnchor(anchorEntity)
                meshAnchorEntities[meshAnchor.identifier] = anchorEntity
            }
        } catch {
            lastMeshBuildError = String(describing: error)
        }
    }

    /// Builds a `MeshResource` from ARKit geometry (no `MeshResource.generate(from: ARMeshGeometry)` on all SDKs).
    private static func meshResource(from geometry: ARMeshGeometry) throws -> MeshResource {
        do {
            return try meshResource(from: geometry, includeNormals: true)
        } catch {
            return try meshResource(from: geometry, includeNormals: false)
        }
    }

    private static func meshResource(from geometry: ARMeshGeometry, includeNormals: Bool) throws -> MeshResource {
        let positions = readSIMD3Array(from: geometry.vertices)
        let indices = readTriangleIndices(from: geometry.faces)
        guard !positions.isEmpty, !indices.isEmpty, indices.count % 3 == 0 else {
            throw MeshBuildError.invalidBuffers
        }
        var descriptor = MeshDescriptor(name: "sceneMesh")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        if includeNormals {
            let normalsSource = geometry.normals
            if normalsSource.count > 0, normalsSource.count == positions.count {
                descriptor.normals = MeshBuffers.Normals(readSIMD3Array(from: normalsSource))
            }
        }
        return try MeshResource.generate(from: [descriptor])
    }

    private enum MeshBuildError: Error {
        case invalidBuffers
    }

    private static func readSIMD3Array(from source: ARGeometrySource) -> [SIMD3<Float>] {
        let count = source.count
        let stride = source.stride
        let offset = source.offset
        let base = source.buffer.contents()
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let byteOffset = offset + stride * i
            let v = base.advanced(by: byteOffset).assumingMemoryBound(to: SIMD3<Float>.self).pointee
            out.append(v)
        }
        return out
    }

    /// `ARGeometryElement.count` is the number of **primitives** (triangles), not raw index count.
    /// Prefer the subscript API (no `offset` / manual index buffer walk — `offset` was removed from this type).
    private static func readTriangleIndices(from faces: ARGeometryElement) -> [UInt32] {
        let primitiveCount = faces.count
        let indicesPerPrimitive = faces.indexCountPerPrimitive
        var indices: [UInt32] = []
        indices.reserveCapacity(primitiveCount * indicesPerPrimitive)
        for p in 0..<primitiveCount {
            // Subscript returns integer indices; may be UInt16 when `bytesPerIndex == 2`.
            for idx in faces[p] {
                indices.append(UInt32(idx))
            }
        }
        return indices
    }

    private func removeMeshEntity(for meshAnchor: ARMeshAnchor) {
        if let entity = meshAnchorEntities.removeValue(forKey: meshAnchor.identifier) {
            arView.scene.removeAnchor(entity)
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            upsertBlueMeshEntity(for: meshAnchor)
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            upsertBlueMeshEntity(for: meshAnchor)
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            removeMeshEntity(for: meshAnchor)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp

        // Mesh anchors don’t always arrive via `didAdd` before we care; re-sync from the frame periodically.
        if now - lastMeshSyncTime >= 0.2 {
            lastMeshSyncTime = now
            for anchor in frame.anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    upsertBlueMeshEntity(for: meshAnchor)
                }
            }
        }

        if scanFramesRemaining > 0 {
            let depthPts = FootDepthSampling.worldPointsNear(
                frame: frame,
                centerWorld: scanCenter,
                radiusMeters: scanRadiusMeters,
                pixelStride: 2,
                maxPoints: 8000
            )
            let frameIndex = scanFrameCount - scanFramesRemaining
            let added = appendScanPoints(depthPts, frameIndex: UInt8(frameIndex))
            scanFrames.append(ScanBundleMeta.Frame(
                index: frameIndex,
                pointCount: added,
                cameraTransform: ScanRecorder.flatten(frame.camera.transform),
                attitudeQuat: nil
            ))
            scanFramesRemaining -= 1
            if scanFramesRemaining == 0 {
                finishFootScan(frame: frame)
            }
        }

        if now - lastDebugTextUpdate < 0.25 { return }
        lastDebugTextUpdate = now

        if !arView.debugOptions.contains(.showSceneUnderstanding) {
            arView.debugOptions.insert(.showSceneUnderstanding)
        }

        updateTrackingBanner(state: frame.camera.trackingState)

        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }.count
        let tracking = describeTracking(frame.camera.trackingState)
        let light = frame.lightEstimate.map { est in
            String(format: "%.0f lx", est.ambientIntensity)
        } ?? "n/a"

        let lines = """
        t=\(String(format: "%.2f", now)) tracking=\(tracking)
        anchors mesh=\(meshAnchors) total=\(frame.anchors.count)
        blue mesh entities=\(meshAnchorEntities.count)
        depth fuse: framesLeft=\(scanFramesRemaining) accumPts=\(scanAccumPoints.count) lastFused=\(lastDepthSampleCount)
        mesh build err: \(lastMeshBuildError ?? "none")
        light=\(light) interrupted=\(sessionInterrupted)
        session err: \(lastSessionError ?? "none")
        slam_note: internal VIO may log "poor slam" — often harmless; see orange banner if tracking dips.
        """
        DispatchQueue.main.async { [weak self] in
            self?.debugTextView.text = lines
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        updateTrackingBanner(state: camera.trackingState)
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
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        lastSessionError = error.localizedDescription
        appendDebugLine("didFailWithError: \(error.localizedDescription)")
    }

    private func updateTrackingBanner(state: ARCamera.TrackingState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch state {
            case .normal:
                self.trackingWarningLabel.isHidden = true
            case .notAvailable:
                self.trackingWarningLabel.isHidden = false
                self.trackingWarningLabel.text = "AR tracking unavailable. Add light and aim at textured surfaces."
            case .limited(let reason):
                self.trackingWarningLabel.isHidden = false
                self.trackingWarningLabel.text = self.trackingTip(for: reason)
            @unknown default:
                self.trackingWarningLabel.isHidden = true
            }
        }
    }

    private func trackingTip(for reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .excessiveMotion:
            return "Tracking limited (motion): move slowly — fast motion hurts SLAM and mesh updates."
        case .insufficientFeatures:
            return "Tracking limited (visual features): show carpet, grout lines, or clutter — plain floors are hard for AR."
        case .initializing:
            return "AR still initializing — pan the room slowly until this clears."
        case .relocalizing:
            return "Relocalizing map — revisit the same area or walk slowly to recover tracking."
        @unknown default:
            return "Tracking limited — improve lighting and move slowly."
        }
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
            // Use every vertex (no subsampling) so ray–mesh matching uses full ARKit detail.
            for v in verts {
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
    var side: String? = nil
    var onCaptured: (FootSideMeasurement) -> Void
    var onError: (String) -> Void
    var onDismiss: () -> Void
    var onScanRecorded: () -> Void = {}

    func makeUIViewController(context: Context) -> FootScanARViewController {
        let c = FootScanARViewController()
        c.side = side
        c.onScanRecorded = onScanRecorded
        c.onCaptured = { m in
            onCaptured(m)
            // Brief delay so the dense green point cloud is visible before the sheet dismisses.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                onDismiss()
            }
        }
        c.onError = { msg in
            onError(msg)
        }
        return c
    }

    func updateUIViewController(_ uiViewController: FootScanARViewController, context: Context) {}
}
