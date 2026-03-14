# ykey

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## ビルド・インストール

```bash
xcodegen generate
xcodebuild archive -scheme ykey -archivePath /tmp/ykey.xcarchive -configuration Release CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=R2ZZ3ALJ36
sudo rm -rf "/Library/Input Methods/ykey.app"
sudo cp -R /tmp/ykey.xcarchive/Products/Applications/ykey.app "/Library/Input Methods/"
sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Library/Input Methods/ykey.app"
```

- `xcodebuild archive`（`build` ではない）で Release ビルドする
- インストール先は `/Library/Input Methods/`（sudo 必要）。`~/Library/` ではない
- インストール後、ログアウト→ログインで反映。System Settings → キーボード → 入力ソース → 英語 で追加

## macOS 26 IME の罠

### Bundle ID に "inputmethod" が必須

macOS 26 では TIS がサードパーティ IME を認識するために Bundle ID に `inputmethod` の文字列が必要。これがないと `TISRegisterInputSource` は成功を返すが `TISCreateInputSourceList` に現れない。サイレントに失敗するため原因特定が極めて困難。

### Info.plist は xcodegen に上書きさせない

`project.yml` に `info:` セクションを入れると xcodegen が Info.plist を上書きする。`INFOPLIST_FILE` 設定のみで参照すること。

### inputText より handle(event:client:) を使う

`inputText(_:key:modifiers:client:)` は矢印キー等の特殊キーを受け取れない。`handle(_ event: NSEvent!, client sender: Any!) -> Bool` をオーバーライドすること。

### Swift クラスに @objc が必須

InputMethodKit は ObjC ランタイムでクラスを探す。Swift の `IMKInputController` サブクラスや `NSApplication` サブクラスには `@objc(ClassName)` を付けないと実行時に見つからない。Info.plist のクラス名もモジュールプレフィックスなしにする（`ykey.InputController` ではなく `InputController`）。

### IMKCandidates は macOS 26 で使えない

`IMKCandidates` の `selectCandidate(withIdentifier:)` が動作しない。候補ウィンドウは `NSWindow(.borderless, level: .popUpMenu)` + `NSTableView` で自作する。azooKey も同じアプローチ。

### Development 署名で spctl -a は "rejected" になる

正常動作する。Gatekeeper の仕様であり問題ない。
