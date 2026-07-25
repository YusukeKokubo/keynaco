# keynaco

macOS 向け IME（Input Method Editor）。InputMethodKit + SQLite。

## ドキュメント

| ドキュメント | 内容 |
|-------------|------|
| [`docs/domain/states.md`](docs/domain/states.md) | 状態遷移図（コードから引き出せない俯瞰） |
| [`docs/concept.md`](docs/concept.md) | プロダクトの差別化軸・設計の指針（何のために存在するか） |
| [`docs/rejected.md`](docs/rejected.md) | 不採用機能の記録（同じ失敗を繰り返さないため） |
| [`docs/retrospectives.md`](docs/retrospectives.md) | 個別失敗から抽出した開発判断・運用のメタルール |
| [`docs/apple-intelligence.md`](docs/apple-intelligence.md) | FoundationModels の制約・実験結果・使いどころ |
| [`docs/observation.md`](docs/observation.md) | 経過観察中の機能（実装済みだが価値未確定。卒業/廃止を判断するためのリスト） |
| [`docs/zenzai-params.md`](docs/zenzai-params.md) | Zenzai 制御パラメータ（zenz-v3 の条件付き変換）の効き方と UI 露出の判断 |

**ドキュメント方針**: docs/ にはコードから引き出せない情報（理由・哲学・経験的失敗・俯瞰図）のみ置く。用語定義・behavior spec・入力シナリオは該当変数/関数の `///` ドキュメントコメントとテストが正本。**コード = 真実、ドキュメント = 真実から引き出せないもの限定**。

## ディレクトリ構成

レイアウトそのものは `ls` で分かる。ここに書くのは命名規約と、見ただけでは分からんディレクトリの性格だけ。

| パス | 規約・注意 |
|------|-----------|
| `plans/` | 設計・調査メモ（`PLAN<YYMMDD>[-letter]-<slug>.md` / `POC<…>.md`。規約は `plans-audit/references/plan-frontmatter.md`） |
| `ideas/` | アイデアメモ（`IDEA<YYMMDD>.md` 形式） |
| `issues/` | バグ・課題メモ（`ISSUE<YYMMDD>.md` 形式） |
| `keynaco/Debug/` | デバッグ用ツール。本番動作には影響しない |
| `LocalPackages/` | Xcode が生成するローカル SPM キャッシュ（ソースなし。`.build/` と `.swiftpm/` のみ） |

### スクリプト一覧（`scripts/`）

| スクリプト | 用途 |
|-----------|------|
| `test_core.sh` | Core ユニットテスト（fast のみ、`KeynacoCoreTests`） |
| `test_core_slow.sh` | Core 重いテストのみ（`KeynacoCoreSlowTests`、AzooKey 実機） |
| `test_core_all.sh` | Core fast + slow 両方 |
| `debug_ime.py` | デバッグソケット（`$TMPDIR/keynaco-debug.sock`）クライアント（キーシーケンス手動送信） |
| `test_marked_text_sandbox.sh` | marked text 同期・候補 Space/Shift+Delete のソケット回帰（`test_marked_text_sandbox.py` の薄いラッパー） |
| `test_candidate_cleanup_sandbox.sh` | passive/explicit Space・機能語 dismiss のソケット回帰（候補整理後の主要動線） |
| `cleanup_history_db.py` | history.db の重複読み統合・助詞行削除（ドライランあり。`--apply` で実行・自動バックアップ） |
| `test_prefix_focus.py` | 打鍵中 prefix focus の品詞別モーラ閾値回帰（形容詞 3 / 動詞 3 / 名詞 2 / 拗音 mora_count） |

## ビルド・インストール

`/deploy` スキル（Claude Code 内）でビルドからインストールまで一括実行する。Post-action でプロセス再起動しても `pgrep -x keynaco` が空のことがある。未起動なら `open "/Library/Input Methods/keynaco.app"` または日本語入力ソースへ切替。手動でビルドのみ行う場合:

```bash
xcodebuild build -scheme keynaco -destination "platform=macOS" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO
```

- `SWIFT_VERSION: "6.0"`（strict concurrency モード）。新しいクラス・struct を追加する際は `@MainActor`、`Sendable`、または `@unchecked Sendable` のいずれかが必要
- **`@unchecked Sendable` + `Task.detached` の注意**: `@unchecked Sendable` はコンパイラの並行性チェックをバイパスするため、内部の非スレッドセーフな状態を `Task.detached` から触ると無音でデータ競合になる。`KanaKanjiConverter` / Zenzai の `llama_context` は非スレッドセーフ（過去に SIGABRT クラッシュを引き起こした実績あり）。`AzooKeyConverter` ではこの converter を `LockedConverter`（NSLock でロック保持中のみクロージャに貸し出す private 型）に封じ込めてあり、素の `converter.*` を書く手段が存在しない＝ロック貼り忘れがコンパイルエラーになる。新メソッドを追加するときも必ず `locked.withLock { c in c.xxx() }` を通すこと（`converter` 参照をクロージャ外へ持ち出さないのが唯一の不変条件）。
- **Zenzai モデルのセットアップ**: `keynaco/Resources/zenz-v3.2-small-gguf/` は HuggingFace の git submodule（LFS 管理）。初回 clone 後に以下が必要:
  ```bash
  brew install git-lfs && git lfs install
  git submodule update --init
  git -C keynaco/Resources/zenz-v3.2-small-gguf lfs pull
  ```
  モデルがなくても Zenzai 機能がオフにフォールバックするだけでビルド自体は通る
