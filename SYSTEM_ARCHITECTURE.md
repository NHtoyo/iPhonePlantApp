# iPhonePlantApp システム構成図

最終確認日: 2026-09-27  
対象: 現行の iOS アプリ、端末内処理、アップロード経路と保存先

この資料は、ひとつの巨大な図にすべてを詰め込まず、目的別の図を組み合わせてシステム全体を説明します。図の内容はリポジトリ内の現行コードと `APP_REPRODUCTION_SPEC.md` に基づきます。iOSアプリ外の受信サーバーやNASは、アプリから確認できる通信契約と運用情報の範囲で描いています。

## 1. この種のシステム構成図には何があるか

| 図の種類 | 何を示すか | このアプリでの用途 |
|---|---|---|
| システムコンテキスト図 | 利用者、アプリ、外部サービス、保存先の関係 | アプリの境界と、何がアプリの外にあるかを示す |
| ソフトウェア／コンポーネント図 | アプリ内モジュールと責務・依存関係 | Swiftファイル、Apple Framework、データの受け渡しを示す |
| データフロー／処理パイプライン図 | 入力データがどの処理を経て何になるか | AR撮影、AI検出、品質計算、ファイル生成を示す |
| シーケンス図 | 時間順の呼び出し、リクエスト、応答 | IP方式とngrok方式の送信手順・失敗点を比べる |
| 配置／ネットワーク図 | 実行環境、ネットワーク境界、通信経路 | iPhone、HTTP/HTTPS、ngrok、受信API、NASの接続を示す |
| データ／保存図 | ファイル形式、保存場所、設定・状態の永続化 | Documents、UserDefaults、Keychain、TARの関係を示す |
| 状態／エラー遷移図 | 状態変化とエラー分類 | 未送信、送信中、成功、失敗、再送の挙動を示す |

このアプリを「再実装できる粒度」で説明するには、**全体・コンポーネント・撮影データフロー・送信シーケンス／ネットワーク**を中心にし、AIの内部処理とデータ契約を別図にするのが読みやすい構成です。

## 2. 全体構成図（システムコンテキスト＋配置）

```mermaid
flowchart LR
    user[利用者]

    subgraph phone[LiDAR対応 iPhone / iOS]
        app["iPhonePlantApp<br/>SwiftUI / Swift"]
        ar["ARKit / RealityKit<br/>カメラ・姿勢・深度・Raycast"]
        vision["Vision + Core ML<br/>同梱 YOLO kendama モデル"]
        docs[("Documents<br/>画像・深度・transforms.json・履歴対象データ")]
        prefs[("UserDefaults<br/>接続方式・URL・保存先階層・自動送信等")]
        keychain[("iOS Keychain<br/>ngrok API key")]
        app --> ar
        app --> vision
        app --> docs
        app --> prefs
        app --> keychain
    end

    subgraph intranet[研究室内ネットワーク / IP方式]
        local["受信サーバー<br/>HTTP :5000 /upload"]
    end

    subgraph public[HTTPS / ngrok方式]
        edge["ngrok HTTPS URL<br/>POST /upload"]
        tunnel["ngrok tunnel / agent"]
        receiver["アップロード受信API<br/>API key・multipart・folder fieldsを検証"]
        nas[("NAS upload root<br/>設定された階層へ保存")]
        edge --> tunnel --> receiver --> nas
    end

    user --> app
    ar -->|ARFrame| app
    app -->|HTTP multipart: TAR| local
    app -->|HTTPS multipart: TAR + API key + 任意のfolder fields| edge

    classDef appNode fill:#e8f2ff,stroke:#4b78a8
    classDef external fill:#f3f3f3,stroke:#777
    class app,ar,vision appNode
    class local,edge,tunnel,receiver external
```

ngrok側の保存先階層は設定可能です。現在の既定値は `nakamura` → `トマト動画` で、受信APIがNASの `upload` をルートとしてこの階層を使う場合の保存先は `upload/nakamura/トマト動画` です。**アプリはNASへ直接接続しません**。受信APIが階層をどう解釈し、TARを展開するかはサーバー側の実装に依存します。

## 3. アプリ内部コンポーネント図

