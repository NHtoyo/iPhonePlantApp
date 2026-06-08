import SwiftUI
import ARKit

struct ContentView: View {
    @State private var statusText: String = "AR初期化中..."
    @State private var detectedBoxes: [CGRect] = []
    @State private var isRecording: Bool = false

    @AppStorage("server_ip") private var serverIP: String = ""
    @State private var uploadMessage: String = ""
    @State private var isUploading: Bool = false

    private let deviceSupportsLidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) || ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    @State private var lidarMode: LidarMode = (ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) || ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)) ? .full : .off
    @State private var shouldResetOrigin: Bool = false
    @State private var isRefSphereDetectionEnabled = false
    
    // トマト株の部位別スキャン進捗
    @State private var tomatoTopProgress: Double = 0.0
    @State private var tomatoMiddleLeftProgress: Double = 0.0
    @State private var tomatoMiddleRightProgress: Double = 0.0
    @State private var tomatoBottomLeftProgress: Double = 0.0
    @State private var tomatoBottomRightProgress: Double = 0.0

    @State private var errorAlertMessage: String = ""
    @State private var showErrorAlert: Bool = false
    @State private var showSideMenu: Bool = false
    @State private var showDeleteAllConfirm = false
    
    // マルチビュー・スマートキャリブレーション用
    @State private var isCalibrating: Bool = false
    @State private var calibrationProgress: Double = 0.0
    
    // 撮影品質レポート用
    @State private var showQualityReport: Bool = false
    @State private var lastQualityReport: DataRecorder.QualityReport? = nil
    
    @State private var uploadStartTime: Date? = nil
    @State private var uploadElapsedSeconds: Int = 0
    private let uploadCancelThresholdSeconds = 5

    @ObservedObject private var uploadManager = UploadManager.shared
    
    // ─── 追加: カメラ電源トグル状態 ───
    @State private var isCameraActive: Bool = true

    var body: some View {
        GeometryReader { geometry in
            let safeAreaTop = geometry.safeAreaInsets.top
            let dynamicTopPadding = max(safeAreaTop, 16.0) // ノッチなし端末でも最小16pxを確保して見やすく！
            
            ZStack {
            ARScannerView(
                statusText: $statusText,
                detectedBoxes: $detectedBoxes,
                lidarMode: $lidarMode,
                shouldResetOrigin: $shouldResetOrigin,
                isRefSphereDetectionEnabled: $isRefSphereDetectionEnabled,
                isCalibrating: $isCalibrating,
                calibrationProgress: $calibrationProgress,
                tomatoTopProgress: $tomatoTopProgress,
                tomatoMiddleLeftProgress: $tomatoMiddleLeftProgress,
                tomatoMiddleRightProgress: $tomatoMiddleRightProgress,
                tomatoBottomLeftProgress: $tomatoBottomLeftProgress,
                tomatoBottomRightProgress: $tomatoBottomRightProgress,
                isRecording: $isRecording,
                isCameraActive: $isCameraActive
            )
            .edgesIgnoringSafeArea(.all)

            BoundingBoxOverlay(boundingBoxes: $detectedBoxes)
                .edgesIgnoringSafeArea(.all)

            // ─── 右上: 基準球検知 ＆ LiDAR切り替え ＆ カメラ電源 ───
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 12) {
                    Spacer()
                    
                    let isLidarActive = deviceSupportsLidar && (lidarMode == .full)
                    VStack(spacing: 4) {
                        Image(systemName: isRefSphereDetectionEnabled ? "target" : "scope")
                            .font(.system(size: 22))
                        Text("基準球検知")
                            .font(.caption2)
                            .fontWeight(.bold)
                    }
                .foregroundColor(isRefSphereDetectionEnabled ? .cyan : .gray)
                .padding(10)
                .background(Color.black.opacity(0.6))
                .cornerRadius(10)
                .contentShape(RoundedRectangle(cornerRadius: 10)) // タップ可能領域をカード全体に設定
                .disabled(isRecording || isUploading || !isLidarActive || !isCameraActive)
                .opacity((isRecording || isUploading) ? 0.5 : (!isLidarActive || !isCameraActive ? 0.3 : 1.0))
                .onTapGesture {
                    guard !isRecording && !isUploading && isLidarActive && isCameraActive else { return }
                    
                    isRefSphereDetectionEnabled.toggle()
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    
                    // 検出OFFにした際は、SwiftUI側のキャリブレーション状態も即時完全リセット！
                    if !isRefSphereDetectionEnabled {
                        isCalibrating = false
                        calibrationProgress = 0.0
                    }
                }
                .onLongPressGesture(minimumDuration: 0.8) {
                    guard !isRecording && !isUploading && isLidarActive && isCameraActive else { return }
                    
                    // 長押しによるリセット＆再スキャン
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.impactOccurred()
                    
                    // 一度OFFにして、アンカーとキャリブレーションを完全消去してからONに戻す
                    isRefSphereDetectionEnabled = false
                    isCalibrating = false
                    calibrationProgress = 0.0
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isRefSphereDetectionEnabled = true
                    }
                }
                
                // LiDARモード切り替えボタン
                Button(action: {
                    switch lidarMode {
                    case .full:     lidarMode = .slamOnly
                    case .slamOnly: lidarMode = .off
                    case .off:      lidarMode = .full
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: lidarMode == .off ? "sensor.tag.radiowaves.forward" : "sensor.tag.radiowaves.forward.fill")
                            .font(.system(size: 22))
                        Text(lidarMode.rawValue)
                            .font(.caption2)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(deviceSupportsLidar ? (lidarMode == .off ? .gray : (lidarMode == .full ? .green : .orange)) : .gray.opacity(0.5))
                    .padding(10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                }
                .disabled(!deviceSupportsLidar || isRecording || isUploading || !isCameraActive)
                .opacity(!isCameraActive ? 0.3 : 1.0)
                .padding(.trailing, 16)
                } // HStackここまで
                
                // カメラ（ARKit）電源切り替えボタン
                Button(action: {
                    isCameraActive.toggle()
                    if !isCameraActive {
                        isRefSphereDetectionEnabled = false
                        isCalibrating = false
                        calibrationProgress = 0.0
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: isCameraActive ? "camera.fill" : "camera.slash.fill")
                            .font(.system(size: 22))
                        Text(isCameraActive ? "カメラ ON" : "スタンバイ")
                            .font(.caption2)
                            .fontWeight(.bold)
                    }
                    .foregroundColor(isCameraActive ? .white : .red)
                    .padding(10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                }
                .disabled(isRecording)
                .opacity(isRecording ? 0.3 : 1.0)
                .padding(.trailing, 16)
            } // VStackここまで
            .padding(.top, dynamicTopPadding - 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .ignoresSafeArea(.all, edges: .top)

            // ─── 左上: メニュー & 送信ボタン ───
            VStack(alignment: .leading, spacing: 12) {
                Button(action: {
                    withAnimation(.spring()) {
                        showSideMenu.toggle()
                    }
                }) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                }
                
                RetryUploadButton(serverIP: serverIP, isUploading: $isUploading, uploadMessage: $uploadMessage, errorAlertMessage: $errorAlertMessage, showErrorAlert: $showErrorAlert, uploadElapsedSeconds: $uploadElapsedSeconds)
            }
            .padding(.top, dynamicTopPadding - 6)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.all, edges: .top)

            // ─── 撮影品質レポート表示 ───
            if showQualityReport, let report = lastQualityReport {
                Color.black.opacity(0.4) // 背景を少し薄く
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { dismissQualityReport() } // 外側タップでも消えるように
                
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 15) {
                            Text("📊 撮影品質レポート").font(.headline).foregroundColor(.white).padding(.top, 10)
                            
                            // スコア
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                                Circle().trim(from: 0, to: CGFloat(report.score) / 100.0)
                                    .stroke(report.score >= 70 ? Color.green : (report.score >= 40 ? Color.orange : Color.red), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                VStack {
                                    Text("\(report.score)").font(.system(size: 28, weight: .black))
                                    Text("SCORE").font(.system(size: 8)).bold()
                                }
                            }
                            .frame(width: 80, height: 80)
                            
                            Text(report.message)
                                .font(.system(size: 13))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .padding(.horizontal)
                            
                            Divider().background(Color.white.opacity(0.2))
                            
                            HStack(spacing: 20) {
                                QualityMetric(
                                    label: report.wasDepthExpected || lidarMode == .slamOnly ? "追跡(SLAM)" : "追跡(VIO)",
                                    value: Int(report.trackingStability * 100),
                                    icon: "waveform.path.ecg"
                                )
                                QualityMetric(label: "動作(手ブレ)", value: Int(report.motionStability * 100), icon: "hand.raised.fill")
                                if report.wasDepthExpected {
                                    QualityMetric(label: "深度", value: Int(report.depthCoverage * 100), icon: "sensor.tag.radiowaves.forward.fill")
                                }
                            }
                            
                            Text("5秒後に自動で閉じます").font(.system(size: 9)).foregroundColor(.gray).padding(.top, 5)
                        }
                        .padding(.vertical, 20)
                        .background(Color(white: 0.15))
                        .cornerRadius(20)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        
                        // 右上の×ボタン
                        Button(action: { dismissQualityReport() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.gray.opacity(0.8))
                                .padding(10)
                        }
                    }
                    .padding(.horizontal, 40)
                }
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                .onAppear {
                    // 5秒後に自動で閉じる
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        if showQualityReport {
                            dismissQualityReport()
                        }
                    }
                }
                .zIndex(2)
            }

            // ─── 送信中ポップアップ ───
            if isUploading || !uploadMessage.isEmpty {
                VStack {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            if isUploading {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            Text(uploadMessage)
                                .font(.subheadline).bold()
                                .foregroundColor(.white)
                        }
                        
                        if isUploading && uploadElapsedSeconds >= uploadCancelThresholdSeconds {
                            Button(action: {
                                UploadManager.shared.cancelCurrentUpload()
                                isUploading = false
                                uploadMessage = "⛔ キャンセルしました"
                                clearMessageAfterDelay()
                            }) {
                                Text("✕ 中断 (\(uploadElapsedSeconds)秒)")
                                    .font(.caption2).bold()
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.red.opacity(0.8))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding()
                    .background(isUploading ? Color.blue.opacity(0.9) : (uploadMessage.contains("✅") ? Color.green.opacity(0.9) : Color.red.opacity(0.9)))
                    .cornerRadius(12)
                    .shadow(radius: 10)
                    .padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut, value: isUploading)
            }

            // ─── 下部: 録画ボタン ───
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    Text(statusText)
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)

                    Button(action: {
                        if isRecording {
                            if let (_, report) = DataRecorder.shared.stopRecording() {
                                isRecording = false
                                lastQualityReport = report
                                withAnimation { showQualityReport = true }
                                
                                if !uploadManager.autoUploadEnabled {
                                    uploadMessage = "✅ 保存完了"
                                    clearMessageAfterDelay()
                                }
                            }
                        } else {
                            uploadMessage = ""
                            shouldResetOrigin = true
                            if DataRecorder.shared.startRecording(expectsDepth: lidarMode == .full) {
                                isRecording = true
                            }
                        }
                    }) {
                        Text(isRecording ? "録画停止" : "データ収集開始 (NeRF用)")
                            .font(.title2).fontWeight(.bold).foregroundColor(.white)
                            .padding().frame(maxWidth: .infinity)
                            .background(isRecording ? Color.red : Color.blue)
                            .cornerRadius(15)
                    }
                    .disabled(isUploading || showQualityReport || !isCameraActive)
                    .opacity(!isCameraActive ? 0.3 : 1.0)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }

            // ─── 【新開発：マルチビュースキャン キャリブレーション UI Overlay】 ───
            if isCalibrating {
                ZStack {
                    // タップ操作を邪魔しないように半透明背景は廃止し、allowsHitTesting(false)ですり抜けさせます！
                    VStack(spacing: 20) {
                        Spacer()
                        
                        // SFチックなスキャナーレティクル ＋ 円形プログレス
                        ZStack {
                            // 背景リング
                            Circle()
                                .stroke(Color.white.opacity(0.15), lineWidth: 4)
                                .frame(width: 140, height: 140)
                            
                            // 進捗円グラフリング（プレミアムネオンブルー＆グリーン）
                            Circle()
                                .trim(from: 0.0, to: CGFloat(calibrationProgress))
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.cyan, .green]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                                )
                                .frame(width: 140, height: 140)
                                .rotationEffect(.degrees(-90))
                                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: calibrationProgress)
                            
                            // 進捗率テキスト
                            VStack(spacing: 2) {
                                Text("\(Int(calibrationProgress * 100))%")
                                    .font(.system(size: 28, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                                
                                Text("SCANNING")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.cyan)
                                    .tracking(1.5)
                            }
                        }
                        .shadow(color: .cyan.opacity(0.4), radius: 10)
                        
                        // ガイドメッセージカード（グラスモーフィズムデザイン）
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.iphone.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.cyan)
                                    .imageScale(.large)
                                
                                Text("3Dスキャン中")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundColor(.white)
                                    .tracking(1.0)
                            }
                            
                            Text("球体を中心にいろいろな方向から\nゆっくりスマホを傾けながら撮影してください")
                                .font(.system(size: 11, weight: .medium))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white.opacity(0.85))
                                .lineSpacing(4)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial) // iOSネイティブの極上ガラスエフェクト
                        .cornerRadius(18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 10)
                        .padding(.bottom, 240) // さらに上に引き上げて視認性を大幅向上！
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(1.5)
                .allowsHitTesting(false) // ◀◀◀ タップ操作を完全に背後のARViewやボタンにスルー！
            }

            // ─── 【新開発：植物株スキャン品質インジケータ（AI生成モノクロ画像 ＋ 動的カラーオーバーレイ）】 ───
            // ─── 【新開発：植物株スキャン品質インジケータ（AI生成モノクロ画像 ＋ 2倍拡大・自己着色マスク・グロウエフェクト）】 ───
            if isRefSphereDetectionEnabled && !isCalibrating && isRecording {
                ZStack {
                    // 1. ベースレイヤー: 薄い半透明ホワイト/グレーの全体線画（拡大サイズ 120x120）
                    if let uiImage = UIImage(named: "AppLogo") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "AppLogo", ofType: "png") ?? "") {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .opacity(0.22) // より上品な薄さにチューニング
                    } else {
                        Image("AppLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .opacity(0.22)
                    }
                    
                    // 2. 魔法の自己着色レイヤー: 元の画像を完璧なマスクにして、裏側の進捗カラー放射グラデーション（ソフトグロウ）を投影！
                    ZStack {
                        // 🟢 Top (上部実 ＆ 枝付近)
                        if tomatoTopProgress > 0 {
                            RadialGradient(
                                gradient: Gradient(colors: [cropColor(for: tomatoTopProgress, isAnyActive: isRecording), .clear]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 28
                            )
                            .frame(width: 56, height: 56)
                            .offset(x: 0, y: -30)
                        }
                        
                        // 🟢 MiddleLeft (中左実 ＆ 枝付近)
                        if tomatoMiddleLeftProgress > 0 {
                            RadialGradient(
                                gradient: Gradient(colors: [cropColor(for: tomatoMiddleLeftProgress, isAnyActive: isRecording), .clear]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 25
                            )
                            .frame(width: 50, height: 50)
                            .offset(x: -36, y: -9)
                        }
                        
                        // 🟢 MiddleRight (中右実 ＆ 枝付近)
                        if tomatoMiddleRightProgress > 0 {
                            RadialGradient(
                                gradient: Gradient(colors: [cropColor(for: tomatoMiddleRightProgress, isAnyActive: isRecording), .clear]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 25
                            )
                            .frame(width: 50, height: 50)
                            .offset(x: 36, y: -9)
                        }
                        
                        // 🟢 BottomLeft (下左実 ＆ 枝付近)
                        if tomatoBottomLeftProgress > 0 {
                            RadialGradient(
                                gradient: Gradient(colors: [cropColor(for: tomatoBottomLeftProgress, isAnyActive: isRecording), .clear]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 25
                            )
                            .frame(width: 50, height: 50)
                            .offset(x: -25, y: 22)
                        }
                        
                        // 🟢 BottomRight (下右実 ＆ 枝付近)
                        if tomatoBottomRightProgress > 0 {
                            RadialGradient(
                                gradient: Gradient(colors: [cropColor(for: tomatoBottomRightProgress, isAnyActive: isRecording), .clear]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 25
                            )
                            .frame(width: 50, height: 50)
                            .offset(x: 25, y: 22)
                        }
                    }
                    .frame(width: 120, height: 120)
                    .mask(
                        Group {
                            if let uiImage = UIImage(named: "AppLogo") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "AppLogo", ofType: "png") ?? "") {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image("AppLogo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            }
                        }
                        .frame(width: 120, height: 120)
                    )
                    
                    // 3. 各部位の進捗率をスタイリッシュに重ねる (白フォントサイズ 8.0 で中央に美しくシャドウ配置)
                    ZStack {
                        if tomatoTopProgress > 0 {
                            Text("\(Int(tomatoTopProgress * 100))")
                                .font(.system(size: 8.0, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.9), radius: 1.5)
                                .offset(x: 0, y: -30)
                        }
                        if tomatoMiddleLeftProgress > 0 {
                            Text("\(Int(tomatoMiddleLeftProgress * 100))")
                                .font(.system(size: 8.0, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.9), radius: 1.5)
                                .offset(x: -36, y: -9)
                        }
                        if tomatoMiddleRightProgress > 0 {
                            Text("\(Int(tomatoMiddleRightProgress * 100))")
                                .font(.system(size: 8.0, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.9), radius: 1.5)
                                .offset(x: 36, y: -9)
                        }
                        if tomatoBottomLeftProgress > 0 {
                            Text("\(Int(tomatoBottomLeftProgress * 100))")
                                .font(.system(size: 8.0, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.9), radius: 1.5)
                                .offset(x: -25, y: 22)
                        }
                        if tomatoBottomRightProgress > 0 {
                            Text("\(Int(tomatoBottomRightProgress * 100))")
                                .font(.system(size: 8.0, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.9), radius: 1.5)
                                .offset(x: 25, y: 22)
                        }
                    }
                }
                .frame(width: 130, height: 130)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.top, dynamicTopPadding - 6) // ◀◀◀ 端末のセーフエリアを越えて完全に吸着！
                .padding(.leading, 84) // ◀◀◀ 左上のメニューボタン(横幅約55px)の右隣の空きスペースにずらし、完璧な被り回避！
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(.all, edges: .top) // ◀◀◀ 画面最上端に強制突入！
                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                .animation(.spring(), value: isRecording)
            }

            // ─── サイドメニュー ───
            if showSideMenu {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        hideKeyboard()
                        withAnimation { showSideMenu = false }
                    }
                
                SideMenuView(isPresented: $showSideMenu, serverIP: $serverIP, showDeleteAllConfirm: $showDeleteAllConfirm)
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
        }
        .alert("送信エラー", isPresented: $showErrorAlert) {
            Button("OK") { showErrorAlert = false }
        } message: {
            Text(errorAlertMessage)
        }
        } // GeometryReader closing brace
    } // ContentView body closing brace

    private func dismissQualityReport() {
        guard showQualityReport else { return }
        withAnimation { showQualityReport = false }
        if uploadManager.autoUploadEnabled {
            if serverIP.isEmpty {
                uploadMessage = "⚠️ IP未設定"
                clearMessageAfterDelay()
            } else {
                startUpload()
            }
        }
    }
    
    private func startUpload() {
        uploadMessage = "🚀 送信中..."
        isUploading = true
        uploadElapsedSeconds = 0
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if !isUploading { timer.invalidate(); return }
            uploadElapsedSeconds += 1
        }
        UploadManager.shared.retryAll(serverIP: serverIP) { completed, total, message in
            if total == 0 || completed == total {
                isUploading = false
                uploadMessage = total == 0 ? "未送信なし" : "✅ 全件送信完了 (\(completed)/\(total))"
                clearMessageAfterDelay()
            } else if message.contains("失敗") || message.contains("エラー") {
                errorAlertMessage = message
                showErrorAlert = true
                isUploading = false
                uploadMessage = "❌ 送信失敗"
                clearMessageAfterDelay()
            } else {
                uploadMessage = message
            }
        }
    }
    
    private func clearMessageAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if !isUploading {
                withAnimation { uploadMessage = "" }
            }
        }
    }
}

