# server-login

Windows 11 / AVD 上から RDP / SSH / SFTP で社内サーバへ素早くログインするための WPF GUI。
PowerShell 5.1 + XAML 実装。AWS EC2 や社内 VM など、リストファイルに書いたサーバを
ランチャーバーから開き、一覧の行ボタンで接続するだけ。

## 主な機能

- **OS 別接続**: Linux → SSH (Tera Term / PuTTY) + SFTP (WinSCP) / Windows → RDP (mstsc)
- **ランチャーバー**: 起動直後は「サーバ接続 / ログ / 記録 / 設定」だけのコンパクト表示
- **サーバ一覧**: YAML で管理。一覧の各行から RDP / SSH / SFTP を直接起動
- **接続ボタン制御**: Windows は RDP、Linux は設定済みツールに応じて SSH / SFTP のみ有効化
- **DPAPI 暗号化パスワード**: 平文を YAML に書かずに済む。OS の認証情報マネージャには保存しない（YAML 内のみ）
- **設定 GUI**: Tera Term / PuTTY / WinSCP の実行ファイルパスを保存

## セットアップ

前提:

- Windows 11 (PowerShell 5.1)
- 必要なクライアント（インストール済みのものだけでよい）:
  - Tera Term または PuTTY（Linux SSH 用）
  - WinSCP（Linux SFTP 用）
  - mstsc（Windows 標準。Windows RDP 用）

### 起動

```powershell
.\launch.bat
```

初回起動時はサーバ一覧ファイルが無いので、**[サーバ接続]** → **[一覧編集]** でディレクトリを
開き、[`servers.example.yaml`](servers.example.yaml) を参考にコピー編集。

### 設定

ヘッダの **[設定]** で以下を保存（`%LOCALAPPDATA%\server-login\settings.json`）:

- サーバ一覧 YAML パス（既定: `%USERPROFILE%\.server-login\servers.yaml`）
- Tera Term / PuTTY / WinSCP の実行ファイルパス
- 既定の SSH クライアント（Tera Term or PuTTY）
- 保存先（未指定時: デスクトップ）
- 記録ショートカット（既定: `Ctrl+Alt+S`、設定画面の **[記録]** ボタンで登録）

### スクリーンショット記録

接続中の作業記録として、現在の前面ウィンドウを PNG で保存できます。

- 設定したショートカット: GUI が最小化中でも、その時点の前面ウィンドウを保存
- ランチャーバーの **[記録]** ボタン: 現在の前面ウィンドウを保存
- ランチャーバーの **[ログ]** ボタン: 当日の保存先フォルダを開く
- 記録保存先: `<設定した保存先>\yyyy-MM-dd-<WindowsユーザID>\capture\<host-id>\`
- ログ保存先: `<設定した保存先>\yyyy-MM-dd-<WindowsユーザID>\log\<host-id>\`
- リモート接続に紐づかない前面ウィンドウは `capture\local\` に保存
- Tera Term / PuTTY / WinSCP はツールログを出力し、RDP を含む各接続は起動記録を同じ `log\<host-id>\` に保存

同じホストに対する同じ接続種別は、複数起動していても同じフォルダに保存されます。
保存されるのは画面画像のみで、パスワードや秘密鍵の内容は記録しません。

## サーバ一覧 YAML

```yaml
servers:
  - name: web-prod-01
    os: Linux                          # Linux または Windows
    host: 10.0.1.10                    # 省略可。省略時は name で接続
    user: ec2-user
    key_file: C:\Users\you\.ssh\rsa    # 省略可。あれば鍵認証
    environment: 本番                  # 本番 / 検証 / 開発 / ...
    role: 一般                         # 管理者 / 一般 / ...
    in_development: false              # 互換用フラグ。通常は false
    note: フロントエンド Web
```

全フィールドは [`servers.example.yaml`](servers.example.yaml) と[ServerList.psm1](ServerList.psm1) を参照。

## パスワードの扱い

3 通り（推奨順）:

1. **DPAPI 暗号化**: `.\Protect-ServerPassword.ps1` で暗号文を生成 → `password_protected:` に貼る。
   同一 Windows ユーザー・同一マシンでのみ復号可能（他端末ではキャンセル/再生成）。
2. **接続時入力**: `password` も `password_protected` も書かない → 接続時にダイアログで入力
3. **平文**: `password: <plain>` — 非推奨。検証用途のみ

OS の認証情報マネージャ（cmdkey 等）には**保存しません**。

## テスト

```powershell
Invoke-Pester -Path tests/
```

## バージョン

現在: **0.1.0** — 変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照。

## 将来予定

- AWS EC2 Manager (`aws-ec2-manager`) との統合 — インスタンスを選択して直接接続
- AWS SSM Session Manager 経由の接続（踏み台/VPN なしで RDP/SSH）
- 接続履歴の永続化

## ライセンス

[MIT](LICENSE)
