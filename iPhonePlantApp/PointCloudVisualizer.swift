import Foundation
import ARKit
import RealityKit

/// 撮影済み（緑）と未撮影（白）を「点」で出し分けるビジュアライザー
class PointCloudVisualizer {
    private var pointAnchors: [AnchorEntity] = []
    weak var arView: ARView?
    
    var isEnabled: Bool = false {
        didSet { if !isEnabled { clearAll() } }
    }
    
    // 録画中かどうか
    var isRecording: Bool = false
    
    // 負荷軽減のための間引き用
    private var frameCount = 0
    
    init(arView: ARView?) {
        self.arView = arView
    }
    
    /// ARFrameから点群を抽出し、可視化を更新
    func update(with frame: ARFrame) {
        guard isEnabled, let arView = arView else { return }
        
        frameCount += 1
        if frameCount % 10 != 0 { return } // 10フレームに1回処理（負荷対策）
        
        guard let points = frame.rawFeaturePoints else { return }
        
        // 取得した特徴点のうち、直近のいくつかを表示
        let maxPointsThisFrame = isRecording ? 20 : 5 // 録画中は密度を上げる
        let stride = max(1, points.points.count / maxPointsThisFrame)
        
        for i in Swift.stride(from: 0, to: points.points.count, by: stride) {
            let point = points.points[i]
            addPoint(at: point, color: isRecording ? .green : .white.withAlphaComponent(0.5))
        }
        
        // 点が増えすぎないように古いものを制限（疎結合・安全のため）
        if pointAnchors.count > 1000 {
            let removeCount = pointAnchors.count - 1000
            for _ in 0..<removeCount {
                let old = pointAnchors.removeFirst()
                old.removeFromParent()
            }
        }
    }
    
    private func addPoint(at position: simd_float3, color: UIColor) {
        guard let arView = arView else { return }
        
        // 0.01m (1cm) の小さな球体を作成
        let mesh = MeshResource.generateSphere(radius: 0.005)
        let material = UnlitMaterial(color: color)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        
        let anchor = AnchorEntity(world: position)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
        pointAnchors.append(anchor)
    }
    
    func clearAll() {
        for anchor in pointAnchors {
            anchor.removeFromParent()
        }
        pointAnchors.removeAll()
    }
}