// MARK: - サイドメニュー

// SideMenuView は独立したファイルに移動しました。

// MARK: - 補助ビュー

struct QualityMetric: View {
    let label: String
    let value: Int
    let icon: String
    
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption).foregroundColor(.cyan)
                Text(label).font(.caption).foregroundColor(.gray)
            }
            Text("\(value)%")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(value >= 70 ? .green : (value >= 50 ? .orange : .red))
        }
    }
}

struct HistoryItemView: View {
    let session: SessionRecord
    let serverIP: String
    @ObservedObject var uploadManager = UploadManager.shared
    
    @State private var showEditDialog = false
    @State private var showDeleteConfirm = false
    @State private var newName = ""
    
    private var statusIcon: some View {
        switch session.status {
        case .savedLocal: return Text("📁").font(.caption)
        case .uploading:  return Text("⏳").font(.caption)
        case .uploaded:   return Text("✅").font(.caption)
        case .failed:     return Text("❌").font(.caption)
        }
    }
    
    private var statusText: String {
        switch session.status {
        case .savedLocal: return "未送信"
        case .uploading:  return "送信中..."
        case .uploaded:   return "送信済み"
        case .failed:     return "失敗"
        }
    }
    
    private var statusColor: Color {
        switch session.status {
        case .savedLocal: return .gray
        case .uploading:  return .blue
        case .uploaded:   return .green
        case .failed:     return .red
        }
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.id).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.white).lineLimit(1)
                HStack(spacing: 4) {
                    statusIcon
                    Text(statusText).font(.caption2).foregroundColor(statusColor)
                }
            }
            Spacer()
            
            HStack(spacing: 12) {
                if session.status == .savedLocal || session.status == .failed {
                    Button(action: { uploadManager.upload(sessionId: session.id, serverIP: serverIP) { _, _ in } }) {
                        Text(session.status == .failed ? "再試行" : "送信")
                            .font(.caption2).bold().foregroundColor(.blue)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.blue.opacity(0.1)).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3), lineWidth: 1))
                    }
                }
                
                Button(action: { newName = session.id; showEditDialog = true }) {
                    Image(systemName: "ellipsis.circle").font(.caption).foregroundColor(.gray)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
        .alert("データ管理", isPresented: $showEditDialog) {
            TextField("新しい名前", text: $newName)
            Button("名前変更") { uploadManager.renameSession(id: session.id, newName: newName, serverIP: serverIP) }
            Button("強制送信") { uploadManager.upload(sessionId: session.id, serverIP: serverIP) { _, _ in } }
            Button("削除", role: .destructive) { showDeleteConfirm = true }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("このデータの名前変更、送信、または削除を行います。") }
        .alert("データを削除", isPresented: $showDeleteConfirm) {
            Button("削除", role: .destructive) { uploadManager.deleteSession(id: session.id) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この撮影データ（\(session.id)）をiPhoneから完全に削除します。よろしいですか？")
        }
    }
}

