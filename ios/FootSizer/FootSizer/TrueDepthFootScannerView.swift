import AVFoundation
import CoreMotion
import simd
import SwiftUI
import UIKit

/// Front TrueDepth camera: dense depth samples fused over several frames, rotated into a gravity-aligned
/// reference frame (horizontal plane X×Y) for the same Mondopoint / ball-width heuristic as LiDAR.
/// Best results: aim the phone at the foot (mirror clip helps so you can see the screen).
enum FootScanCapabilities {
    /// Depth delivery from the built-in TrueDepth camera (iPhone X+ class devices, not iPad Pro LiDAR back).
    static var supportsTrueDepthDepthDelivery: Bool {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            return false
        }
        return device.formats.contains { (format: AVCaptureDevice.Format) in
            !format.supportedDepthDataFormats.isEmpty
        }
    }
}

// MARK: - Depth → camera space

private enum TrueDepthPointSampling {
    /// Unproject depth map to camera-space points (meters). Camera: X right, Y down, Z forward into scene.
    static func cameraPoints(
        from depthData: AVDepthData,
        nearCenterPixel u0: Int,
        v0: Int,
        radiusPixels: Int,
        pixelStride: Int,
        maxPoints: Int,
        radiusMeters: Float
    ) -> (points: [SIMD3<Float>], anchor: SIMD3<Float>?) {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = converted.depthDataMap
        guard let cal = converted.cameraCalibrationData else {
            return ([], nil)
        }
        let intrin = cal.intrinsicMatrix
        let refW = Float(cal.intrinsicMatrixReferenceDimensions.width)
        let refH = Float(cal.intrinsicMatrixReferenceDimensions.height)

        let w = Float(CVPixelBufferGetWidth(depthMap))
        let h = Float(CVPixelBufferGetHeight(depthMap))

        let fx = intrin.columns.0.x * (w / refW)
        let fy = intrin.columns.1.y * (h / refH)
        let cx = intrin.columns.2.x * (w / refW)
        let cy = intrin.columns.2.y * (h / refH)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            return ([], nil)
        }

        var anchor: SIMD3<Float>?
        if u0 >= 0, u0 < Int(w), v0 >= 0, v0 < Int(h) {
            if let d = readDepth(x: u0, y: v0, base: base, bytesPerRow: bytesPerRow, format: format),
               d > 0.05, d < 5 {
                let xf = Float(u0)
                let yf = Float(v0)
                let xCam = (xf - cx) / fx * d
                let yCam = -(yf - cy) / fy * d
                anchor = SIMD3<Float>(xCam, yCam, d)
            }
        }

        guard let center = anchor else {
            return ([], nil)
        }

        var out: [SIMD3<Float>] = []
        out.reserveCapacity(min(maxPoints, Int(w * h)))

        let r = radiusPixels
        let uMin = max(0, u0 - r)
        let uMax = min(Int(w) - 1, u0 + r)
        let vMin = max(0, v0 - r)
        let vMax = min(Int(h) - 1, v0 + r)

        let stride = max(1, pixelStride)
        for v in Swift.stride(from: vMin, through: vMax, by: stride) {
            for u in Swift.stride(from: uMin, through: uMax, by: stride) {
                if out.count >= maxPoints { return (out, center) }
                guard let d = readDepth(x: u, y: v, base: base, bytesPerRow: bytesPerRow, format: format),
                      d > 0.04, d < 5 else { continue }
                let xf = Float(u)
                let yf = Float(v)
                let xCam = (xf - cx) / fx * d
                let yCam = -(yf - cy) / fy * d
                let p = SIMD3<Float>(xCam, yCam, d)
                if simd_distance(p, center) <= radiusMeters {
                    out.append(p)
                }
            }
        }
        return (out, center)
    }

    private static func readDepth(
        x: Int, y: Int, base: UnsafeMutableRawPointer, bytesPerRow: Int, format: OSType
    ) -> Float? {
        switch format {
        case kCVPixelFormatType_DepthFloat32:
            let offset = y * bytesPerRow + x * 4
            return base.advanced(by: offset).assumingMemoryBound(to: Float32.self).pointee
        case kCVPixelFormatType_DepthFloat16:
            let offset = y * bytesPerRow + x * 2
            let bits = base.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee
            return Float(Float16(bitPattern: bits))
        default:
            return nil
        }
    }
}

// MARK: - Camera → reference (gravity horizontal)

private enum TrueDepthOrientation {
    /// Front camera (portrait): maps common pinhole camera coords (X right, Y down, Z forward) into device axes.
    private static let cameraToDevice = simd_float3x3(
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, 0, -1),
        SIMD3<Float>(0, 1, 0)
    )

    /// `deviceToReference` is the quaternion rotating vectors from **device** to **reference** (CoreMotion `.xArbitraryZVertical`).
    static func referencePoints(cameraPoints: [SIMD3<Float>], deviceToReference: simd_quatf) -> [SIMD3<Float>] {
        let qInv = simd_inverse(deviceToReference)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(cameraPoints.count)
        for pCam in cameraPoints {
            let pDev = simd_mul(cameraToDevice, pCam)
            let pRef = simd_act(qInv, pDev)
            out.append(pRef)
        }
        return out
    }
}

