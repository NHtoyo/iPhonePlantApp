import SwiftUI
import UIKit
import ARKit
import RealityKit

enum LidarMode: String, CaseIterable {
    case full = "LiDAR オン"
    case slamOnly = "SLAMのみ"
    case off = "LiDAR オフ"
}

struct ARScannerView: UIViewRepresentable {
    @Binding var statusText: String
    @Binding var detectedBoxes: [CGRect]
    @Binding var lidarMode: LidarMode
    /// 録画開始時に世界座標原点をリセットするトリガーフラグ
    @Binding var shouldResetOrigin: Bool
    @Binding var isRefSphereDetectionEnabled: Bool // 「基準球（Reference Sphere）」検出への改名
    
    // ─── 【マルチビュー・スマートキャリブレーション】 ───
    @Binding var isCalibrating: Bool
    @Binding var calibrationProgress: Double
    
    // ─── 【新開発：トマト株の部位別スキャン進捗（0.0 〜 1.0）】 ───
    @Binding var tomatoTopProgress: Double
    @Binding var tomatoMiddleLeftProgress: Double
    @Binding var tomatoMiddleRightProgress: Double
    @Binding var tomatoBottomLeftProgress: Double
    @Binding var tomatoBottomRightProgress: Double
    
    @Binding var isRecording: Bool
    @Binding var isCameraActive: Bool

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        arView.debugOptions = []
        arView.renderOptions = [
            .disablePersonOcclusion,
            .disableDepthOfField,
            .disableMotionBlur,
            .disableCameraGrain,
            .disableFaceMesh,
            .disableGroundingShadows
        ]
        
        // LiDARオクルージョンの有効化
        arView.environment.sceneUnderstanding.options.insert(.occlusion)
        
        context.coordinator.arViewRef = arView
        context.coordinator.setupSession(arView: arView, lidarMode: lidarMode)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        if context.coordinator.currentLidarMode != lidarMode {
            context.coordinator.setupSession(arView: uiView, lidarMode: lidarMode)
        }

        if shouldResetOrigin {
            context.coordinator.resetWorldOrigin()
            DispatchQueue.main.async { self.shouldResetOrigin = false }
        }
        
        context.coordinator.isDetectionEnabled = isRefSphereDetectionEnabled
        
        if context.coordinator.isRecording != isRecording {
            context.coordinator.resetVoxelContactState()
        }
        context.coordinator.isRecording = isRecording
        
