# keynaco

macOS 向けの日本語 IME（Input Method Editor）。

## 設計思想

詳細は [`docs/concept.md`](docs/concept.md) を参照。

- **ユーザー入力を重視** - ユーザーが過去入力した語彙を学習して優先的にサジェストする。
- **品詞でサジェストを変える** — 名詞・固有名詞は積極的にサジェストする。助詞・助動詞はサジェストあえてしない。
- **ローカル完結** — クラウド変換や外部送信の予測に逃げない。LLM 補強もローカル推論（Zenzai）。学習はローカルの SQLite に閉じる。

## 動作要件

- macOS 26 以降
- Xcode 16 系（Swift 6.0 / strict concurrency）
- Zenzai 用モデルは HuggingFace の git submodule（Git LFS）で配布

## セットアップ

初回 clone のあと、Zenzai のモデルを取得する(任意)。

```bash
brew install git-lfs && git lfs install
git submodule update --init
git -C keynaco/Resources/zenz-v3.2-small-gguf lfs pull
```

## ビルド・インストール

Xcode プロジェクトを開いて Run すれば `/Library/Input Methods/keynaco.app` にインストールされる。CLI で行う場合は次のようになる。

```bash
xcodebuild build -scheme keynaco -destination "platform=macOS" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO
```

インストール後、システム設定の「キーボード」→「入力ソース」で **keynaco** を追加し、入力ソースメニューから切り替える。

## ドキュメント

| ドキュメント                                               | 内容                              |
| ---------------------------------------------------------- | --------------------------------- |
| [`docs/concept.md`](docs/concept.md)                       | プロダクトの差別化軸・設計の指針  |
| [`docs/domain/states.md`](docs/domain/states.md)           | 状態遷移図                        |
| [`docs/rejected.md`](docs/rejected.md)                     | 不採用機能の記録                  |
| [`docs/retrospectives.md`](docs/retrospectives.md)         | 開発判断・運用のメタルール        |
| [`docs/apple-intelligence.md`](docs/apple-intelligence.md) | FoundationModels の制約・実験結果 |
| [`docs/observation.md`](docs/observation.md)               | 経過観察中の機能                  |
| [`CHANGELOG.md`](CHANGELOG.md)                             | 変更履歴                          |

## 変換エンジン

- [AzooKey](https://github.com/ensan-hcl/azooKey)
- [Zenzai / zenz-v3](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf)
