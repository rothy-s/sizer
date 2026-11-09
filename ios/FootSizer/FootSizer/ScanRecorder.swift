import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd

/// Everything needed to replay one capture offline, written next to the raw points.
///
/// Encoded as snake_case JSON (`meta.json`). The Python reader lives in
/// `server/scanlab/bundle.py` — keep the two in sync, and bump `schemaVersion` on any
/// change that an old reader would misinterpret.
struct ScanBundleMeta: Codable, Equatable {
    struct Algorithm: Codable, Equatable {
        var version: String
        var floorBandMm: Double
        var legCapMm: Double
        var tipCorrectionMm: Double

        /// The constants the on-device engine ran with for this capture.
        static var current: Algorithm {
            Algorithm(
                version: "1",
                floorBandMm: FootMeasurementGeometry.floorBandMm,
                legCapMm: FootMeasurementGeometry.legCapMm,
                tipCorrectionMm: FootMeasurementGeometry.tipCorrectionMm
            )
        }
    }

    /// One fused depth frame. LiDAR frames carry the ARKit camera transform (16 floats,
    /// column-major); TrueDepth frames carry the CoreMotion attitude quaternion (x, y, z, w)
    /// that rotated camera points into the gravity-aligned reference frame.
    struct Frame: Codable, Equatable {
        var index: Int
        var pointCount: Int
        var cameraTransform: [Float]?
        var attitudeQuat: [Float]?
    }

    /// Filled in later (ruler / Brannock), never by the scanner.
    struct GroundTruth: Codable, Equatable {
        var lengthMm: Double?
        var ballWidthMm: Double?
        var source: String?
    }

    var schemaVersion: Int = 1
    var id: String
    var createdAt: String
    /// "lidar" or "truedepth".
    var capturePath: String
    /// "left" / "right" when the caller knows which foot was being scanned.
    var side: String?
    var deviceModel: String
    var osVersion: String
    var appVersion: String
    var algorithm: Algorithm
    /// Index of the vertical axis in `points.f32` (1 = ARKit Y, 2 = CoreMotion Z).
    var verticalAxis: Int
    /// Horizontal tap seed exactly as passed to the engine (nil = "largest cluster").
    var seed: [Float]?
    /// Centre of the crop sphere, in the same frame as the points (LiDAR only).
    var tapCenter: [Float]?
    var cropRadiusM: Float
    var framesFused: Int
    var pointCount: Int
    var frames: [Frame]
    /// "measured" or "rejected".
    var outcome: String
    var rejectReason: String?
    var measurement: FootSideMeasurement?
    var isolatedPointCount: Int?
    var hasPhoto: Bool
    var groundTruth: GroundTruth?
    var looksLikeFoot: Bool?
    var notes: String?
}

/// Saves every capture — accepted or rejected — as a replayable bundle under
/// `Documents/Scans/<id>/`:
///
///   * `meta.json`       — `ScanBundleMeta`
///   * `points.f32`      — little-endian float32 x,y,z triples: the exact engine input
///   * `frame_index.u8`  — per point, the fused frame it came from (255 = scene-mesh vertex)
///   * `photo.jpg`       — what the camera saw (optional)
///
/// `Documents` is exposed to the Files app / Finder (see Info.plist), so bundles can be
/// pulled off the phone and replayed with `python -m scanlab.replay`.
enum ScanRecorder {
    /// `frame_index.u8` value for points that came from the ARKit scene mesh, not a depth frame.
    static let meshFrameIndex: UInt8 = 255

    static var scansDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Scans", isDirectory: true)
    }

    private static let ioQueue = DispatchQueue(label: "footsizer.scan-recorder", qos: .utility)
    private static let ciContext = CIContext()

    // MARK: - Building metadata

    static func newScanID(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "scan-\(f.string(from: now))-\(suffix)"
    }

    static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Hardware identifier, e.g. "iPhone16,1" (the Simulator reports the host architecture).
    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    // MARK: - Writing

    /// Writes a bundle synchronously and returns its directory.
    @discardableResult
    static func save(
        meta: ScanBundleMeta,
        points: [SIMD3<Float>],
        frameIndex: [UInt8],
        photoJPEG: Data?,
        in root: URL = scansDirectory
    ) throws -> URL {
        let dir = root.appendingPathComponent(meta.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // SIMD3<Float> is padded to 16 bytes, so pack tight x,y,z triples by hand.
        var flat = [Float](repeating: 0, count: points.count * 3)
        for (i, p) in points.enumerated() {
            flat[i * 3] = p.x
            flat[i * 3 + 1] = p.y
            flat[i * 3 + 2] = p.z
        }
        let pointData = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        try pointData.write(to: dir.appendingPathComponent("points.f32"), options: .atomic)
        try Data(frameIndex).write(to: dir.appendingPathComponent("frame_index.u8"), options: .atomic)
        if let photoJPEG {
            try photoJPEG.write(to: dir.appendingPathComponent("photo.jpg"), options: .atomic)
        }

        // meta.json goes last: a bundle without it is an incomplete write and is ignored.
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        return dir
    }

    /// Fire-and-forget save off the main thread. Recording must never break a capture, so
    /// failures are only logged.
    static func saveInBackground(
        meta: ScanBundleMeta,
        points: [SIMD3<Float>],
        frameIndex: [UInt8],
        photoJPEG: Data?,
        completion: (() -> Void)? = nil
    ) {
        ioQueue.async {
            do {
                let dir = try save(meta: meta, points: points, frameIndex: frameIndex, photoJPEG: photoJPEG)
                print("ScanRecorder: saved \(dir.lastPathComponent) (\(points.count) pts, \(meta.outcome))")
            } catch {
                print("ScanRecorder: save failed — \(error)")
            }
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    // MARK: - Listing / housekeeping

    /// Complete bundles (those with a `meta.json`), oldest first.
    static func bundleDirectories(in root: URL = scansDirectory) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func deleteAll(in root: URL = scansDirectory) {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Photo

    /// JPEG of a camera frame, downscaled so the longest side is at most `maxDimension`.
    static func jpegData(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        maxDimension: CGFloat = 1280
    ) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxDimension, longest > 0 {
            let s = maxDimension / longest
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        )
    }
}