        if context.coordinator.isCameraActive != isCameraActive {
            context.coordinator.handleCameraState(isActive: isCameraActive)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, ARSessionDelegate {
        var parent: ARScannerView
        var currentLidarMode: LidarMode? = nil
        weak var arViewRef: ARView?
        
        var isRecording = false
        var isCameraActive = true
        var isDetectionEnabled = false {
            didSet {
                if !isDetectionEnabled {
                    removeRefSphereAnchor()
                }
            }
        }
        
        private var refSphereAnchor: AnchorEntity?
        
        // ─── マルチビュー・スマートキャリブレーション用プロパティ ───
        private var isCalibrating = false
        private var calibrationPoints: [simd_float3] = []
        private var startCameraTransform: simd_float4x4? = nil
        
        // ─── ガイド半円筒（ボクセル高密度）用のプロパティ ───
        private var guideVoxelAnchor: AnchorEntity?
        private var voxelEntities: [ModelEntity] = []
        private var voxelVisited: [Bool] = []
        
        private let voxelCountPerRing = 30 // 半円の中に30個配置（半径50cm化に合わせて密度を同一に維持）
        private let ringOffsets: [Float] = [0.05, -0.05, -0.15, -0.25, -0.35, -0.45, -0.55] // 基準球から50cm下までの範囲（7段）
        private let guideRadius: Float = 0.50 // 半径50cm
        private let activationDistance: Float = 0.08 // 接近判定（8cm）は同一密度のためそのまま維持
        
        private var detectionThrottleCounter = 0
        private var frameThrottleCounter = 0
        
        init(_ parent: ARScannerView) {
            self.parent = parent
        }

        func resetWorldOrigin() {
            guard let session = arViewRef?.session else { return }
            
            if parent.lidarMode != .off {
                session.setWorldOrigin(relativeTransform: matrix_identity_float4x4)
                print("🎯 座標原点をリセット: 録画開始地点を(0,0,0)に設定しました")
            } else {
                print("🎯 VIOモード: セッション開始時点が座標原点です")
            }
        }
        
        func resetVoxelContactState() {
            // 1. 訪問フラグをすべてクリア
            for i in 0..<voxelVisited.count {
                voxelVisited[i] = false
            }
            
            // 2. RealityKit 側のすべてのボクセルマテリアルの色を元の半透明な水色（シアン）にリセット！
            var resetMaterial = SimpleMaterial()
            resetMaterial.color = .init(tint: UIColor.systemCyan.withAlphaComponent(0.65))
            resetMaterial.roughness = 0.2
            resetMaterial.metallic = 0.1
            for entity in voxelEntities {
                entity.model?.materials = [resetMaterial]
            }
            
            // 3. SwiftUI 側の進捗率（植物株の各部位）を 0% に即時リセット！
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.parent.tomatoTopProgress = 0.0
                self.parent.tomatoMiddleLeftProgress = 0.0
                self.parent.tomatoMiddleRightProgress = 0.0
                self.parent.tomatoBottomLeftProgress = 0.0
                self.parent.tomatoBottomRightProgress = 0.0
            }
            
            print("🌱 録画停止に伴い、ボクセルの触れた判定（カバレッジ）をすべてリセットしました。")
        }
        
        func handleCameraState(isActive: Bool) {
            guard self.isCameraActive != isActive else { return }
            self.isCameraActive = isActive
            
            if isActive {
                if let mode = self.currentLidarMode, let arView = self.arViewRef {
                    self.setupSession(arView: arView, lidarMode: mode)
                }
            } else {
                self.arViewRef?.session.pause()
                // カメラOFF時は物体検知などのBoxもクリアする
                DispatchQueue.main.async { [weak self] in
                    self?.parent.detectedBoxes.removeAll()
                }
            }
        }
        
        func setupSession(arView: ARView, lidarMode: LidarMode) {
            self.currentLidarMode = lidarMode
            arView.session.delegate = self
            
            let config = ARWorldTrackingConfiguration()
            config.isAutoFocusEnabled = true
            
            switch lidarMode {
            case .full:
                var semantics: ARWorldTrackingConfiguration.FrameSemantics = []
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                    semantics.insert(.smoothedSceneDepth)
                } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    semantics.insert(.sceneDepth)
                }
                config.frameSemantics = semantics
                
                if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                    config.sceneReconstruction = .mesh
                }
                updateStatus("✅ LiDAR オン - 準備完了")
                
