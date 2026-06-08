import Foundation
import ARKit
import RealityKit

/// CoordinateTransform handles the alignment of 2D bounding boxes detected from the camera
/// to real-world 3D coordinates using ARKit and LiDAR depth mapping.
class CoordinateTransform {
    
    /// Calculates the real-world 3D position of an object given its 2D screen coordinate.
    /// This replicates the logic from Android's `convertTo3D` and `applyCoordinateTransform`.
    ///
    /// - Parameters:
    ///   - point2D: The (x,y) point in the image/screen coordinates (e.g., center of bounding box).
    ///   - frame: The current ARFrame containing the sceneDepth and camera transforms.
    ///   - viewSize: The dimensions of the view the user is looking at.
    /// - Returns: A 3D vector representing the world position (x, y, z) in meters.
    static func convertTo3D(point2D: CGPoint, frame: ARFrame, viewSize: CGSize) -> SIMD3<Float>? {
        
        // 1. Get the depth map from the LiDAR sensor
        guard let sceneDepth = frame.sceneDepth else {
            print("Depth map not available. Ensure LiDAR is active.")
            return nil
        }
        
        // 2. Perform coordinate transformation accounting for the 90-degree offset
        // In Android, there's often a 90-degree offset between sensor and screen orientation.
        // In ARKit, `displayTransform` handles mapping from the camera image to the screen view.
        
        let displayTransform = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        
        // Normalize the 2D point (0.0 to 1.0)
        let normalizedPoint = CGPoint(x: point2D.x / viewSize.width, y: point2D.y / viewSize.height)
        
        // Convert screen coordinate to camera image coordinate
        let cameraCoordinate = normalizedPoint.applying(displayTransform.inverted())
        
        // 3. Extract Depth value at the calculated coordinate
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        
        // Map normalized camera coordinate to depth map dimensions
        let depthX = Int(cameraCoordinate.x * CGFloat(depthWidth))
        let depthY = Int(cameraCoordinate.y * CGFloat(depthHeight))
        
        guard depthX >= 0, depthX < depthWidth, depthY >= 0, depthY < depthHeight else {
            return nil
        }
        
        // Read Float32 depth value
        let baseAddress = CVPixelBufferGetBaseAddress(depthMap)!
        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
        let depthInMeters = floatBuffer[depthY * depthWidth + depthX]
        
        if depthInMeters <= 0.0 {
            return nil
        }
        
        // 4. Unproject 2D + depth to 3D Camera coordinates
        // ARCamera intrinsics matrix maps 3D points in camera space to 2D
        // To go backwards: (x_3d, y_3d, z_3d) = (x_2d, y_2d, 1) * depth * inverse(intrinsics)
        let cameraIntrinsics = frame.camera.intrinsics
        let fx = cameraIntrinsics[0][0]
        let fy = cameraIntrinsics[1][1]
        let cx = cameraIntrinsics[2][0]
        let cy = cameraIntrinsics[2][1]
        
        // Camera space 2D point
        let pixelX = Float(cameraCoordinate.x * CGFloat(frame.camera.imageResolution.width))
        let pixelY = Float(cameraCoordinate.y * CGFloat(frame.camera.imageResolution.height))
        
        let localX = (pixelX - cx) * depthInMeters / fx
        let localY = (pixelY - cy) * depthInMeters / fy
        let localZ = -depthInMeters // Z is negative in camera coordinates
        
        let localPosition = SIMD4<Float>(localX, localY, localZ, 1.0)
        
        // 5. Convert Camera coordinates to World coordinates
        // applying the camera view transform offsets any rotational changes.
        let worldPositionMatrix = frame.camera.transform * simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        let worldPosition = worldPositionMatrix * localPosition
        
        return SIMD3<Float>(worldPosition.x, worldPosition.y, worldPosition.z)
    }
}
