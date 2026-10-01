keynaco をビルドしてインストールする。

引数: $ARGUMENTS

- 引数なし → **Release**（普段使い。最適化あり・デバッグソケットなし）
- `debug` → **Debug**（`/keynaco-ime-sandbox`・`scripts/test_*_sandbox.sh`・`debug_ime.py` を使うとき。検証が終わったら引数なしで Release に戻す）

Debug ビルドはデバッグソケット・IME Sandbox・毎キーのスナップショット通知が常駐し、普段使いで起動しっぱなしにすると劣化しうる（`IMESandboxWindow` のイベント蓄積で 150ms/key 超になった実績あり）。latency/input/fetch/divergence ログは Release でも記録される。

## 初回のみ：ACL 設定（sudo は一度だけ）

`/Library/Input Methods/` への書き込み権限を自分のアカウントに付与する。
一度実行すれば以降は sudo 不要になる。

```bash
sudo chmod +a "$(whoami) allow list,add_file,search,add_subdirectory,delete_child,delete,read,write,execute" "/Library/Input Methods"
```

## ビルド手順

ACL 設定済みであれば、ビルドだけで自動インストールまで完結する
（Post-action が再署名・コピー・プロセス再起動を行う）。

`CONFIG` は引数なしなら `Release`、`debug` なら `Debug`。

```bash
xcodebuild build -scheme keynaco -configuration "$CONFIG" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO
```

ビルドエラーがあれば修正して再ビルド。

インストール前に ACL が付いとるか確認する（無いと Post-action の `rm -rf` が中身だけ消して外枠が残り、`keynaco.app/keynaco.app` の二重構造になって keynaco が起動不能になる）:

```bash
ls -le -d "/Library/Input Methods" | grep -q "$(whoami) allow" || echo "ACL なし — 上の sudo chmod をユーザーに別ターミナルで実行してもらう"
```

## 注意

- `project.yml` は存在しない（`xcodegen` は不要）。`keynaco.xcodeproj` を直接使用する
- Post-action が DerivedData 内アプリの再署名（`codesign --force --deep --sign`）まで行う。手動再署名は不要
- ACL は `-R` なしでディレクトリ自体にのみ付与する（`-R` にすると既存 Apple 製 IME の内部バイナリへの変更が Operation not permitted で失敗する）
- ACL 設定後は `rm: Permission denied` が出なくなり、post-action がインストールまで完走する
- 初回インストール後はログアウト→ログインが必要（TIS キャッシュ更新のため）
