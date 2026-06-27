# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- 前面ウィンドウのスクリーンショット保存機能を追加。
- ランチャーバーの **[記録]** ボタンと `Ctrl+Alt+S` グローバルホットキーを追加。
- 設定画面で保存先を指定できるようにした。
- 設定画面で記録ショートカットを指定できるようにした。
- 記録ショートカットを文字入力ではなく、ボタン押下後のキー入力で登録できるようにした。
- 接続ツールのログ出力先を `log\<host-id>\` にまとめ、起動ログも同じフォルダへ保存するようにした。

### Changed
- 記録保存先を `<保存先>\yyyy-MM-dd-<WindowsユーザID>\capture\<host-id>\` に変更し、リモート接続に紐づかない記録は `capture\local\` に保存するように変更。
- 起動直後を「サーバ接続 / ログ / 記録 / 設定」のランチャーバーに変更し、サーバ一覧は必要時だけ展開する構成に変更。
- 検索、環境フィルタ、選択中サーバ詳細ペイン、本番/管理者警告表示を廃止し、各行の右端に接続ボタンを配置。
- 接続ボタンは Windows では RDP、Linux では設定済みツールに応じた SSH / SFTP のみ有効化するように変更。
- 設定画面を「サーバ一覧 / 接続ツール / 記録」にカテゴリ化し、既定 SSH クライアントを PuTTY / WinSCP 近くへ移動。
- 記録ボタン押下時に GUI を最小化しないように変更。
- サーバ接続パネルの「閉じる」でランチャーバーサイズへ戻るように修正。
- 設定画面の下部が切れないようにリサイズ可能化し、記録ショートカット登録で修飾キー単体を押した時は確定せず待機するように修正。
- ランチャーにアイコンを追加し、接続ボタンは RDP / SSH / SFTP ごとに色分け。

## [0.1.0] - 2026-06-26

### Added
- 初版リリース
- WPF メインウィンドウ: サーバ一覧 DataGrid + 検索 + 環境フィルタ + 詳細パネル + 接続ボタン (RDP / SSH / SFTP)
- `AppSettings.psm1`: 外部ツールパス / 既定 SSH クライアント / サーバ一覧パスを `%LOCALAPPDATA%\server-login\settings.json` に永続化
- `PasswordProtect.psm1`: DPAPI による暗号化 / 復号 / 検出
- `ServerList.psm1`: 最小 YAML パーサ + サーバオブジェクト正規化（in_development フラグ含む）
- `ConnectionLauncher.psm1`: mstsc / Tera Term / PuTTY / WinSCP の起動関数
- 設定ダイアログ: ツールパスを GUI で指定（ファイル参照ダイアログ付き）
- パスワード暗号化ダイアログ: 暗号文をその場で生成してクリップボードへ
- `Protect-ServerPassword.ps1`: コマンドラインからの暗号化補助
- `servers.example.yaml`: 6 パターンのサンプル（本番鍵認証 / 本番暗号化 / 本番入力 / 開発中 / 検証 / host 省略）
- Pester テスト 20 件（DPAPI 往復 / YAML パース / 接続コマンド引数形状）
- GitHub Actions CI: windows-latest 上で PSScriptAnalyzer + Pester
