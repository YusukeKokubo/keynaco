keynaco をビルドしてインストールする。

## 初回のみ：ACL 設定（sudo は一度だけ）

`/Library/Input Methods/` への書き込み権限を自分のアカウントに付与する。
一度実行すれば以降は sudo 不要になる。

```bash
sudo chmod -R +a "$(whoami) allow list,add_file,search,add_subdirectory,delete_child,delete,read,write,execute" "/Library/Input Methods"
```

## ビルド手順

ACL 設定済みであれば、ビルドだけで自動インストールまで完結する
（Post-action が再署名・コピー・プロセス再起動を行う）。

```bash
xcodebuild build -scheme keynaco -configuration Debug \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO
```

ビルドエラーがあれば修正して再ビルド。

## 注意

- `project.yml` は存在しない（`xcodegen` は不要）。`keynaco.xcodeproj` を直接使用する
- Post-action が DerivedData 内アプリの再署名（`codesign --force --deep --sign`）まで行う。手動再署名は不要
- ACL 設定後は `rm: Permission denied` が出なくなり、post-action がインストールまで完走する
- 初回インストール後はログアウト→ログインが必要（TIS キャッシュ更新のため）
