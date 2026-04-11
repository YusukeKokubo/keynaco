ykey をビルドする。

1. `xcodegen generate` で Xcode プロジェクトを再生成
2. `xcodebuild archive` で Release ビルド
3. ビルドエラーがあれば修正して再ビルド

```bash
xcodegen generate
rm -rf /tmp/ykey.xcarchive
xcodebuild archive -scheme ykey -archivePath /tmp/ykey.xcarchive -configuration Release CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=R2ZZ3ALJ36
```

ビルドが成功したら、以下のコマンドをユーザーに提示する（sudo が必要なためユーザーが自分で実行する）:
```bash
killall ykey 2>/dev/null
sudo rm -rf "/Library/Input Methods/ykey.app"
sudo cp -R /tmp/ykey.xcarchive/Products/Applications/ykey.app "/Library/Input Methods/"
sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Library/Input Methods/ykey.app"
```
