import Foundation
import ARKit
import CoreVideo
import CoreImage
import UniformTypeIdentifiers
import AppleArchive
import System

class DataRecorder {
    static let shared = DataRecorder()
    
    var isRecording = false
    var frameCount = 0
    
    private var sessionDir: URL?
    private var imagesDir: URL?
    private var depthsDir: URL?
    
    private var framesData: [[String: Any]] = []
    
    // CoreImage Context for fast image conversion
    private let ciContext = CIContext(options: nil)
    
    // アップロード用ステータス（ContentViewから参照）
    var uploadStatus: String = ""
    
    var expectsDepth: Bool = false
    
    // ─── 統計用データ ───
    private var totalFrames: Int = 0
    private var limitedTrackingFrames: Int = 0
    private var totalDepthValidPixels: Double = 0
    private var totalPixelsCount: Double = 0
    
    // ─── ブレ・速度検知用 ───
    private var lastTransform: matrix_float4x4?
    private var lastTimestamp: TimeInterval = 0
    private var totalMotionPenalty: Double = 0 // 累積ペナルティ量 (0.0 - totalFrames)
    
    struct QualityReport {
        var score: Int
        var trackingStability: Double // SLAM自体の安定性
        var motionStability: Double   // 手ブレ・速度の安定性
        var depthCoverage: Double     // 深度の網羅率
        var wasDepthExpected: Bool    // 深度モードだったか
        var message: String
    }