struct RetryUploadButton: View {
    let serverIP: String
    @Binding var isUploading: Bool
    @Binding var uploadMessage: String
    @Binding var errorAlertMessage: String
    @Binding var showErrorAlert: Bool
    @Binding var uploadElapsedSeconds: Int // 経過時間を同期
    
    @ObservedObject private var uploadManager = UploadManager.shared

    var body: some View {
        Button(action: { startManualUpload() }) {
            VStack(spacing: 4) {
                Text(uploadManager.autoUploadEnabled ? "自動送信" : "手動送信")
                    .font(.system(size: 7, weight: .black)).padding(.horizontal, 4).padding(.vertical, 2)
                    .background(uploadManager.autoUploadEnabled ? Color.green : Color.gray).foregroundColor(.white).cornerRadius(3)
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.to.line.compact").font(.system(size: 24))
                        .foregroundColor(uploadManager.autoUploadEnabled ? .green : .gray)
                    if uploadManager.pendingCount > 0 {
                        Text("\(uploadManager.pendingCount)").font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white).padding(4).background(Color.red).clipShape(Circle()).offset(x: 6, y: -6)
                    }
                }
                Text("再送").font(.system(size: 9, weight: .bold)).foregroundColor(uploadManager.autoUploadEnabled ? .green : .gray)
            }
            .padding(8).background(Color.black.opacity(0.6)).cornerRadius(10)
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            uploadManager.autoUploadEnabled.toggle()
            let generator = UIImpactFeedbackGenerator(style: .heavy); generator.impactOccurred()
            uploadMessage = uploadManager.autoUploadEnabled ? "🔄 自動送信モード" : "✋ 手動送信モード"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { if !isUploading { uploadMessage = "" } }
        })
        .disabled(isUploading || serverIP.isEmpty)
    }
    
    private func startManualUpload() {
        guard !isUploading, uploadManager.pendingCount > 0 else { return }
        
        // 送信状態のリセットとタイマー開始
        uploadElapsedSeconds = 0
        isUploading = true
        uploadMessage = "🔄 手動送信中..."
        
        // タイマー開始
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if !isUploading { timer.invalidate(); return }
            uploadElapsedSeconds += 1
        }
        
        uploadManager.retryAll(serverIP: serverIP) { completed, total, message in
            DispatchQueue.main.async {
                if message == "完了" || message.contains("件失敗") || total == 0 {
                    // 全件の処理が終了した（成功・失敗問わず）
                    isUploading = false
                    if completed == total {
                        uploadMessage = "✅ 送信完了 (\(completed)/\(total))"
                    } else {
                        if let errorMsg = uploadManager.sessions.first(where: { $0.status == .failed && $0.errorMessage != nil })?.errorMessage {
                            uploadMessage = "⚠️ \(errorMsg) (\(completed)/\(total))"
                        } else {
                            uploadMessage = "⚠️ 一部失敗 (\(completed)/\(total))"
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if !isUploading { uploadMessage = "" }
                    }
                } else if message.contains("❌ エラー") {
                    // 個別の失敗通知。ここではクルクルは止めず、メッセージだけ更新。
                    uploadMessage = message
                } else {
                    // 送信中の進捗
                    uploadMessage = message
                }
            }
        }
    }
}

