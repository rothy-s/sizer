import XCTest
import simd
@testable import FootSizer

/// Tiny deterministic LCG so synthetic feet are reproducible across runs (mirrors the
/// Python reference test's `random.Random(seed)`).
private struct LCG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next01() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next01() }
}

/// Parametric foot with KNOWN dimensions on a noisy floor, rotated by `yawDeg` about vertical.
/// `up` selects the vertical axis (1 = ARKit Y, 2 = CoreMotion Z). Mirrors `make_foot` in
/// `server/tests/foot_geometry_reference.py` so Swift and Python validate the same way.
private func makeFoot(lengthMm: Double, ballWidthMm: Double, instepMm: Double,
                      yawDeg: Double, up: Int, seed: UInt64 = 7) -> [SIMD3<Float>] {
    let outline: [(Double, Double)] = [(0.00, 0.50), (0.12, 0.62), (0.30, 0.55),
                                       (0.50, 0.62), (0.72, 1.00), (0.85, 0.92), (1.00, 0.34)]
    func halfWidthFrac(_ t: Double) -> Double {
        for i in 0..<(outline.count - 1) {
            let (t0, w0) = outline[i], (t1, w1) = outline[i + 1]
            if t >= t0 && t <= t1 {
                let f = (t - t0) / (t1 - t0)
                return (w0 + f * (w1 - w0)) * 0.5
            }
        }
        return 0.18
    }
    let L = lengthMm / 1000.0, Wb = ballWidthMm / 1000.0, Ih = instepMm / 1000.0
    let horiz = [0, 1, 2].filter { $0 != up }
    let a0 = horiz[0], a1 = horiz[1]
    let c = cos(yawDeg * .pi / 180), s = sin(yawDeg * .pi / 180)
    var rng = LCG(seed)
    var pts: [SIMD3<Float>] = []

    func place(_ la: Double, _ wa: Double, _ h: Double) -> SIMD3<Float> {
        var p = SIMD3<Float>(0, 0, 0)
        p[a0] = Float((la * c - wa * s) + rng.uniform(-1.5, 1.5) / 1000.0)
        p[a1] = Float((la * s + wa * c) + rng.uniform(-1.5, 1.5) / 1000.0)
        p[up] = Float(h + rng.uniform(-1.5, 1.5) / 1000.0)
        return p
    }

    for _ in 0..<4000 {
        let t = rng.next01()
        let hw = halfWidthFrac(t) * Wb
        let w = rng.uniform(-hw, hw)
        let la = t * L - L / 2.0
        let dome = pow(sin(.pi * min(1.0, max(0.0, t))), 0.7)
        let top = Ih * dome
        let h = top > 0.005 ? rng.uniform(0, top) : rng.uniform(0, 0.01)
        pts.append(place(la, w, h))
    }
    for _ in 0..<3000 {
        pts.append(place(rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5), rng.uniform(-0.004, 0.010)))
    }
    return pts
}

final class FootMeasurementGeometryTests: XCTestCase {
    func testRecoversKnownDimensionsAcrossSizesAndRotations() {
        let cases: [(Double, Double, Double)] = [
            (280, 100, 68), (250, 95, 60), (300, 110, 72), (235, 88, 55),
        ]
        for (L, W, I) in cases {
            for yaw in [0.0, 20, 45, 75] {
                let pts = makeFoot(lengthMm: L, ballWidthMm: W, instepMm: I, yawDeg: yaw, up: 1)
                guard let m = FootMeasurementGeometry.mondoBallFromXZPoints(pts) else {
                    XCTFail("no foot at L=\(L) yaw=\(yaw)"); continue
                }
                XCTAssertEqual(m.lengthMm, L, accuracy: 14, "length L=\(L) yaw=\(yaw)")
                XCTAssertEqual(m.ballWidthMm, W, accuracy: 7, "width L=\(L) yaw=\(yaw)")
                XCTAssertGreaterThan(m.archHeightMm, 20, "arch should be measured")
            }
        }
    }

