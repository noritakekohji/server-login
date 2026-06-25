# server-login

Windows 11 / AVD 上から RDP / SSH / SFTP で社内サーバへ素早くログインするための WPF GUI。
PowerShell 5.1 + XAML 実装。AWS EC2 や社内 VM など、リストファイルに書いたサーバを
ドロップダウンや検索から選んで接続するだけ。

## 主な機能

- **OS 別接続**: Linux → SSH (Tera Term / PuTTY) + SFTP (WinSCP) / Windows → RDP (mstsc)
- **サーバ一覧**: YAML で管理。検索 + 環境タグでフィルタ
- **DPAPI 暗号化パスワード**: 平文を YAML に書かずに済む。OS の認証情報マネージャには保存しない（YAML 内のみ）
- **本番警告**: `environment: 本番` 選択時に確認ダイアログ。`in_development: true` で抑制可能
- **管理者警告**: `role: 管理者` 選択時に同様の確認
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

初回起動時はサーバ一覧ファイルが無いので、ヘッダの **[サーバ一覧を開く]** → ディレクトリが
作成されるので [`servers.example.yaml`](servers.example.yaml) を参考にコピー編集。

### 設定

ヘッダの **[設定]** で以下を保存（`%LOCALAPPDATA%\server-login\settings.json`）:

- サーバ一覧 YAML パス（既定: `%USERPROFILE%\.server-login\servers.yaml`）
- Tera Term / PuTTY / WinSCP の実行ファイルパス
- 既定の SSH クライアント（Tera Term or PuTTY）

## サーバ一覧 YAML

```yaml
servers:
  - name: web-prod-01
    os: Linux                          # Linux または Windows
    ip: 10.0.1.10                      # 省略可。省略時は name で接続
    user: ec2-user
    key_file: C:\Users\you\.ssh\rsa    # 省略可。あれば鍵認証
    environment: 本番                  # 本番 / 検証 / 開発 / ...
    role: 一般                         # 管理者 / 一般 / ...
    in_development: false              # 本番警告を抑制したい時 true
    note: フロントエンド Web
```

全フィールドは [`servers.example.yaml`](servers.example.yaml) と[ServerList.psm1](ServerList.psm1) を参照。

## パスワードの扱い

3 通り（推奨順）:

1. **DPAPI 暗号化**: ヘッダ **[パスワード暗号化]** ボタンで暗号文を生成 → `password_protected:` に貼る。
   コマンドラインからは `.\Protect-ServerPassword.ps1` でも生成可能。
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
