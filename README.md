# iPhonePlantApp

## Xcodeで開く

1. このリポジトリをcloneし、`iPhonePlantApp.xcodeproj` をXcodeで開きます。
2. Xcode 26.3以降でビルドします（プロジェクトのiOS Deployment Targetは26.2）。
3. 実機へインストールする場合は、Target `iPhonePlantApp` の `Signing & Capabilities` で利用するTeamを選択し、Bundle IdentifierがそのTeamで使える値か確認します。Team IDは個人環境依存のため、プロジェクトファイルには固定していません。

アプリのSwiftソース、Asset Catalog、Core MLモデル（`.mlpackage` と重みファイル）はビルドに必要なためGit管理対象です。Xcodeの`xcuserdata`、DerivedData、端末固有の署名情報は含めません。現状は外部Swift PackageやCocoaPodsへの依存はありません。

## アップロード設定

アプリのメニューにある「サーバー設定」で送信方式を選択します。

- `研究室内IP`: 従来どおりサーバーIPを入力し、`http://<IP>:5000/upload` へ送信します。
- `ngrok (外部HTTPS)`: HTTPSのベースURL、共有APIキー、`folder`、`subfolder` を入力します。URL末尾の `/upload` はアプリが付加します。

ngrok方式の保存先入力欄は0～2個の範囲で追加・削除できます。入力欄なしは `upload` 直下、1個は `folder`、2個は `folder` と `subfolder` として送ります。初期設定は `nakamura/トマト動画` です。ngrok URLは変更される可能性があるため固定していません。APIキーはiOS Keychainに保存され、ソースコードやUserDefaultsには保存されません。