    func startRecording(expectsDepth: Bool) -> Bool {
        guard !isRecording else { return false }
        
        // 統計のリセット
        totalFrames = 0
        limitedTrackingFrames = 0
        totalDepthValidPixels = 0
        totalPixelsCount = 0
        lastTransform = nil
        lastTimestamp = 0
        totalMotionPenalty = 0
        
        // Create session directory
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folderName = UploadManager.shared.generateFolderName()
        
        sessionDir = docDir.appendingPathComponent(folderName)
        imagesDir = sessionDir?.appendingPathComponent("images")
        // VIOモードは深度データを記録しないため、depthsDirは作成しない
        depthsDir = expectsDepth ? sessionDir?.appendingPathComponent("depths") : nil
        
        do {
            try FileManager.default.createDirectory(at: sessionDir!, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: imagesDir!, withIntermediateDirectories: true, attributes: nil)
            if expectsDepth, let depthsDir = depthsDir {
                try FileManager.default.createDirectory(at: depthsDir, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            print("Failed to create directories: \(error)")
            return false
        }
        
        frameCount = 0
        framesData = []
        isRecording = true
        self.expectsDepth = expectsDepth
        return true
    }
    
    func stopRecording() -> (URL, QualityReport)? {
        guard isRecording, let sessionDir = sessionDir else { return nil }
        isRecording = false
        
        // Quality Calculation
        let stability = totalFrames > 0 ? 1.0 - (Double(limitedTrackingFrames) / Double(totalFrames)) : 1.0
        let coverage = totalPixelsCount > 0 ? (totalDepthValidPixels / totalPixelsCount) : 0.0
        
        // ─── モーション（手ブレ）評価の刷新 ───
        // 平均ペナルティを算出し、さらに二乗をかけて「悪いものほど壊滅的」にする
        let avgPenalty = totalFrames > 0 ? (totalMotionPenalty / Double(totalFrames)) : 0.0
        // 1.0(最高) - 0.0(最低)。二乗により0.8(少し悪い)は0.64に、0.5(悪い)は0.25にまで落ちる
        let motion = pow(1.0 - avgPenalty, 2)
        
        var score: Int
        if expectsDepth {
            // スコア配分: SLAM(40%) + モーション(40%) + 深度(20%)
            score = Int((stability * 40) + (motion * 40) + (coverage * 20))
        } else {
            // スコア配分: SLAM(50%) + モーション(50%)
            score = Int((stability * 50) + (motion * 50))
        }
        
        var msg = "撮影完了！"
        if stability < 0.8 { msg = "🔴 追跡が不安定です：特徴点が少ないか、動きが速すぎます。" }
        else if motion < 0.6 { msg = "🔴 動きが速すぎます：画像がボケている可能性が非常に高いです。もっとゆっくり動かしてください。" }
        else if motion < 0.85 { msg = "🟡 少し動きが速いです：NeRFの品質を上げるため、さらにゆっくり慎重に動かしてください。" }
        else if coverage < 0.5 && expectsDepth { msg = "🟡 深度データ不足：被写体との距離や明るさを確認してください。" }
        else if score < 60 { msg = "🟡 全体的に品質が低めです。NeRFの生成に失敗する可能性があります。" }
        else { msg = "✅ 非常に良い状態で撮影できました！" }
        
        let report = QualityReport(score: score, trackingStability: stability, motionStability: motion, depthCoverage: coverage, wasDepthExpected: expectsDepth, message: msg)

        // Save transforms.json
        var transforms: [String: Any] = [
            "camera_model": "OPENCV",
            "orientation_override": "none",
            "frames": framesData
        ]
        
        if let firstFrame = framesData.first {
            transforms["fl_x"] = firstFrame["fl_x"]
            transforms["fl_y"] = firstFrame["fl_y"]
            transforms["cx"] = firstFrame["cx"]
            transforms["cy"] = firstFrame["cy"]
            transforms["w"] = firstFrame["w"]
            transforms["h"] = firstFrame["h"]
        }
        
        let jsonURL = sessionDir.appendingPathComponent("transforms.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: transforms, options: .prettyPrinted)
            try data.write(to: jsonURL)
            print("Saved transforms.json to \(jsonURL.path)")
        } catch {
            print("Failed to save transforms.json: \(error)")
        }
        
        // UploadManagerにSAVED_LOCALとして登録
        UploadManager.shared.register(sessionURL: sessionDir)
        
        return (sessionDir, report)
    }
    
    func recordFrame(frame: ARFrame) {
        guard isRecording, let imagesDir = imagesDir else { return }
        
        let frameCountSnapshot = self.frameCount
        self.frameCount += 1
        
        // メインスレッド（ARループ）を止めないよう、画像処理はバックグラウンドで実行
        let pixelBuffer = frame.capturedImage
        let depthSource = frame.sceneDepth ?? frame.smoothedSceneDepth
        let cameraTransform = frame.camera.transform
        let cameraIntrinsics = frame.camera.intrinsics
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let frameName = String(format: "frame_%04d", frameCountSnapshot)
            let imageFileName = "\(frameName).jpg"
            let imageURL = imagesDir.appendingPathComponent(imageFileName)
            
            // 1. RGB Image Saving
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
                let options: [CIImageRepresentationOption: Any] = [
                    CIImageRepresentationOption(rawValue: "kCGImageDestinationLossyCompressionQuality"): 0.9
                ]
                do {
                    try self.ciContext.writeJPEGRepresentation(of: ciImage, to: imageURL, colorSpace: colorSpace, options: options)
                } catch {
                    print("❌ JPEG保存失敗 [\(frameName)]: \(error)")
                }
            }
            
            // 2. Depth Image Saving
            var depthFileName: String? = nil
            if self.expectsDepth, let depthsDir = self.depthsDir {
                if let sceneDepth = depthSource {
                    let depthBuffer = sceneDepth.depthMap
                    depthFileName = "\(frameName).png"
                    let depthURL = depthsDir.appendingPathComponent(depthFileName!)
                    self.saveDepthBufferAs16BitPNG(depthBuffer: depthBuffer, to: depthURL)
                }
            }
            
            // 3. Pose Data (Thread-safe collection)
            let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            let transformArray = [
                [cameraTransform.columns.0.x, cameraTransform.columns.1.x, cameraTransform.columns.2.x, cameraTransform.columns.3.x],
                [cameraTransform.columns.0.y, cameraTransform.columns.1.y, cameraTransform.columns.2.y, cameraTransform.columns.3.y],
                [cameraTransform.columns.0.z, cameraTransform.columns.1.z, cameraTransform.columns.2.z, cameraTransform.columns.3.z],
                [cameraTransform.columns.0.w, cameraTransform.columns.1.w, cameraTransform.columns.2.w, cameraTransform.columns.3.w]
            ]
            
            var frameData: [String: Any] = [
                "file_path": "images/\(imageFileName)",
                "transform_matrix": transformArray,
                "fl_x": cameraIntrinsics[0][0],
                "fl_y": cameraIntrinsics[1][1],
                "cx": cameraIntrinsics[2][0],
                "cy": cameraIntrinsics[2][1],
                "w": Int(imageSize.width),
                "h": Int(imageSize.height)
            ]
            if let df = depthFileName { frameData["depth_file_path"] = "depths/\(df)" }
            
            DispatchQueue.main.async {
                self.framesData.append(frameData)
                if frameCountSnapshot % 10 == 0 {
                    print("📸 Saved frame \(frameCountSnapshot) (Depth: \(depthFileName != nil ? "✅" : "❌"))")
                }
            }
        }
        
        // ─── 統計の更新 ───
        totalFrames += 1
        if case .limited = frame.camera.trackingState {
            limitedTrackingFrames += 1
        }
        
        // 速度・回転のチェック
        let currentTs = frame.timestamp
        let currentTf = frame.camera.transform
        if let lastTf = lastTransform, lastTimestamp > 0 {
            let dt = Float(currentTs - lastTimestamp)
            if dt > 0 {
                let dPos = simd_make_float3(currentTf.columns.3.x - lastTf.columns.3.x,
                                            currentTf.columns.3.y - lastTf.columns.3.y,
                                            currentTf.columns.3.z - lastTf.columns.3.z)
                let speed = simd_length(dPos) / dt
                let qLast = simd_quaternion(lastTf)
                let qCurr = simd_quaternion(currentTf)
                let dRot = simd_angle(simd_mul(simd_inverse(qLast), qCurr))
                let angularSpeed = dRot / dt
                let speedExcess = max(0.0, min(1.0, (speed - 0.5) / (1.5 - 0.5)))
                let angularExcess = max(0.0, min(1.0, (angularSpeed - 0.52) / (1.57 - 0.52)))
                let framePenalty = max(pow(speedExcess, 2), pow(angularExcess, 2))
                totalMotionPenalty += Double(framePenalty)
            }
        }
        lastTransform = currentTf
        lastTimestamp = currentTs
        
        if self.expectsDepth, let depthMap = (frame.sceneDepth ?? frame.smoothedSceneDepth)?.depthMap {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            let w = CVPixelBufferGetWidth(depthMap)
            let h = CVPixelBufferGetHeight(depthMap)
            let base = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self)
            if let ptr = base {
                var validCount = 0
                for i in 0..<(w * h) { if ptr[i] > 0 { validCount += 1 } }
                totalDepthValidPixels += Double(validCount)
                totalPixelsCount += Double(w * h)
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
    }
    
    private func saveDepthBufferAs16BitPNG(depthBuffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
        
        let width  = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)  // パディングを考慮
        let format = CVPixelBufferGetPixelFormatType(depthBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else { return }
        
        // ── Step 1: Float値 → ミリメートル UInt16 ──
        // 結果を格納する連続バッファ（パディングなし）
        var uint16Array = [UInt16](repeating: 0, count: width * height)
        
        if format == kCVPixelFormatType_DepthFloat32 {
            for row in 0..<height {
                let rowPtr = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for col in 0..<width {
                    let m = rowPtr[col]
                    // 異常値 (NaN, Inf, 負数) を0に、最大値を65.5mに制限
                    if m.isNaN || m.isInfinite || m <= 0 {
                        uint16Array[row * width + col] = 0
                    } else {
                        uint16Array[row * width + col] = UInt16(clamping: UInt(min(m * 1000.0, 65535.0)))
                    }
                }
            }
        } else if format == kCVPixelFormatType_DepthFloat16 {
            for row in 0..<height {
                let rowPtr = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float16.self)
                for col in 0..<width {
                    let m = Float(rowPtr[col])
                    if m.isNaN || m.isInfinite || m <= 0 {
                        uint16Array[row * width + col] = 0
                    } else {
                        uint16Array[row * width + col] = UInt16(clamping: UInt(min(m * 1000.0, 65535.0)))
                    }
                }
            }
        } else {
            print("⚠️ Unsupported depth format: \(format)")
            return
        }
        
        // ── Step 2: 診断ログ ──
        let nonZero = uint16Array.filter { $0 > 0 }.count
        let sample = uint16Array.prefix(5).map { $0 }
        print("[DEPTH] 非ゼロピクセル数: \(nonZero)/\(width*height), 先頭5値(mm): \(sample)")
        
        // ── Step 3: CGContext経由でPNG保存（動作実証済み方式） ──
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        
        uint16Array.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 2,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                print("[DEPTH] ❌ CGContext生成失敗")
                return
            }
            print("[DEPTH] ✅ CGContext生成OK")
            guard let cgImage = context.makeImage() else {
                print("[DEPTH] ❌ makeImage失敗")
                return
            }
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else {
                print("[DEPTH] ❌ Destination生成失敗")
                return
            }
            CGImageDestinationAddImage(dest, cgImage, nil)
            let ok = CGImageDestinationFinalize(dest)
            print("[DEPTH] PNG書き込み: \(ok ? "✅ 成功" : "❌ 失敗") → \(url.lastPathComponent)")
        }
    }
}

