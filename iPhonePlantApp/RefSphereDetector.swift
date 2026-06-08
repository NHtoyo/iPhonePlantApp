import Foundation
import CoreML
import Vision
import ARKit

class RefSphereDetector {
    static let shared = RefSphereDetector()
    
    private var visionModel: VNCoreMLModel?
    var isModelLoaded = false
    var modelLoadStatusMessage = "⏳ 初期化未完了"
    
    init() {
        loadModel()
    }
    
    /// アプリバンドル内からモデルファイルを動的に探索・ロードする
    func loadModel() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        let modelNames = urls.map { $0.deletingPathExtension().lastPathComponent }
        print("📁 [RefSphereDetector] バンドル内のCoreMLモデル一覧: \(modelNames)")
        
        guard let modelURL = Bundle.main.url(forResource: "yolo_kendama_best", withExtension: "mlmodelc") ??
                             Bundle.main.url(forResource: "yolo26n", withExtension: "mlmodelc") ??
                             Bundle.main.url(forResource: "yolo26n_nms", withExtension: "mlmodelc") ??
                             Bundle.main.url(forResource: "kendama_detector", withExtension: "mlmodelc") ??
                             urls.first else {
            self.modelLoadStatusMessage = "⚠️ モデル(*.mlmodel)未追加 (検出数: \(modelNames.count))"
            print("⚠️ [RefSphereDetector]: \(self.modelLoadStatusMessage)")
            return
        }
        
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let coreMLModel = try MLModel(contentsOf: modelURL, configuration: config)
            self.visionModel = try VNCoreMLModel(for: coreMLModel)
            self.isModelLoaded = true
            self.modelLoadStatusMessage = "✅ ロード成功: \(modelURL.deletingPathExtension().lastPathComponent)"
            print("✅ [RefSphereDetector]: \(self.modelLoadStatusMessage)")
        } catch {
            self.modelLoadStatusMessage = "❌ ロード失敗: \(error.localizedDescription)"
            print("❌ [RefSphereDetector]: \(self.modelLoadStatusMessage)")
        }
    }
    
    /// カメラ画像から基準球オブジェクトを検出する
    /// - Parameters:
    ///   - frame: ARKitのフレーム
    ///   - completion: 検出された矩形、ラベル名、信頼度、および詳細デバッグログ
    func detect(frame: ARFrame, completion: @escaping (CGRect?, String?, Float?, String) -> Void) {
        if !isModelLoaded {
            loadModel()
        }
        
        guard isModelLoaded, let visionModel = self.visionModel else {
            completion(nil, nil, nil, modelLoadStatusMessage)
            return
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .up, options: [:])
        
        let request = VNCoreMLRequest(model: visionModel) { request, error in
            if let err = error {
                completion(nil, nil, nil, "❌ Visionエラー: \(err.localizedDescription)")
                return
            }
            
            guard let results = request.results as? [VNRecognizedObjectObservation] else {
                completion(nil, nil, nil, "🔍 走査中...")
                return
            }
            
            if results.isEmpty {
                completion(nil, nil, nil, "🔍 走査中... (未検出)")
                return
            }
            
            let validObservations = results.filter { observation in
                observation.labels.contains(where: {
                    let id = $0.identifier.lowercased()
                    let confidence = $0.confidence
                    return (id.contains("kendama") || id == "class_0" || id.hasPrefix("class") || id == "0" || results.first?.labels.count == 1) && confidence >= 0.50
                })
            }
            
            if validObservations.isEmpty {
                completion(nil, nil, nil, "🔍 走査中... (未検出)")
                return
            }
            
            if let bestObservation = validObservations.first {
                let box = bestObservation.boundingBox
                let label = "ref_sphere"
                let confidence = bestObservation.labels.first?.confidence ?? 0.0
                let debugLog = String(format: "🎯 基準球ロックオン! (信頼度: %.0f%%)", confidence * 100)
                completion(box, label, confidence, debugLog)
            } else {
                completion(nil, nil, nil, "🔍 走査中... (未検出)")
            }
        }
        
        request.imageCropAndScaleOption = .scaleFill
        
        try? handler.perform([request])
    }
}
