import ARKit
import CoreVideo
import RealityKit
import simd
import UIKit

/// Dense samples from **LiDAR scene depth** (`ARFrame.sceneDepth` / `smoothedSceneDepth`).
/// Much higher spatial sampling than `ARMeshAnchor` scene reconstruction (room-scale mesh).
enum FootDepthSampling {

    /// World-space points from the current frame’s depth map within a sphere around `centerWorld`.
    static func worldPointsNear(
        frame: ARFrame,
        centerWorld: SIMD3<Float>,
        radiusMeters: Float,
        pixelStride: Int,
        maxPoints: Int
    ) -> [SIMD3<Float>] {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return [] }
        let depthMap = depthData.depthMap

        let stride = max(1, pixelStride)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let format = CVPixelBufferGetPixelFormatType(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return [] }

        let confMap = depthData.confidenceMap
        var confBuffer: CVPixelBuffer?
        if let cm = confMap,
           CVPixelBufferGetWidth(cm) == width,
           CVPixelBufferGetHeight(cm) == height {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            confBuffer = cm
        }
        defer {
            if let cm = confBuffer {
                CVPixelBufferUnlockBaseAddress(cm, .readOnly)
            }
        }
        let confBPR = confBuffer.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let camera = frame.camera
        let intrin = camera.intrinsics
        let iw = Float(camera.imageResolution.width)
        let ih = Float(camera.imageResolution.height)
        let w = Float(width)
        let h = Float(height)
        let fx = intrin.columns.0.x * (w / iw)
        let fy = intrin.columns.1.y * (h / ih)
        let cx = intrin.columns.2.x * (w / iw)
        let cy = intrin.columns.2.y * (h / ih)

        var out: [SIMD3<Float>] = []
        out.reserveCapacity(min(maxPoints, width * height / max(stride * stride, 1)))

        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                if out.count >= maxPoints { return out }

                if let cm = confBuffer {
                    let coff = y * confBPR + x
                    let cptr = CVPixelBufferGetBaseAddress(cm)!.advanced(by: coff).assumingMemoryBound(to: UInt8.self)
                    if cptr.pointee < 1 { continue }
                }

                guard let d = readDepth(
                    x: x, y: y, base: base, bytesPerRow: bytesPerRow, format: format
                ), d.isFinite, d > 0.04, d < 5.0 else { continue }

                let xf = Float(x)
                let yf = Float(y)
                let xCam = (xf - cx) / fx * d
                let yCam = -(yf - cy) / fy * d
                let world = camera.transform * SIMD4<Float>(xCam, yCam, -d, 1)
                let p = SIMD3<Float>(world.x, world.y, world.z)
                if simd_distance(p, centerWorld) <= radiusMeters {
                    out.append(p)
                }
            }
        }
        return out
    }

    /// Builds a mesh of camera-facing quads (two triangles each) for point-cloud visualization.
    static func meshResource(
        from points: [SIMD3<Float>],
        cameraTransform: simd_float4x4,
        quadHalfMeters: Float
    ) throws -> MeshResource {
        let cap = 12_000
        let pts: [SIMD3<Float>]
        if points.count > cap {
            let step = max(1, points.count / cap)
            var s: [SIMD3<Float>] = []
            s.reserveCapacity(cap)
            var i = 0
            while i < points.count {
                s.append(points[i])
                i += step
            }
            pts = s
        } else {
            pts = points
        }

        guard !pts.isEmpty else {
            throw PointCloudError.empty
        }

        let t = cameraTransform
        let right = simd_normalize(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
        let up = simd_normalize(SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z))
        let h = quadHalfMeters

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(pts.count * 4)
        indices.reserveCapacity(pts.count * 6)

        var vi: UInt32 = 0
        for p in pts {
            let a = p - right * h - up * h
            let b = p + right * h - up * h
            let c = p + right * h + up * h
            let d = p - right * h + up * h
            positions.append(contentsOf: [a, b, c, d])
            indices.append(contentsOf: [vi, vi &+ 1, vi &+ 2, vi, vi &+ 2, vi &+ 3])
            vi += 4
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }

    static func pointCloudMaterial() -> RealityKit.Material {
        var mat = UnlitMaterial()
        mat.color = .init(
            tint: UIColor(red: 0.15, green: 0.95, blue: 0.12, alpha: 0.88),
            texture: nil
        )
        if #available(iOS 18.0, *) {
            mat.faceCulling = .none
        }
        return mat
    }

    private enum PointCloudError: Error {
        case empty
    }

    private static func readDepth(
        x: Int, y: Int, base: UnsafeMutableRawPointer, bytesPerRow: Int, format: OSType
    ) -> Float? {
        switch format {
        case kCVPixelFormatType_DepthFloat32:
            let offset = y * bytesPerRow + x * 4
            let v = base.advanced(by: offset).assumingMemoryBound(to: Float32.self).pointee
            return Float(v)
        case kCVPixelFormatType_DepthFloat16:
            let offset = y * bytesPerRow + x * 2
            let bits = base.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee
            return Float(Float16(bitPattern: bits))
        default:
            return nil
        }
    }
}
