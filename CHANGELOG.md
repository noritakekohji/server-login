# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- `servers.example.yaml`: 6 パターンのサンプル（本番鍵認証 / 本番暗号化 / 本番入力 / 開発中 / 検証 / IP 省略）
- Pester テスト 20 件（DPAPI 往復 / YAML パース / 接続コマンド引数形状）
- GitHub Actions CI: windows-latest 上で PSScriptAnalyzer + Pester
