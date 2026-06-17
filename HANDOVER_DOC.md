# HANDOVER_DOC.md — iPhonePlantApp プロジェクト引継ぎ書

最終更新: 2026-06-16

---

## プロジェクト概要

| 項目 | 内容 |
|------|------|
| 名称 | iPhonePlantApp |
| 目的 | iPhoneでARKit深度付き画像を撮影し、NeRF（Nerfstudio）用データセットを生成・アップロードするアプリ |
| プラットフォーム | iOS（Swift / ARKit） |
| リポジトリ | `\\100.110.66.37\share\共有ファイル置き場\iPhonePlantApp` |

---

## 主要フォルダ・ファイル

`
iPhonePlantApp/
├── iPhonePlantApp/              ← Swiftソースコード
│   ├── DataRecorder.swift       ← ARフレーム記録（深度PNG保存含む）★
│   ├── ARScannerView.swift      ← ARKit撮影UI
│   ├── ContentView.swift        ← メインUI
│   ├── UploadManager.swift      ← サーバーへのアップロード管理
│   ├── ObjectDetector.swift     ← YOLO物体検出
│   └── CoordinateTransform.swift← 座標変換
├── iPhonePlantApp.xcodeproj/    ← Xcodeプロジェクト
├── yolo_kendama_best.mlpackage  ← YOLO CoreMLモデル
└── inspect_model.py             ← モデル検査用Pythonスクリプト
`

---

## データ出力形式（Nerfstudio用）

撮影後、以下の構造でiPhone内に保存され、サーバーへアップロードされる。

`
<セッション名>/
├── images/          ← RGB画像（JPEG, 0.9品質）
│   └── frame_XXXX.jpg
├── depths/          ← 深度画像（16bit Grayscale PNG, mm単位）
│   └── frame_XXXX.png
└── transforms.json  ← カメラパラメータ・姿勢（Nerfstudio形式）
`

### 深度画像の仕様
- 解像度: 256×192（ARKitデプスマップのネイティブ解像度）
- ビット深度: 16bit グレースケール PNG
- 単位: ミリメートル（mm）
- 0 = 無効ピクセル（NaN/Inf/負値）
- ARKit Float32[m] → UInt16[mm]（×1000）変換済み
- バイト順: **Big Endian（PNG仕様準拠）** ← 2026-06-16修正済み

---

## バージョン・バグ修正履歴

### v3.4.3 (2026-06-16): transforms.json自動追記とバージョン表記更新
- **変更内容**:
  - `DataRecorder.swift` にて深度画像撮影時に自動生成される `transforms.json` に `"depth_unit_scale_factor": 0.001` を自動追記するように修正。これにより、Nerfstudio（depth-nerfactoなど）で16bit mm単位の深度画像をメートル単位に正しく変換して読み込めるようになった。
  - アプリ内のバージョン表示を **3.4.3** に変更 (`SideMenuView.swift` および `project.pbxproj` の `MARKETING_VERSION`)。

### v3.4.2 (2026-06-16): デプス画像エンディアン逆転バグ（縞々問題）修正
- **症状**: 保存されたデプスPNGが縞々になり、値が2〜65312mm（最大65m）と異常になる問題。
- **根本原因**: `DataRecorder.swift` の `saveDepthBufferAs16BitPNG()` 内、CGContext初期化時にbitmapInfoでバイト順を指定していなかった。
  - Swift の UInt16 配列は ARM Little Endian（例: 1500mm = [DC, 05]）
  - CGContext は 16bit Grayscale を Big Endian として解釈
  - 結果: 0xDC05 = 56325mm（約56m）として保存 → 縞々の原因
- **修正内容**: `DataRecorder.swift` L.317〜359
  - 保存前に `uint16Array.map { $0.bigEndian }` でBig Endianに変換。
  - `bitmapInfo` に `CGBitmapInfo.byteOrder16Big` を明示。
- **検証**: 修正後の画像値が300〜8810mm（平均2m前後）と正常であることを確認済み。

---

## 主要機能

| 機能 | 担当ファイル | 状態 |
|------|------------|------|
| ARKit撮影（RGB + Depth） | ARScannerView.swift | OK |
| 深度PNG保存（16bit mm） | DataRecorder.swift | OK（エンディアン修正済み）|
| transforms.json生成 | DataRecorder.swift | OK |
| サーバーアップロード | UploadManager.swift | OK |
| 撮影品質スコア | DataRecorder.swift | OK |
| YOLO物体検出 | ObjectDetector.swift | OK |
| confidenceMapフィルタ | DataRecorder.swift | 未実装（改善余地）|

---

## 未解決の改善項目

1. **confidenceMap未使用**: ARKitの信頼度マップを使って低信頼ピクセルを0にする処理が未実装。
   葉の隙間・反射面などで誤深度がNeRF学習に影響する可能性あり。

---

## 実行・ビルド方法

- Xcodeで iPhonePlantApp.xcodeproj を開く
- 実機（LiDAR搭載iPhone）に転送してビルド・実行

---

## データアップロードサーバー仕様と起動方法

iPhoneアプリから送信されるデータを受け取るPC側のFlaskサーバーの仕様です。

### 1. プログラム・バッチファイルの所在
* **サーバー起動用バッチファイル**: `C:\Users\islab\Desktop\run_server.bat`
  * デスクトップ上にあり、ダブルクリックで簡単にサーバーを起動できます。
* **アップロードサーバー本体**: `C:\Users\islab\Desktop\upload_server.py`
  * 受信データのデフォルト保存先はスクリプト内の `SAVE_DIR = r"D:\tomato_collection\トマト動画"` に指定されています。

### 2. 通信プロトコル仕様
サーバーはポート `5000` で稼働し、アプリの `UploadManager.swift` から以下のAPIが呼び出されます。

* **データアップロード (`/upload`)**
  * **エンドポイント**: `POST http://<サーバーIP>:5000/upload`
  * **Content-Type**: `multipart/form-data`
  * **処理内容**: 送信されたセッションデータ（tarアーカイブ）を受信し、`SAVE_DIR` 配下に自動展開します。
* **フォルダ名変更の同期 (`/rename`)**
  * **エンドポイント**: `POST http://<サーバーIP>:5000/rename`
  * **Content-Type**: `application/json`
  * **データ形式**: `{"old_name": "旧フォルダ名", "new_name": "新フォルダ名"}`
  * **処理内容**: アプリ内でフォルダ名が変更された際、サーバー側のフォルダ名も同期してリネームします。

---

## 次回作業時に確認すべきこと

- エンディアン修正後の実機テスト：新しいデプスPNGをPythonで確認し、値が300〜8000mmに収まることを確認する
- confidenceMapフィルタの実装を検討する
