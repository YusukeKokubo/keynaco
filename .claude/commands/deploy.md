ykey をビルドしてインストールする。

Build Post-action により `/Library/Input Methods/` への自動コピーとプロセス再起動が行われる。

1. `xcodegen generate` で Xcode プロジェクトを再生成
2. `xcodebuild build` でビルド（Post-action で自動インストール）
3. ビルドエラーがあれば修正して再ビルド

```bash
xcodegen generate
xcodebuild build -scheme ykey -configuration Debug
```