- POS 分類（`AzooKeyPOSClassifier`）は AzooKey 辞書の `lcid` + 接続詞/感動詞辞書によるルールベース実装。Apple Intelligence 不要。起動時に `AzooKeyPOSBackfill` で未分類エントリを一括再分類する。以前の `LLMPOSClassifier`（FoundationModels）は精度壊滅（77% が `other`）のため削除済み。`LLMSegmentConverter`（セグメントモード LLM 補助）は Zenzai ON 環境での効果がなく削除済み。

## テスト実行

コマンドは上のスクリプト一覧を参照（普段は fast の `./scripts/test_core.sh` のみ）。アプリ＋ IMK 関連は `xcodebuild test -scheme keynaco -destination "platform=macOS"`。

- `cd Core && swift test` は slow 含めて全部走る。slow のみ除外するなら `swift test --filter KeynacoCoreTests`
- 末尾に `✔ Test run with 0 tests in 0 suites passed` が出るが正常（Swift Testing framework のノイズ）。XCTest の結果は `Executed N tests` として別途出力される

## コンポーネント構成

各クラス・関数・主要変数の振る舞いと不変条件は `///` ドキュメントコメントが正本（`fetchHistoryScoredMerged` の SUM 集計禁止、`recordPrefixes` の同一 output 最長読み統合、`isExplicitlySelected` の意味、`RomajiConverter` の `nn` 両方消費など）。

### 候補表示（`CandidateScoreBuilder` + flatten）

`CandidateScoreBuilder.build` が履歴・ユーザー辞書・AzooKey・数値/日時・ひらがな bonus を単一スコア列に統合し、`CandidateScoredLayout` がスコア降順で flatten する。行ごとの `ScoredCandidate.Source`（`candidateSources`）がセクション判定と Shift+Delete の正本。

| source 種別 | 行セクション | Shift+Delete |
|-------------|-------------|-------------|
| `hiraganaBuiltin` / `hiraganaPreferred` | fixed | 不可 |
| `historyExact` / `historyPrefix` | history | 可 |
| その他（`userDict`・`azooKey`・`number`・`dateTime` 等） | dictionary | 不可 |

`fixedEnd` は先頭から連続する hiragana preferred 行数（Zenzai 診断用）。sandbox では `candidateEntries[].section` を見る。

### 初期行

- `.explicit` / `.whileTyping` とも **スコア降順 row 0**（`CandidateScoreBuilder` + `CandidateScoredLayout`）
- `.whileTyping` で組み込み助詞 reading、または row 0 が機能語なら dismiss（concept 指針 1）

## パフォーマンス計測

Instruments は IME では実用的でない（UI にフォーカスが奪われ自然な打鍵ができない）。in-process 記録が唯一の実用手段で、`~/Library/Application Support/keynaco/` 配下の 3 種の JSONL に落ちる。ログの内訳とフラッシュ条件は `/keynaco-latency-profiler` スキルの `references/log-files.md` を参照。

## テスト方針

- `InputHandler`（純粋 Swift struct）+ `MockTextClient` でユニットテストする
- `ScenarioRegressionTests.swift`: 具体的な入力シーケンス×期待出力のリグレッションテスト（worked example の正本）
- **E2E 動作確認**: 状態（Bracket モード等）に依存する機能変更後は `/keynaco-ime-sandbox` スキルで実機相当の検証を行う（ユニットテストだけではパイプラインのタイミングバグを見逃す）。sandbox で通常文字を送るには `{"type_string": "k"}` を使う（`{"key": "k"}` は特殊キーのみ有効）
- **prefix focus / 履歴シードの sandbox**: `type_string` → `wait_azoo_key` → `state` で `selectedText` を見る（`seed_history` は `pos`/`lcid` 無し。final を `wait_azoo_key` だけにしない）

## ローマ字分解（エージェント向け）

**正本**: `RomajiConverter` + `Core/Sources/CoreTests/`（`InputHandlerCompositionTests.testKonnyakuProducesKonyaku` 等）。分解規則を OS 名・「標準 IME 準拠」で正当化しない。