struct TomatoPlantVector: View {
    let topProgress: Double
    let middleLeftProgress: Double
    let middleRightProgress: Double
    let bottomLeftProgress: Double
    let bottomRightProgress: Double
    let isAnyActive: Bool
    
    var body: some View {
        ZStack {
            // ── 1. 地面 (ベースプレート) ──
            RoundedRectangle(cornerRadius: 1)
                .fill(isAnyActive ? Color.green.opacity(0.3) : Color(white: 0.35))
                .frame(width: 50, height: 2)
                .offset(y: 28)
            
            // ── 2. 主幹 (中央の茎) ──
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isAnyActive ? Color.green.opacity(0.7) : Color(white: 0.4))
                .frame(width: 3.5, height: 52)
                .offset(y: 2)
            
            // ── 3. 茎から伸びる美しい「枝 (Branches)」 ──
            // これにより、バラバラのパーツではなく「一本の有機的なトマト株」として完全に繋がります！
            
            // 左中枝 (MiddleLeft Branch)
            Path { path in
                path.move(to: CGPoint(x: 40, y: 35))
                path.addQuadCurve(to: CGPoint(x: 20, y: 22), control: CGPoint(x: 30, y: 30))
            }
            .stroke(isAnyActive ? cropColor(for: middleLeftProgress, isAnyActive: isAnyActive).opacity(0.8) : Color(white: 0.4), lineWidth: 2)
            
            // 右中枝 (MiddleRight Branch)
            Path { path in
                path.move(to: CGPoint(x: 40, y: 35))
                path.addQuadCurve(to: CGPoint(x: 60, y: 22), control: CGPoint(x: 50, y: 30))
            }
            .stroke(isAnyActive ? cropColor(for: middleRightProgress, isAnyActive: isAnyActive).opacity(0.8) : Color(white: 0.4), lineWidth: 2)
            
            // 左下枝 (BottomLeft Branch)
            Path { path in
                path.move(to: CGPoint(x: 40, y: 48))
                path.addQuadCurve(to: CGPoint(x: 18, y: 42), control: CGPoint(x: 28, y: 48))
            }
            .stroke(isAnyActive ? cropColor(for: bottomLeftProgress, isAnyActive: isAnyActive).opacity(0.8) : Color(white: 0.4), lineWidth: 2)
            
            // 右下枝 (BottomRight Branch)
            Path { path in
                path.move(to: CGPoint(x: 40, y: 48))
                path.addQuadCurve(to: CGPoint(x: 62, y: 42), control: CGPoint(x: 52, y: 48))
            }
            .stroke(isAnyActive ? cropColor(for: bottomRightProgress, isAnyActive: isAnyActive).opacity(0.8) : Color(white: 0.4), lineWidth: 2)
            
            // ── 4. 各部位の葉っぱ (TomatoLeafVector) と果実 (TomatoFruitVector) ──
            // 🟢 Top (上部)
            TomatoLeafVector(progress: topProgress, isAnyActive: isAnyActive, size: 10, rotation: 0, offsetX: 0, offsetY: -26)
            TomatoFruitVector(progress: topProgress, isAnyActive: isAnyActive, size: 12, offsetX: 0, offsetY: -18)
            
            // 🟢 MiddleLeft (中左)
            TomatoLeafVector(progress: middleLeftProgress, isAnyActive: isAnyActive, size: 9, rotation: -35, offsetX: -18, offsetY: -12)
            TomatoFruitVector(progress: middleLeftProgress, isAnyActive: isAnyActive, size: 11, offsetX: -22, offsetY: -5)
            
            // 🟢 MiddleRight (中右)
            TomatoLeafVector(progress: middleRightProgress, isAnyActive: isAnyActive, size: 9, rotation: 35, offsetX: 18, offsetY: -12)
            TomatoFruitVector(progress: middleRightProgress, isAnyActive: isAnyActive, size: 11, offsetX: 22, offsetY: -5)
            
            // 🟢 BottomLeft (下左)
            TomatoLeafVector(progress: bottomLeftProgress, isAnyActive: isAnyActive, size: 9, rotation: -65, offsetX: -16, offsetY: 12)
            TomatoFruitVector(progress: bottomLeftProgress, isAnyActive: isAnyActive, size: 11, offsetX: -20, offsetY: 20)
            
            // 🟢 BottomRight (下右)
            TomatoLeafVector(progress: bottomRightProgress, isAnyActive: isAnyActive, size: 9, rotation: 65, offsetX: 16, offsetY: 12)
            TomatoFruitVector(progress: bottomRightProgress, isAnyActive: isAnyActive, size: 11, offsetX: 20, offsetY: 20)
        }
        .frame(width: 80, height: 60)
    }
}