// MARK: - UIKit controller

final class TrueDepthFootScannerViewController: UIViewController, AVCaptureDepthDataOutputDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate {
    var onCaptured: ((FootSideMeasurement) -> Void)?
    var onError: ((String) -> Void)?
    /// "left" / "right" — only used to label the recorded scan bundle.
    var side: String?
    /// Called on the main thread after a scan bundle has been written to disk.
    var onScanRecorded: (() -> Void)?

    private let session = AVCaptureSession()
    private let depthOutput = AVCaptureDepthDataOutput()
    /// Colour frames are kept only so a recorded scan bundle can include a photo.
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "footsizer.truedepth.video", qos: .utility)
    private let latestVideoLock = NSLock()
    private var latestVideoFrame: CVPixelBuffer?
    private let motionManager = CMMotionManager()
    private var latestMotion: CMDeviceMotion?

    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var statusLabel: UILabel!
    private var captureButton: UIButton!

    private var lastTapScreenPoint: CGPoint?
    private var scanFramesRemaining = 0
    private var scanAccumPoints: [SIMD3<Float>] = []
    private var scanVoxelKeys = Set<String>()
    /// Parallel to `scanAccumPoints`: which fused frame each point came from (recorded bundles).
    private var scanAccumFrame: [UInt8] = []
    private var scanFrames: [ScanBundleMeta.Frame] = []
    private let scanFrameCount = 12
    private let scanRadiusMeters: Float = 0.22
    private let maxScanPoints = 40_000
    private var needsCenterPixel = true
    private var centerPixel: (Int, Int)?

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
    private func recordScanAndReset(measurement: FootSideMeasurement?, rejectReason: String?) {
        latestVideoLock.lock()
        let videoFrame = latestVideoFrame
        latestVideoLock.unlock()
        let photo = videoFrame.flatMap { ScanRecorder.jpegData(from: $0, orientation: .up) }

        let meta = ScanBundleMeta(
            id: ScanRecorder.newScanID(),
            createdAt: ScanRecorder.timestamp(),
            capturePath: "truedepth",
            side: side,
            deviceModel: ScanRecorder.deviceModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: ScanRecorder.appVersion(),
            algorithm: .current,
            verticalAxis: 2,
            seed: nil,
            tapCenter: nil,
            cropRadiusM: scanRadiusMeters,
            framesFused: scanFrames.count,
            pointCount: scanAccumPoints.count,
            frames: scanFrames,
            outcome: measurement == nil ? "rejected" : "measured",
            rejectReason: rejectReason,
            measurement: measurement,
            isolatedPointCount: nil,
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

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestVideoLock.lock()
        latestVideoFrame = pixelBuffer
        latestVideoLock.unlock()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard FootScanCapabilities.supportsTrueDepthDepthDelivery else {
            onError?("This device does not support TrueDepth depth capture (use LiDAR scan or manual entry).")
            return
        }

        setupSession()
        guard previewLayer != nil else {
            onError?("Could not start TrueDepth camera.")
            return
        }

        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)

        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.text = "Point the front camera at your foot. Optional: use a mirror to see the screen. Tap the foot, then Capture."
        view.addSubview(statusLabel)

        captureButton = UIButton(type: .system)
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.setTitle("Capture (TrueDepth)", for: .normal)
        captureButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        captureButton.backgroundColor = UIColor.systemGreen
        captureButton.setTitleColor(.white, for: .normal)
        captureButton.layer.cornerRadius = 12
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        view.addSubview(captureButton)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            captureButton.widthAnchor.constraint(equalToConstant: 260),
            captureButton.heightAnchor.constraint(equalToConstant: 48),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(screenTapped(_:)))
        view.addGestureRecognizer(tap)

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue.main) { [weak self] data, _ in
                self?.latestMotion = data
            }
        }

        depthOutput.setDelegate(self, callbackQueue: .main)
        session.startRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            session.commitConfiguration()
            return
        }

        if let format = device.formats.first(where: { !$0.supportedDepthDataFormats.isEmpty }) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
            } catch {}
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            return
        }

        depthOutput.isFilteringEnabled = true
        depthOutput.alwaysDiscardsLateDepthData = false
        if session.canAddOutput(depthOutput) {
            session.addOutput(depthOutput)
        }

        if let connection = depthOutput.connection(with: .depthData) {
            connection.videoOrientation = .portrait
        }

        // Optional colour stream for the recorded-scan photo; the scan works without it.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        if let conn = preview.connection {
            conn.videoOrientation = .portrait
        }
        previewLayer = preview

        session.commitConfiguration()
    }

    @objc private func screenTapped(_ gr: UITapGestureRecognizer) {
        lastTapScreenPoint = gr.location(in: view)
        statusLabel.textColor = .white
        statusLabel.text = "Tap Capture to fuse TrueDepth samples near this point."
    }

    @objc private func captureTapped() {
        guard scanFramesRemaining == 0 else { return }
        guard lastTapScreenPoint != nil else {
            statusLabel.text = "Tap on the foot in the preview first."
            return
        }
        resetScanAccumulation()
        needsCenterPixel = true
        centerPixel = nil
        scanFramesRemaining = scanFrameCount
        captureButton.isEnabled = false
        statusLabel.textColor = .white
        statusLabel.text = "Hold still — fusing TrueDepth depth (12 frames)…"
    }

    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        guard scanFramesRemaining > 0, let previewLayer else { return }

        guard let tap = lastTapScreenPoint else { return }

        let deviceToReference: simd_quatf
        // Recorded per frame; nil means CoreMotion had no attitude and identity was used.
        let recordedAttitude: [Float]?
        if let q = latestMotion?.attitude.quaternion {
            deviceToReference = simd_quatf(
                ix: Float(q.x),
                iy: Float(q.y),
                iz: Float(q.z),
                r: Float(q.w)
            )
            recordedAttitude = [Float(q.x), Float(q.y), Float(q.z), Float(q.w)]
        } else {
            deviceToReference = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            recordedAttitude = nil
        }

        let layerPoint = previewLayer.convert(tap, from: view.layer)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)

        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = converted.depthDataMap
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)

        let u = Int(devicePoint.x * CGFloat(w))
        let v = Int(devicePoint.y * CGFloat(h))

        if needsCenterPixel {
            centerPixel = (max(0, min(w - 1, u)), max(0, min(h - 1, v)))
            needsCenterPixel = false
        }

        guard let (cu, cv) = centerPixel else { return }

        let (camPts, _) = TrueDepthPointSampling.cameraPoints(
            from: converted,
            nearCenterPixel: cu,
            v0: cv,
            radiusPixels: min(w, h) / 4,
            pixelStride: 2,
            maxPoints: 6000,
            radiusMeters: scanRadiusMeters
        )

        let refPts = TrueDepthOrientation.referencePoints(cameraPoints: camPts, deviceToReference: deviceToReference)
        let frameIndex = scanFrameCount - scanFramesRemaining
        let added = appendScanPoints(refPts, frameIndex: UInt8(frameIndex))
        scanFrames.append(ScanBundleMeta.Frame(
            index: frameIndex,
            pointCount: added,
            cameraTransform: nil,
            attitudeQuat: recordedAttitude
        ))

        scanFramesRemaining -= 1
        if scanFramesRemaining == 0 {
            finishScanSuccess()
        }
    }

    private func finishScanError(_ message: String) {
        scanFramesRemaining = 0
        captureButton.isEnabled = true
        showProblem(message)
    }

    /// Recoverable problem: say it inside the scanner so the user can retry straight away.
    /// (An alert on the parent screen only appears after the scanner is closed.)
    private func showProblem(_ message: String) {
        statusLabel.textColor = .systemYellow
        statusLabel.text = message
    }

    private func finishScanSuccess() {
        captureButton.isEnabled = true
        guard let m = FootMeasurementGeometry.mondoBallFromReferenceHorizontalXY(scanAccumPoints) else {
            recordScanAndReset(measurement: nil, rejectReason: "no_lock_on")
            showProblem("Couldn't lock onto a single foot. Improve light, put the foot flat, fill the frame with one foot, and try again.")
            return
        }
        recordScanAndReset(measurement: m, rejectReason: nil)
        statusLabel.textColor = .white
        statusLabel.text = String(format: "Locked on ✓  %.0f × %.0f mm · arch %.0f mm", m.lengthMm, m.ballWidthMm, m.archHeightMm)
        onCaptured?(m)
    }
}

// MARK: - SwiftUI

struct TrueDepthFootScannerSheet: UIViewControllerRepresentable {
    var side: String? = nil
    var onCaptured: (FootSideMeasurement) -> Void
    var onError: (String) -> Void
    var onDismiss: () -> Void
    var onScanRecorded: () -> Void = {}

    func makeUIViewController(context: Context) -> TrueDepthFootScannerViewController {
        let c = TrueDepthFootScannerViewController()
        c.side = side
        c.onScanRecorded = onScanRecorded
        c.onCaptured = { m in
            onCaptured(m)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                onDismiss()
            }
        }
        c.onError = { msg in
            onError(msg)
        }
        return c
    }

    func updateUIViewController(_ uiViewController: TrueDepthFootScannerViewController, context: Context) {}
}
