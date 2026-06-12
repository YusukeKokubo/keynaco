# PLAN260523b: AI コードリーディング時のトークン消費削減リファクタリング

## 背景・目的

AI（Claude Code 等）がこのコードベースを読む際、`Read` で1ファイルを丸ごと開くことが多い。
現状、巨大ファイル（特に `DebugSocketServer.swift` の 1962 行）は「特定のコマンドの挙動だけ確認したい」場面でも全行が context を圧迫する。

ファイル分割と関数抽出によって、AI が `Read offset/limit` や grep でピンポイント参照できる粒度に整える。
**ロジック変更は伴わない純粋なリファクタリング**。テストと domain docs はそのまま。

## 対象ファイルと現状

| ファイル | 行数 | 主な肥大要因 |
|---------|------|-------------|
| `keynaco/Debug/DebugSocketServer.swift` | 1962 | `processCommand` 単体で約520行（L1028–1550）の `if let x = cmd["…"]` 縦長ディスパッチ |
| `Core/Sources/Core/InputHandler+Candidates.swift` | 609 | MARK で章立て済みだが 1 ファイルに5トピックが同居 |
| `keynaco/InputController.swift` | 555 | 冒頭に IMKTextInput アダプタ（〜L107）が同居 |

## 方針

### 優先度 1: `DebugSocketServer.swift` 分割（最大効果）

`processCommand` をコマンド種別ごとに別 method へ抽出。**コマンド名 → handler クロージャ** のディスパッチ辞書を導入できると更に良いが、`cmd: [String: Any]` を unwrap する型がバラバラなので、まずは素直に method 抽出のみ。

**抽出単位（処理内容ごと）**

- `handleReset(cmd:)`  — L1033–1051
- `handleState(cmd:)`  — L1053–1057
- `handleGetLog(cmd:)` / `handleAnnotate(cmd:)`  — L1060–1070
- `handleLintSuite(cmd:)` — L1073–1077
- `handleWaitUntil(cmd:)` / `handleAssertEventually(cmd:)` — 既に分離済み（L646, 705）
- `handleSeedNounBigram(cmd:)` — L1090〜
- `handleSeedHistory(cmd:)` / `handleSetLastNoun(cmd:)` / `handleSetSurrounding(cmd:)` / `handleSetLeftContext(cmd:)` — L1114–1154
- `handleTestSuite(cmd:)` — L1156–1373
- `handleSequence(cmd:)` — L1375–1418
- `handleTypeString(cmd:)` — L1420–1447
- `handleKey(cmd:)` — L1449–終端

**ファイル分割（method 抽出後）**

抽出だけでも 520→各 30〜200 行に下がり読みやすくなる。さらに以下の3ファイルに分割:

1. `DebugSocketServer.swift` — クラス本体・I/O ループ・`processCommand` の薄いディスパッチ（〜400 行想定）
2. `DebugSocketServer+Commands.swift` — `handle*` 系コマンドハンドラ（〜800 行）
3. `DebugSocketServer+Snapshot.swift` — `makeRealDBSnapshot` / `copyDatabase*` / `cleanupSnapshot` 等の DB スナップショット周り（L1748–1836, 約 90 行）
4. `SocketMockClient.swift` — L1843–1903 を独立ファイルに（〜60 行）
5. `DebugCandidateWindow.swift` — L1906〜末尾の `struct`（〜60 行）

> 注: `processCommand` の switch 大手術や辞書化はやらない。auto mode で「機械的な抽出」だけに留め、ロジック差分ゼロを担保する。

### 優先度 2: `InputHandler+Candidates.swift` 分割

既存 MARK の境界でファイルを切る。

| 新ファイル | 元の範囲 | 内容 |
|-----------|---------|------|
| `InputHandler+Candidates.swift`（縮小） | L189–544 | `buildCandidateList`・Fixed slot ロジックのみ残す |
| `InputHandler+BracketMode.swift` | L14–187 | z+キー マップ・括弧候補マップ・括弧モード処理 |
| `InputHandler+CandidatesUtil.swift` | L545–570 | `isHiraganaPreferred` / `merged` |
| `SegmentizeLRUCache.swift` | L572–末尾 | LRU キャッシュ実装（独立した型） |

> アクセス制御は `public extension InputHandler` のままなので、ファイル分割しても外部 API への影響なし。

### 優先度 3: `InputController.swift` 分割

冒頭の `IMKTextInput → TextInputClient アダプタ`（L5–106、〜100 行）を `InputController+IMKAdapter.swift` に分離する。
本体は IMK イベント処理に集中。

## 進め方

1. **DebugSocketServer の method 抽出**（最重要）
   - `processCommand` から `handle*` を順に切り出し、本体は `if cmd["reset"] != nil { return handleReset(cmd: cmd) }` の連鎖に整理
   - 抽出ごとにビルドを通す（`xcodebuild build -scheme keynaco -destination "platform=macOS"`）
2. **DebugSocketServer のファイル分割**（method 抽出後）
   - `extension DebugSocketServer { … }` の形で別ファイルへ移動
   - `SocketMockClient` / `DebugCandidateWindow` は独立 struct なのでそのまま新ファイルへ
3. **InputHandler+Candidates 分割**
   - MARK 境界で機械的に分割。`public extension InputHandler` を継続使用
4. **InputController アダプタ分離**
5. 全工程後にテスト実行
   ```bash
   xcodebuild test -scheme keynaco -destination "platform=macOS"
   cd Core && swift test
   ```

## 各ステップごとの検証

- **ビルド成功** が必須条件（純粋な移動なのでテスト結果は変わらないはず）
- 各ステップ毎にコミット（`refactor(debug): …`、`refactor(core): …` プレフィックス）
- ロジック差分が生じたら即ロールバック

## やらないこと

- `processCommand` の switch 化や辞書ディスパッチへの変更（型が揃わないため副作用リスクが高い）
- コマンド名のリネーム・JSON スキーマ変更
- テストの分割（テストは別の最適化対象、まず本体から）
- `InputHandlerCandidatesTests.swift` (1028 行) や `InputHandlerSuccessorTests.swift` (528 行) の分割
- ドキュメント追加（CLAUDE.md/docs は現状すでにコンパクト）

## 想定効果

- `DebugSocketServer.swift` を 1962 → 5 ファイル平均 ~400 行に。「reset の挙動だけ確認」が ~50 行で済む
- `InputHandler+Candidates.swift` を 609 → 4 ファイル平均 ~150 行に
- AI が「Read で全行」しなくても grep+局所 Read で完結する設計に
- 副次効果: ファイル単位の git blame が話題ごとに整理される