- **`nn` は両方の `n` を消費して `ん`**。`hiddenPendingN`（非表示 pending `n`）は不採用（[`docs/rejected.md` R-1](docs/rejected.md)）。
- **表記 ≠ 打鍵列**: Web の Hepburn 表記（例: こんにゃくの英字 `konnyaku`）と、IME への打鍵を 1 文字ずつ分解した結果は別物。
- **変更・説明前に trace する**: `konnyaku` → `k+o=こ` / `n+n=ん` / `y+a=や` / `k+u=く` → **こんやく**（婚約）。この反例を壊さない。
- **やってはいけない**: 特定 OS/製品 IME の挙動を未検証で断定する、表記から打鍵結果を推論する、Converter の `pending` 実装を「IME の内部状態」と述べる。

## キー入力の挙動（特殊ケース）

- **keyDown の pre/post 読み分け**: 本番・sandbox・benchmark は `KeyEventPipeline.preSnapshot` → `runHandle(pre:)` で固定する。`handle()` に渡す `candidate` は pre 時点の `candidateSession.makeContext()`。新しい keyDown 経路を足すときはこのパイプラインを通すこと（手書きの pre 退避を増やさない）。
- **Shift+英字（日本語モード、組成前）**: 英字単語モードを開始（`GitHub` 等の混在ケース用）。`InputHandlerAsciiTests.swift` 参照。
- **英数キー（keyCode 102）**: 組成中なら確定してASCIIモードへ。`ignoreNextModeSwitch` は **`activateServer` 直後に IMK が echo する英数/かなを 1 回無視**（入力ソース切替キーの余韻。英数押下の二重送信ではない）
- **`baseCharacters` vs `characters`**: Shift押下時、`characters`はシフト文字（`>`）、`baseCharacters`は素文字（`.`）。Shift+`,`/`.` は `characters` が `<`/`>` となり Bracket モード（`＜`/`＞` 候補）に入る
- **z シーケンス**: `z` + 記号/矢印キーで特殊文字を挿入（`zCharMap` / `zArrowMap` 定義）。`InputHandlerZSequenceTests.swift` 参照。
- **Bracket モード（`?` / `(` / `[` / `{` / `「` / `,` / `.` 等）**: 組成なし・ASCII モードでない状態でトリガー。`bracketOptions` マップで対応文字ペアを定義。US キーボードの `?` は `Shift+/`（`baseCharacters="/"`）なのでキーボード判定が必要（`InputHandler+Candidates.swift` 参照）。
- **Space（keyCode 49）**: 組成中・候補非表示なら候補窓表示（`buildCandidateList(trigger: .explicit)`）。候補表示中は passive なら explicit リビルド、explicit 選択済みなら次候補。未吸収ローマ字があるときは組み込み後に `.explicit` で再構築。

## macOS 26 IME の罠

### Bundle ID に "inputmethod" が必須（InputMethodKit 全般の仕様）

TIS がサードパーティ IME を認識するために Bundle ID に `inputmethod` の文字列が必要（macOS 26 固有ではなく InputMethodKit 長年の仕様）。これがないと `TISRegisterInputSource` は成功を返すが `TISCreateInputSourceList` に現れない。サイレントに失敗するため原因特定が極めて困難。

### inputText より handle(event:client:) を使う

`inputText(_:key:modifiers:client:)` は矢印キー等の特殊キーを受け取れない。`handle(_ event: NSEvent!, client sender: Any!) -> Bool` をオーバーライドすること。

### Swift クラスに @objc が必須

InputMethodKit は ObjC ランタイムでクラスを探す。Swift の `IMKInputController` サブクラスや `NSApplication` サブクラスには `@objc(ClassName)` を付けないと実行時に見つからない。Info.plist のクラス名もモジュールプレフィックスなしにする（`keynaco.InputController` ではなく `InputController`）。

### IMKCandidates は macOS 26 で動作しない（実体験）

`IMKCandidates` の `selectCandidate(withIdentifier:)` が macOS 26 環境で動作しなかった（Apple 公式の明示的なバグ報告はないが、歴史的に描画不安定の報告が多い）。候補ウィンドウは `NSWindow(.borderless, level: .popUpMenu)` + `NSTableView` で自作する。

### Development 署名で spctl -a は "rejected" になる

正常動作する。Gatekeeper の仕様であり問題ない。

### Electron 系アプリで Enter が届かない

`setMarkedText("")`（空文字）のまま候補を表示すると、Electron は「IME が非アクティブ」と判断し Enter をアプリ側で処理する。候補選択中は実テキストを marked text に設定すること。

### flagsChanged で Caps Lock を検知する

Caps Lock トグルは未実装。実装時は `handle(event:client:)` で `.flagsChanged` イベントを受け取り、`NSEvent.ModifierFlags.capsLock` で ON/OFF を判定する。`inputText` では flagsChanged を受け取れない。

## 不採用の機能

[`docs/rejected.md`](docs/rejected.md) を参照。

## プロダクトの差別化軸

[`docs/concept.md`](docs/concept.md) を参照。新機能の検討時に「ポジショニングに合致するか」のチェック基準として読む。

## 開発判断・運用のメタルール

[`docs/retrospectives.md`](docs/retrospectives.md) を参照。新機能の実装前・大きなリファクタリング前に読み返す。