    /// The old AABB inflated length badly when a foot sat at an angle; PCA length must be stable.
    func testRotationInvarianceLengthStable() {
        var lengths: [Double] = []
        for yaw in [0.0, 15, 30, 45, 60, 75, 90] {
            let pts = makeFoot(lengthMm: 280, ballWidthMm: 100, instepMm: 68, yawDeg: yaw, up: 1)
            guard let m = FootMeasurementGeometry.mondoBallFromXZPoints(pts) else {
                XCTFail("no foot at yaw=\(yaw)"); continue
            }
            lengths.append(m.lengthMm)
        }
        let spread = (lengths.max() ?? 0) - (lengths.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 16, "length spread across yaw: \(lengths)")
    }

    func testReferenceHorizontalXYAxis() {
        let pts = makeFoot(lengthMm: 270, ballWidthMm: 100, instepMm: 64, yawDeg: 30, up: 2)
        guard let m = FootMeasurementGeometry.mondoBallFromReferenceHorizontalXY(pts) else {
            XCTFail("expected measurement"); return
        }
        XCTAssertEqual(m.lengthMm, 270, accuracy: 14)
        XCTAssertEqual(m.ballWidthMm, 100, accuracy: 7)
    }

    func testTooFewPointsRejected() {
        let pts: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.1, 0.05, 0.1)]
        XCTAssertNil(FootMeasurementGeometry.mondoBallFromXZPoints(pts))
    }

    func testFloorOnlyRejected() {
        var rng = LCG(1)
        var pts: [SIMD3<Float>] = []
        for _ in 0..<3000 {
            pts.append(SIMD3<Float>(Float(rng.uniform(-0.3, 0.3)),
                                    Float(rng.uniform(-0.004, 0.01)),
                                    Float(rng.uniform(-0.3, 0.3))))
        }
        XCTAssertNil(FootMeasurementGeometry.mondoBallFromXZPoints(pts))
    }
}

final class FootSizingLocalTests: XCTestCase {
    func testMondopointRoundsToFiveMillimeters() {
        XCTAssertEqual(FootSizingLocal.mondopoint(lengthMm: 268.0), 270)
        XCTAssertEqual(FootSizingLocal.mondopoint(lengthMm: 262.0), 260)
    }

    func testApproximateUsMensInterpolates() {
        let a = FootSizingLocal.approximateUsMens(lengthMm: 255.0)
        let b = FootSizingLocal.approximateUsMens(lengthMm: 270.0)
        XCTAssertGreaterThan(b, a)
    }
}

final class MeasurementModelsTests: XCTestCase {
    func testMeasurementCreateEncodesSnakeCaseKeys() throws {
        let req = MeasurementCreateRequest(
            gender: "mens",
            deviceId: "unit-test",
            left: FootSideMeasurement(lengthMm: 270, ballWidthMm: 100),
            right: FootSideMeasurement(lengthMm: 268, ballWidthMm: 99)
        )
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let data = try enc.encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["gender"] as? String, "mens")
        XCTAssertEqual(obj["device_id"] as? String, "unit-test")
        let left = obj["left"] as! [String: Any]
        XCTAssertEqual(left["length_mm"] as? Double, 270)
        XCTAssertEqual(left["ball_width_mm"] as? Double, 100)
    }

    func testMeasurementResponseDecodesFromSnakeCaseJSON() throws {
        let json = """
        {"id":"abc","gender":"mens","left_mondo_mm":270,"left_us_approx":10.0,"left_width_code":"standard",
        "right_mondo_mm":270,"right_us_approx":9.8,"right_width_code":"standard"}
        """
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let r = try dec.decode(MeasurementResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.id, "abc")
        XCTAssertEqual(r.leftMondoMm, 270)
        XCTAssertEqual(r.leftWidthCode, "standard")
    }
}

