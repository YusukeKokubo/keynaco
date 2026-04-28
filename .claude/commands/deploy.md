keynaco をビルドしてインストールする。

## 手順

1. `xcodegen generate` で Xcode プロジェクトを再生成
2. `xcodebuild build` でビルド（Post-action で `/Library/Input Methods/` への自動コピーとプロセス再起動が行われる）
3. ビルドエラーがあれば修正して再ビルド
4. Post-action の再署名が失敗した場合は手動で再署名してコピー（下記参照）

```bash
/opt/homebrew/bin/xcodegen generate
xcodebuild build -scheme keynaco -configuration Debug \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO
```

## 署名証明書がない場合の追加手順

`security find-identity -v -p codesigning` で有効な "Mac Development" 証明書が見つからない環境では、
post-action の `codesign` 再署名が失敗し、起動時に macOS に SIGKILL される。
その場合はビルド後に以下を手動実行する：

```bash
# DerivedData パスはビルドログ内の BUILT_PRODUCTS_DIR に合わせる
SOURCE_APP="$(xcodebuild -scheme keynaco -configuration Debug -showBuildSettings CODE_SIGN_IDENTITY=- 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}')/keynaco.app"
codesign --force --deep --sign "-" "$SOURCE_APP"
pkill -f keynaco || true
rm -rf "/Library/Input Methods/keynaco.app"
cp -R "$SOURCE_APP" "/Library/Input Methods/keynaco.app"
open "/Library/Input Methods/keynaco.app"
```

## 注意

- `xcodegen` は `/opt/homebrew/bin/xcodegen` にある（PATH に入っていない場合あり）
- 初回インストール後はログアウト→ログインが必要（TIS キャッシュ更新のため）
