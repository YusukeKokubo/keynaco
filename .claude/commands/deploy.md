ykey をビルドしてインストールする。

1. `xcodegen generate` で Xcode プロジェクトを再生成
2. `xcodebuild archive` で Release ビルド
3. 既存の `/Library/Input Methods/ykey.app` を削除して新しいアーカイブをコピー
4. `lsregister -f` で LaunchServices に再登録
5. ビルドエラーがあれば修正して再ビルド

```bash
xcodegen generate
rm -rf /tmp/ykey.xcarchive
xcodebuild archive -scheme ykey -archivePath /tmp/ykey.xcarchive -configuration Release CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=R2ZZ3ALJ36
```

ビルドが成功したら以下を実行:
```bash
killall ykey 2>/dev/null
sudo rm -rf "/Library/Input Methods/ykey.app"
sudo cp -R /tmp/ykey.xcarchive/Products/Applications/ykey.app "/Library/Input Methods/"
sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Library/Input Methods/ykey.app"
```