```mermaid
flowchart TB
    subgraph ui[画面・操作]
        content["ContentView.swift<br/>AR画面・撮影・履歴・品質表示・送信起点"]
        settings["ServerSettingsSection.swift<br/>IP/ngrok・API key・保存先階層設定"]
        menu["SideMenuView / HistorySection / NamingRulesSection"]
        overlay["BoundingBoxOverlay.swift<br/>検出枠表示"]
    end

    subgraph capture[AR撮影・解析]
        scanner["ARScannerView.swift<br/>ARSession・フレーム採取・Raycast・ガイド点"]
        detector["RefSphereDetector.swift<br/>Vision request・Core ML推論・候補選択"]
        model[("yolo_kendama_best.mlpackage")]
        recorder["DataRecorder.swift<br/>JPEG・深度PNG・姿勢・品質・JSON"]
    end

    subgraph transfer[端末保存・送信]
        uploader["UploadManager.swift<br/>命名・履歴・TAR・IP/ngrok送信"]
        files[("Documents session directory")]
        archive[("一時 multipart body / 非圧縮 TAR")]
        prefs[("UserDefaults")]
        secrets[("Keychain")]
    end

    content --> scanner
    content --> recorder
    content --> uploader
    content --> settings
    content --> menu
    scanner --> detector
    detector --> model
    scanner --> overlay
    scanner --> recorder
    recorder --> files
    uploader --> files
    uploader --> archive
    settings --> prefs
    settings --> secrets
    uploader --> prefs
    uploader --> secrets
```

### コンポーネント図の読み方

- ARKitのカメラフレームとカメラ姿勢を `ARScannerView` が受け、必要な深度情報とともに撮影側へ渡します。
- `RefSphereDetector` が同梱モデルをVision経由で実行します。現行モデルのクラスは `kendama` で、アプリでは基準球 `ref_sphere` として扱います。トマト部位を認識するモデルではありません。
- `DataRecorder` はセッション一式を端末内に生成し、`UploadManager` はそのディレクトリから送信データを組み立てます。
- `ObjectDetector.swift`、`CoordinateTransform.swift`、`PointCloudVisualizer.swift` は現行経路から未接続です。名前だけで実行中コンポーネントとみなさないでください。

## 4. 撮影・AI・ファイル生成のデータフロー

```mermaid
flowchart LR
    camera["iPhone camera / LiDAR"] --> frame["ARKit ARFrame<br/>画像・カメラ姿勢・任意のsceneDepth"]

    frame --> detectSchedule{"基準物体検出ON?<br/>2フレームに1回推論"}
    detectSchedule -->|はい| preprocess["Vision<br/>image orientation up / scaleFill"]
    preprocess --> model["Core ML YOLO<br/>320×320・kendama 1クラス"]
    model --> filter["アプリ後処理<br/>confidence ≥ 0.50<br/>採用結果を ref_sphere と命名"]
    filter --> box["bounding boxを画面座標へ変換"]
    box --> raycast["ARKit Raycast<br/>box中心から推定面を探索"]
    raycast --> calibrate["複数視点キャリブレーション<br/>移動12cm + 回転約12°を合成"]
    calibrate --> guide["中心を座標ごとの中央値で確定<br/>半円筒ガイド 210点"]
    guide --> coverage["カメラとガイド点の訪問判定<br/>全体・5部位の進捗"]

    frame --> capture{"録画中?<br/>6フレームに1回保存"}
    capture -->|はい| rgb["JPEG画像<br/>images/frame_####.jpg"]
    capture -->|sceneDepthあり| depth["16-bit PNG深度<br/>depths/frame_####.png<br/>単位 mm / 0=無効"]
    frame --> pose["姿勢・カメラintrinsics"]
    rgb --> recorder["DataRecorder<br/>品質指標・対応関係を管理"]
    depth --> recorder
    pose --> recorder
    recorder --> stop["撮影停止"]
    stop --> quality["品質レポート<br/>tracking / motion / depth coverage"]
    stop --> manifest["transforms.json生成"]
    rgb --> session[("Documents/<session>/images")]
    depth --> session2[("Documents/<session>/depths")]
    manifest --> session
```

注意: 検出は撮影保存とは別のフレーム周期で非同期実行されます。深度サンプルから基準物体の3D位置を直接算出する実装ではなく、検出box中心からARKit Raycastした位置を使います。

## 5. アップロード・シーケンス図