struct TomatoFruitVector: View {
    let progress: Double
    let isAnyActive: Bool
    let size: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    
    var body: some View {
        ZStack {
            // 1. トマトの果実本体 (丸)
            Circle()
                .fill(cropColor(for: progress, isAnyActive: isAnyActive))
                .frame(width: size, height: size)
                .shadow(color: cropColor(for: progress, isAnyActive: isAnyActive).opacity(0.6), radius: 2)
            
            // 2. トマトのヘタ (黄色の小さな星)
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.45))
                .foregroundColor(isAnyActive && progress > 0.0 ? Color.green.opacity(0.8) : Color(white: 0.6))
                .offset(y: -size * 0.45)
            
            // 3. 進捗パーセンテージ of tomato fruit
            if progress > 0.0 {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 6.0, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                    .offset(y: 0.5)
            }
        }
        .offset(x: offsetX, y: offsetY)
    }
}

struct TomatoLeafVector: View {
    let progress: Double
    let isAnyActive: Bool
    let size: CGFloat
    let rotation: Double
    let offsetX: CGFloat
    let offsetY: CGFloat
    
    var body: some View {
        Image(systemName: "leaf.fill")
            .font(.system(size: size))
            .rotationEffect(.degrees(rotation))
            .foregroundColor(cropColor(for: progress, isAnyActive: isAnyActive))
            .shadow(color: cropColor(for: progress, isAnyActive: isAnyActive).opacity(0.4), radius: 2)
            .offset(x: offsetX, y: offsetY)
    }
}

// ─── グローバル共有ヘルパー関数（スキャンの進捗に伴いモノクロ➔カラー進化を完璧に表現） ───
func cropColor(for progress: Double, isAnyActive: Bool) -> Color {
    if !isAnyActive {
        return Color(white: 0.35) // 未撮影時は深みのあるダークグレー
    }
    if progress == 0.0 {
        return Color(white: 0.5) // 録画中だが未スキャン：モノクログレー
    } else if progress < 0.35 {
        return Color.red
    } else if progress < 0.65 {
        return Color.orange
    } else if progress < 0.90 {
        return Color.yellow
    } else {
        return Color.green
    }
}

extension View {
    func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}