/// The on-disk layout is a contract with the Python reader (`server/scanlab/bundle.py`,
/// checked against the same literal bytes in `server/tests/test_scanlab.py`).
final class ScanRecorderTests: XCTestCase {
    private func makeMeta(id: String) -> ScanBundleMeta {
        ScanBundleMeta(
            id: id,
            createdAt: "2026-11-09T00:00:00Z",
            capturePath: "lidar",
            side: "left",
            deviceModel: "iPhone16,1",
            osVersion: "test",
            appVersion: "1.0 (1)",
            algorithm: .current,
            verticalAxis: 1,
            seed: [0.5, -0.25],
            tapCenter: [0.5, 0, -0.25],
            cropRadiusM: 0.22,
            framesFused: 1,
            pointCount: 2,
            frames: [ScanBundleMeta.Frame(
                index: 0, pointCount: 2,
                cameraTransform: ScanRecorder.flatten(matrix_identity_float4x4),
                attitudeQuat: nil
            )],
            outcome: "measured",
            rejectReason: nil,
            measurement: FootSideMeasurement(lengthMm: 270, ballWidthMm: 100, archHeightMm: 60),
            isolatedPointCount: 2,
            hasPhoto: false
        )
    }

    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scans-\(UUID().uuidString)")
    }

    func testWritesTightLittleEndianPointsAndSnakeCaseMeta() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let points: [SIMD3<Float>] = [SIMD3<Float>(1, 2, 3), SIMD3<Float>(-0.5, 0, 0.25)]
        let dir = try ScanRecorder.save(
            meta: makeMeta(id: "scan-test"), points: points,
            frameIndex: [0, ScanRecorder.meshFrameIndex], photoJPEG: nil, in: root
        )

        let pointBytes = [UInt8](try Data(contentsOf: dir.appendingPathComponent("points.f32")))
        XCTAssertEqual(pointBytes, [
            0x00, 0x00, 0x80, 0x3F,  0x00, 0x00, 0x00, 0x40,  0x00, 0x00, 0x40, 0x40,   // 1, 2, 3
            0x00, 0x00, 0x00, 0xBF,  0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x80, 0x3E,   // -0.5, 0, 0.25
        ])
        let frameBytes = [UInt8](try Data(contentsOf: dir.appendingPathComponent("frame_index.u8")))
        XCTAssertEqual(frameBytes, [0, 255])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photo.jpg").path))

        let raw = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let obj = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        XCTAssertEqual(obj["schema_version"] as? Int, 1)
        XCTAssertEqual(obj["capture_path"] as? String, "lidar")
        XCTAssertEqual(obj["vertical_axis"] as? Int, 1)
        XCTAssertEqual(obj["point_count"] as? Int, 2)
        XCTAssertEqual(obj["outcome"] as? String, "measured")
        XCTAssertEqual((obj["seed"] as? [Double])?.count, 2)
        XCTAssertNotNil(obj["crop_radius_m"])
        let measurement = obj["measurement"] as! [String: Any]
        XCTAssertEqual(measurement["length_mm"] as? Double, 270)
        XCTAssertEqual(measurement["ball_width_mm"] as? Double, 100)
        let algorithm = obj["algorithm"] as! [String: Any]
        XCTAssertEqual(algorithm["tip_correction_mm"] as? Double, FootMeasurementGeometry.tipCorrectionMm)
        let frames = obj["frames"] as! [[String: Any]]
        XCTAssertEqual((frames[0]["camera_transform"] as? [Double])?.count, 16)

        // And it round-trips through the same snake_case decoding.
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try dec.decode(ScanBundleMeta.self, from: raw), makeMeta(id: "scan-test"))
    }

    func testListsOnlyCompleteBundlesAndDeletes() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ScanRecorder.bundleDirectories(in: root).isEmpty)

        try ScanRecorder.save(meta: makeMeta(id: "scan-b"), points: [], frameIndex: [], photoJPEG: nil, in: root)
        try ScanRecorder.save(meta: makeMeta(id: "scan-a"), points: [], frameIndex: [], photoJPEG: Data([1, 2]), in: root)
        // A half-written bundle (no meta.json) must be ignored.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scan-partial"), withIntermediateDirectories: true
        )

        XCTAssertEqual(ScanRecorder.bundleDirectories(in: root).map(\.lastPathComponent), ["scan-a", "scan-b"])
        ScanRecorder.deleteAll(in: root)
        XCTAssertTrue(ScanRecorder.bundleDirectories(in: root).isEmpty)
    }
}