```mermaid
sequenceDiagram
    actor User as 利用者
    participant App as ContentView / UploadManager
    participant Local as Documentsのsession
    participant Tar as TAR・multipart一時ファイル
    participant Direct as 研究室内受信API
    participant Ng as ngrok HTTPS入口
    participant Agent as ngrok tunnel / agent
    participant API as ngrok受信API
    participant NAS as NAS upload領域

    User->>App: 送信（自動または手動）
    App->>Local: session内ファイルを列挙
    Local-->>App: images / depths / transforms.json
    App->>Tar: 非圧縮 .tar を作成
    Tar->>Tar: multipart bodyを一時ファイルに組み立て

    alt 研究室内IP方式
        App->>Direct: HTTP POST http://<IP>:5000/upload<br/>multipart file=<session.tar>
        Note over App,Direct: folder fieldsなし・API key headerなし
        Direct-->>App: HTTP 200なら成功扱い
    else ngrok方式
        App->>Ng: HTTPS POST https://<host>/upload<br/>multipart file=<session.tar><br/>X-API-Key + 任意のfolder/subfolder
        Ng->>Agent: トンネル転送
        Agent->>API: /uploadへ転送
        API->>API: API key・ファイル・階層を検証
        API->>NAS: 設定階層へ保存
        NAS-->>API: 保存結果
        API-->>Agent: HTTP status + JSON
        Agent-->>Ng: トンネル応答
        Ng-->>App: HTTP response
        Note over App,API: 現行アプリはHTTP 200だけを成功扱い
    end

    alt 成功
        App->>App: 履歴 status = uploaded
        Note over Local,App: 元sessionは送信成功後も端末に残る
    else 失敗
        App->>App: エラー分類を表示<br/>履歴 status = failed
        User->>App: 必要に応じて再送
    end
```

送信前の `.tar` は**圧縮ファイルではありません**。TARは複数ファイルを一つのアーカイブにまとめる形式です。ngrok経路でも、アプリが送るのはTARを含むmultipart HTTPリクエストであり、ngrokがファイル形式を変換するわけではありません。

## 6. セッションデータと永続化

```mermaid
flowchart LR
    subgraph capture[撮影セッション]
        images["images/frame_####.jpg"]
        depths["depths/frame_####.png<br/>深度がある場合"]
        transforms["transforms.json<br/>姿勢・intrinsics・画像/深度path"]
    end

    capture --> documents[("iOS Documents/<session>")]
    documents --> tar["再送時に毎回生成<br/><session>.tar / 圧縮なし"]
    tar --> transport["multipart file field"]

    preferences[("UserDefaults<br/>server_ip / destination mode / URL<br/>folder levels / auto upload / naming / history")]
    key[("Keychain<br/>ngrok API key")]
    uploader["UploadManager"]
    preferences --> uploader
    key --> uploader
    documents --> uploader
    uploader --> tar

    uploader --> state["savedLocal → uploading<br/>→ uploaded または failed"]
```

## 7. 送信状態と失敗点

```mermaid
stateDiagram-v2
    [*] --> savedLocal: 撮影完了・端末保存
    savedLocal --> uploading: 自動送信または手動送信
    failed --> uploading: ユーザーが再送
    uploading --> uploaded: HTTP 200
    uploading --> failed: 設定 / ファイル / TAR / 通信 / HTTPエラー
    uploaded --> [*]
```

送信失敗の画面表示は、設定、端末内データ、TAR/multipart生成、DNS、接続、TLS、認証、サイズ上限、リクエスト形式、URL、レート制限、サーバー応答、タイムアウト／キャンセルなどを区別します。ネットワーク失敗を自動で指数バックオフ再試行する仕組みはなく、「再送」は利用者操作です。

## 8. 境界・未確定事項

- この図で確認しているAIは、同梱の単一クラス `kendama` 検出器です。トマトの葉・実・茎を分類するAIは現行コードにありません。
- アプリは撮影データを生成し送信するクライアントです。ngrok agent、受信API、API key本体、NAS mount、外部サーバーのコードはiOSアプリのリポジトリに含まれません。
- ngrok方式の保存先階層はアプリ設定からmultipart fieldとして渡します。受信APIがNAS上でどのディレクトリに展開／保存するかは、受信側の実装と設定を確認してください。
- IP方式とngrok方式は別々のAPI契約です。IP方式は `http://<IP>:5000/upload`、ngrok方式は設定URLの `/upload` にHTTPSで送ります。
- Xcodeビルドに必要なSwiftソース、Assets、Core MLモデル、プロジェクト設定などの配置図は、リポジトリの現状に基づきます。署名設定や実機のLiDAR動作はビルド／実機環境に依存します。

## 関連資料

- [APP_REPRODUCTION_SPEC.md](APP_REPRODUCTION_SPEC.md): AI、計算式、ファイル形式、HTTP契約、制約を含む再実装仕様
- [README.md](README.md): リポジトリの概要