            case .slamOnly:
                config.frameSemantics = []
                if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                    config.sceneReconstruction = []
                }
                updateStatus("✅ SLAMのみ - 準備完了")
                
            case .off:
                config.frameSemantics = []
                if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                    config.sceneReconstruction = []
                }
                updateStatus("✅ LiDAR オフ - 準備完了")
            }
            
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
        
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            if case .notAvailable = frame.camera.trackingState { return }
            
            // 毎フレーム、ガイドボクセルに対するカメラの接近（通過）判定を実行
            if self.isDetectionEnabled && self.guideVoxelAnchor != nil {
                self.checkVoxelCoverage(cameraTransform: frame.camera.transform)
            }
            
            // 1. 基準球リアルタイム検知＆AR空間ガイド処理
            if isDetectionEnabled {
                detectionThrottleCounter += 1
                if detectionThrottleCounter % 2 == 0 {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self = self else { return }
                        
                        RefSphereDetector.shared.detect(frame: frame) { rawBox, label, confidence, debugMessage in
                            DispatchQueue.main.async {
                                guard let arView = self.arViewRef else { return }
                                let viewportSize = arView.bounds.size
                                
                                if let box = rawBox, label != nil, confidence != nil {
                                    // 1. 画面の向きに合わせてアライメント補正
                                    var interfaceOrientation: UIInterfaceOrientation = .portrait
                                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                                        interfaceOrientation = windowScene.interfaceOrientation
                                    }
                                    
                                    let normalizedRect = CGRect(
                                        x: box.origin.x,
                                        y: 1.0 - box.origin.y - box.size.height,
                                        width: box.size.width,
                                        height: box.size.height
                                    )
                                    
                                    let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewportSize)
                                    let displayBox = normalizedRect.applying(displayTransform)
                                    
                                    // 2D枠の描画
                                    self.updateBoxes([displayBox])
                                    
                                    let screenPoint = CGPoint(
                                        x: displayBox.midX * viewportSize.width,
                                        y: displayBox.midY * viewportSize.height
                                    )
                                    
                                    var worldPos: simd_float3? = nil
                                    
                                    // ARKit公式の物理立体メッシュレイキャスト
                                    if let query = arView.makeRaycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .any) ??
                                                   arView.makeRaycastQuery(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .any) {
                                        let raycastResults = arView.session.raycast(query)
                                        if let firstResult = raycastResults.first {
                                            worldPos = simd_make_float3(
                                                firstResult.worldTransform.columns.3.x,
                                                firstResult.worldTransform.columns.3.y,
                                                firstResult.worldTransform.columns.3.z
                                            )
                                        }
                                    }
                                    
                                    if let finalPos = worldPos {
                                        // ─── 【マルチビュー・スマートキャリブレーション処理】 ───
                                        if self.guideVoxelAnchor == nil {
                                            // キャリブレーションがまだ開始されていないなら開始
                                            if !self.isCalibrating {
                                                self.isCalibrating = true
                                                self.startCameraTransform = frame.camera.transform
                                                self.calibrationPoints.removeAll()
                                                self.parent.isCalibrating = true
                                                self.parent.calibrationProgress = 0.0
                                                print("🚀 マルチビュースキャン開始！ startCameraTransform を記録しました。")
                                            }
                                            
                                            // 点群の蓄積
                                            self.calibrationPoints.append(finalPos)
                                            
                                            // カメラの移動量・回転量の算出
                                            if let startTransform = self.startCameraTransform {
                                                let currentTransform = frame.camera.transform
                                                let startPos = simd_make_float3(startTransform.columns.3.x, startTransform.columns.3.y, startTransform.columns.3.z)
                                                let currentPos = simd_make_float3(currentTransform.columns.3.x, currentTransform.columns.3.y, currentTransform.columns.3.z)
                                                let moveDistance = simd_distance(startPos, currentPos)
                                                
                                                let startDir = simd_make_float3(-startTransform.columns.2.x, -startTransform.columns.2.y, -startTransform.columns.2.z)
                                                let currentDir = simd_make_float3(-currentTransform.columns.2.x, -currentTransform.columns.2.y, -currentTransform.columns.2.z)
                                                let angleDiff = acos(max(-1.0, min(1.0, simd_dot(startDir, currentDir)))) // ラジアン
                                                
                                                // 【基準】：移動量12cm、角度変化12度（約0.21ラジアン）で100%達成！
                                                let moveRatio = min(1.0, moveDistance / 0.12)
                                                let angleRatio = min(1.0, angleDiff / 0.21)
                                                let progress = (moveRatio * 0.5) + (angleRatio * 0.5)
                                                
                                                // 進捗が減少（後戻り）するのを防ぐため、常に過去の最大値をキープします！
                                                let maxProgress = max(self.parent.calibrationProgress, Double(progress))
                                                self.parent.calibrationProgress = maxProgress
                                                
                                                // 進捗が100%に達したら、中央値（Median）を計算して完璧な位置にボクセルを固定！
                                                if maxProgress >= 0.99 {
                                                    let accurateMedianPos = self.calculateMedianPoint(self.calibrationPoints)
                                                    self.updateRefSphereAR(at: accurateMedianPos, cameraTransform: currentTransform)
                                                    
                                                    // キャリブレーション状態をクローズ
                                                    self.isCalibrating = false
                                                    self.parent.isCalibrating = false
                                                    self.parent.calibrationProgress = 0.0
                                                }
                                            }
                                        }
                                    }
                                    
                                } else {
                                    self.updateBoxes([])
                                }
                            }
                        }
                    }
                }
            }
            
            // 2. データ記録中
            if DataRecorder.shared.isRecording {
                frameThrottleCounter += 1
                if frameThrottleCounter % 6 != 0 { return }
                
                DataRecorder.shared.recordFrame(frame: frame)
                
                DispatchQueue.main.async {
                    if self.parent.lidarMode == .off {
                        self.parent.statusText = "● 録画中: \(DataRecorder.shared.frameCount)枚 | VIOモード"
                    } else {
                        let hasDepth = frame.sceneDepth != nil || frame.smoothedSceneDepth != nil
                        self.parent.statusText = "● 録画中: \(DataRecorder.shared.frameCount)枚 | 深度: \(hasDepth ? "✅" : "❌")"
                    }
                }
            } else {
                // 録画中でなくトラッキング中であれば、トラッキング状態ログを表示
                DispatchQueue.main.async {
                    if !self.isDetectionEnabled {
                        switch frame.camera.trackingState {
                        case .normal:
                            switch self.parent.lidarMode {
                            case .full:     self.parent.statusText = "✅ LiDAR オン - 準備完了"
                            case .slamOnly: self.parent.statusText = "✅ SLAMのみ - 準備完了"
                            case .off:      self.parent.statusText = "✅ LiDAR オフ - 準備完了"
                            }
                        case .limited(let reason):
                            switch reason {
                            case .initializing:         self.parent.statusText = "⏳ 初期化中... カメラをゆっくり動かしてください"
                            case .excessiveMotion:       self.parent.statusText = "⚠️ 動きすぎ - ゆっくり動かしてください"
                            case .insufficientFeatures:  self.parent.statusText = "⚠️ 特徴点不足 - テクスチャの多い場所へ"
                            case .relocalizing:          self.parent.statusText = "⏳ 再ローカライズ中..."
                            @unknown default:            self.parent.statusText = "⚠️ トラッキング不安定"
                            }
                        case .notAvailable:
                            self.parent.statusText = "❌ トラッキング不可"
                        }
                    }
                }
            }
        }
        
        // 点群からX,Y,Zそれぞれの中央値（Median）を計算して外れ値ノイズを完全消去
        private func calculateMedianPoint(_ points: [simd_float3]) -> simd_float3 {
            guard !points.isEmpty else { return simd_float3(0, 0, 0) }
            
            let xs = points.map { $0.x }.sorted()
            let ys = points.map { $0.y }.sorted()
            let zs = points.map { $0.z }.sorted()
            
            let mid = points.count / 2
            let medianX = points.count % 2 == 0 ? (xs[mid - 1] + xs[mid]) / 2.0 : xs[mid]
            let medianY = points.count % 2 == 0 ? (ys[mid - 1] + ys[mid]) / 2.0 : ys[mid]
            let medianZ = points.count % 2 == 0 ? (zs[mid - 1] + zs[mid]) / 2.0 : zs[mid]
            
            return simd_float3(medianX, medianY, medianZ)
        }
        
        // 基準球用ARガイド半円筒の作成と更新
        private func updateRefSphereAR(at position: simd_float3, cameraTransform: simd_float4x4) {
            guard let arView = arViewRef else { return }
            
            if guideVoxelAnchor != nil {
                return
            }
            
            print("🎯 [ARScannerView]: 基準球を中心に自分側180度シリンダーを空間ロックで生成します")
            
            let anchor = AnchorEntity(world: position)
            self.guideVoxelAnchor = anchor
            
            voxelEntities.removeAll()
            voxelVisited.removeAll()
            
            var cyanMaterial = SimpleMaterial()
            cyanMaterial.color = .init(tint: UIColor.systemCyan.withAlphaComponent(0.65)) // 半透明な水色（シアン）
            cyanMaterial.roughness = 0.2
            cyanMaterial.metallic = 0.1
            
            // ─── 【自分側（カメラ側）180度の半円配置アルゴリズム】 ───
            let cameraPos = simd_make_float3(cameraTransform.columns.3.x,
                                             cameraTransform.columns.3.y,
                                             cameraTransform.columns.3.z)
            let toCamera = cameraPos - position
            let centerAngle = atan2(toCamera.z, toCamera.x) // X-Z平面におけるカメラへの水平角度（ラジアン）
            
            for ringOffset in ringOffsets {
                for i in 0..<voxelCountPerRing {
                    let angleFraction = Float(i) / Float(voxelCountPerRing - 1)
                    let angle = (centerAngle - .pi / 2.0) + angleFraction * .pi
                    
                    let localX = guideRadius * cos(angle)
                    let localY = ringOffset
                    let localZ = guideRadius * sin(angle)
                    
                    let boxMesh = MeshResource.generateBox(size: 0.02)
                    let modelEntity = ModelEntity(mesh: boxMesh, materials: [cyanMaterial])
                    modelEntity.position = [localX, localY, localZ]
                    
                    anchor.addChild(modelEntity)
                    voxelEntities.append(modelEntity)
                    voxelVisited.append(false)
                }
            }
            
            // 中心位置を示す未来的に輝く小さな青い球体
            let centerMesh = MeshResource.generateSphere(radius: 0.01) // 1.0cmにスリム化
            var centerMaterial = SimpleMaterial()
            centerMaterial.color = .init(tint: UIColor.cyan)
            centerMaterial.roughness = 0.05
            centerMaterial.metallic = 0.9 // 金属光沢を高めてロックオンコアを表現
            
            let centerEntity = ModelEntity(mesh: centerMesh, materials: [centerMaterial])
            anchor.addChild(centerEntity)
            
            arView.scene.addAnchor(anchor)
            
            let notificationGenerator = UINotificationFeedbackGenerator()
            notificationGenerator.notificationOccurred(.success)
        }
        
        // 毎フレームカメラの位置と各ボクセルの距離をチェックし、カバレッジを更新する
        private func checkVoxelCoverage(cameraTransform: simd_float4x4) {
            guard guideVoxelAnchor != nil else { return }
            
            let cameraPos = simd_make_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            
            for i in 0..<voxelEntities.count {
                if voxelVisited[i] { continue }
                
                let voxelWorldPos = voxelEntities[i].position(relativeTo: nil)
                let distance = simd_distance(cameraPos, voxelWorldPos)
                
                if distance < activationDistance {
                    voxelVisited[i] = true
                    
                    var greenMaterial = SimpleMaterial()
                    greenMaterial.color = .init(tint: UIColor.green.withAlphaComponent(0.65)) // 水色と同じ不透明度0.65に変更！
                    greenMaterial.roughness = 0.2
                    greenMaterial.metallic = 0.1
                    
                    voxelEntities[i].model = ModelComponent(mesh: voxelEntities[i].model!.mesh, materials: [greenMaterial])
                    
                    let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
                    feedbackGenerator.impactOccurred()
                }
            }
            
            // ─── 【新開発：トマト株の部位別カバレッジ計算（減少せず、常に最新を安全にSwiftUIにBinding）】 ───
            var topTotal = 0, topVisited = 0
            var midLeftTotal = 0, midLeftVisited = 0
            var midRightTotal = 0, midRightVisited = 0
            var botLeftTotal = 0, botLeftVisited = 0
            var botRightTotal = 0, botRightVisited = 0
            
            for i in 0..<voxelEntities.count {
                let r = i / voxelCountPerRing
                let c = i % voxelCountPerRing
                let isVis = voxelVisited[i]
                
                if r == 0 || r == 1 {
                    // Top (上段2段)
                    topTotal += 1
                    if isVis { topVisited += 1 }
                } else if r >= 2 && r <= 4 {
                    // Middle (中段3段)
                    if c < 15 {
                        midLeftTotal += 1
                        if isVis { midLeftVisited += 1 }
                    } else {
                        midRightTotal += 1
                        if isVis { midRightVisited += 1 }
                    }
                } else {
                    // Bottom (下段2段)
                    if c < 15 {
                        botLeftTotal += 1
                        if isVis { botLeftVisited += 1 }
                    } else {
                        botRightTotal += 1
                        if isVis { botRightVisited += 1 }
                    }
                }
            }
            
            let topP = topTotal > 0 ? Double(topVisited) / Double(topTotal) : 0.0
            let midLP = midLeftTotal > 0 ? Double(midLeftVisited) / Double(midLeftTotal) : 0.0
            let midRP = midRightTotal > 0 ? Double(midRightVisited) / Double(midRightTotal) : 0.0
            let botLP = botLeftTotal > 0 ? Double(botLeftVisited) / Double(botLeftTotal) : 0.0
            let botRP = botRightTotal > 0 ? Double(botRightVisited) / Double(botRightTotal) : 0.0
            
            DispatchQueue.main.async {
                self.parent.tomatoTopProgress = topP
                self.parent.tomatoMiddleLeftProgress = midLP
                self.parent.tomatoMiddleRightProgress = midRP
                self.parent.tomatoBottomLeftProgress = botLP
                self.parent.tomatoBottomRightProgress = botRP
            }
        }
        
        private func removeRefSphereAnchor() {
            if let anchor = guideVoxelAnchor {
                arViewRef?.scene.removeAnchor(anchor)
                self.guideVoxelAnchor = nil
                voxelEntities.removeAll()
                voxelVisited.removeAll()
                print("🎯 [ARScannerView]: ガイドボクセル半円筒をシーンから削除しました")
            }
            if let anchor = refSphereAnchor {
                arViewRef?.scene.removeAnchor(anchor)
                self.refSphereAnchor = nil
            }
            
            // キャリブレーション情報も完全クリアして初期状態へリセット
            self.isCalibrating = false
            self.calibrationPoints.removeAll()
            self.startCameraTransform = nil
            DispatchQueue.main.async {
                self.parent.isCalibrating = false
                self.parent.calibrationProgress = 0.0
                // トマトの進捗も完全に0にリセット
                self.parent.tomatoTopProgress = 0.0
                self.parent.tomatoMiddleLeftProgress = 0.0
                self.parent.tomatoMiddleRightProgress = 0.0
                self.parent.tomatoBottomLeftProgress = 0.0
                self.parent.tomatoBottomRightProgress = 0.0
            }
            
            updateBoxes([])
        }
        
        private func updateBoxes(_ boxes: [CGRect]) {
            DispatchQueue.main.async {
                self.parent.detectedBoxes = boxes
            }
        }
        
        private func updateStatus(_ text: String) {
            DispatchQueue.main.async {
                self.parent.statusText = text
            }
        }
    }
}
