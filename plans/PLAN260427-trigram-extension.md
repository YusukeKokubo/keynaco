# PLAN260427: trigram 拡張（PLAN260420 案 3 の実装）

## Context

`PLAN260420.md` 案 3 を実装する。現状の予測入力は `bigram(prev, input, output)` で 1 語前のみを文脈化しているが、2 語前まで遡る `trigram(prev2, prev1, input, output)` を追加することで、案 1（Successor モード）の予測精度を底上げする。

例: 「昨日 / 東京 / に」と続いたとき、bigram だけでは `行く` `住む` `戻る` が混在するが、trigram があれば `行った` を最上位に出せる。

trigram は bigram の **置き換えではなく上乗せ**。trigram ヒットを優先し、bigram 結果で重複除去後に補完する（merge 戦略）。`doRefreshCandidates` と `doSuggestSuccessors` の両方で適用する。設定画面の Trigram タブ・JSON I/O は今回スコープ外（必要に応じて別 PR で追加）。

---

## 設計概要

### 1. スキーマ追加（`Sources/DatabaseManager.swift`）

`createTables()`（`DatabaseManager.swift:40-63`）に以下を追記。`CREATE TABLE IF NOT EXISTS` のため migration 不要。

```sql
CREATE TABLE IF NOT EXISTS trigram (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    prev2   TEXT    NOT NULL,
    prev1   TEXT    NOT NULL,
    input   TEXT    NOT NULL,
    output  TEXT    NOT NULL,
    count   INTEGER NOT NULL DEFAULT 1,
    used_at INTEGER NOT NULL,
    UNIQUE(prev2, prev1, input, output)
);
CREATE INDEX IF NOT EXISTS idx_trigram ON trigram(prev2, prev1, input);
```

### 2. DatabaseManager API 追加

bigram と並列に以下を追加。実装は既存 bigram メソッド（`recordBigram` `fetchBigram` `fetchBigramTop` `fetchBigramInList`）を雛形にする。

| 関数 | 用途 | 雛形元 |
|------|------|--------|
| `recordTrigram(prev2:prev1:input:output:)` | 確定時に学習 | `recordBigram` (`:193`) |
| `fetchTrigram(prev2:prev1:reading:) -> [String]` | 組成中の予測（input LIKE prefix） | `fetchBigram` (`:212`) |
| `fetchTrigramTop(prev2:prev1:limit:) -> [String]` | Successor モード（input 集約） | `fetchBigramTop` (`:228`) |
| `fetchTrigramInList(prev2:prev1:list:) -> [String]` | Successor 1 打目 fast-path | `fetchBigramInList` (`:249`) |

### 3. InputHandler の状態変更（`Sources/InputHandler.swift`）

`var lastCommittedOutput: String? = nil`（`:57`）を直近 2 件のスライディングウィンドウに置き換える。既存 API との互換のため computed プロパティを残す。

```swift
private var committedHistory: [String] = []  // 最大 2 要素

var lastCommittedOutput: String? { committedHistory.last }
private var prev2Output: String? {
    committedHistory.count >= 2 ? committedHistory[committedHistory.count - 2] : nil
}

private mutating func pushCommitted(_ text: String) {
    committedHistory.append(text)
    if committedHistory.count > 2 { committedHistory.removeFirst() }
}
```

`lastCommittedOutput` は読み取り専用 computed に変わるので、現在 `lastCommittedOutput = text` と代入している箇所をすべて `pushCommitted(text)` に置換する：

- `doCommit()` (`:307`)
- `confirmSuccessor()` (`:366`)

### 4. 学習タイミング（write path）

`doCommit()` (`:303-310`):

```swift
private mutating func doCommit(text: String, client: TextInputClient) {
    if !state.composingText.isEmpty {
        if let p1 = lastCommittedOutput {
            db.recordBigram(prev: p1, input: state.finalizedText, output: text)
            if let p2 = prev2Output {
                db.recordTrigram(prev2: p2, prev1: p1, input: state.finalizedText, output: text)
            }
        }
    }
    pushCommitted(text)
    client.insertText(text)
    state = CompositionState()
}
```

`confirmSuccessor()` (`:362-369`) も同様に trigram を学習。`input` / `output` ともに particle 自身（既存 bigram と同じ規約）。`lastCommittedOutput = particle` の代入を `pushCommitted(particle)` に置き換える。

```swift
private mutating func confirmSuccessor(_ particle: String, client: TextInputClient) {
    isSuccessorMode = false; successorFirstChar = nil
    if let p1 = lastCommittedOutput {
        db.recordBigram(prev: p1, input: particle, output: particle)
        if let p2 = prev2Output {
            db.recordTrigram(prev2: p2, prev1: p1, input: particle, output: particle)
        }
    }
    db.record(input: particle, output: particle)
    pushCommitted(particle)
    client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0))
    client.insertText(particle)
}
```

### 5. 読み出しタイミング（read path）

#### a. `doRefreshCandidates()` (`:431`)

```swift
let bigramRaw = lastCommittedOutput.map { db.fetchBigram(prev: $0, reading: state.composedHiragana) } ?? []
let trigramRaw: [String] = {
    guard let p1 = lastCommittedOutput, let p2 = prev2Output else { return [] }
    return db.fetchTrigram(prev2: p2, prev1: p1, reading: state.composedHiragana)
}()
let predictRaw = trigramRaw + bigramRaw.filter { !trigramRaw.contains($0) }
// 以降 candidates 構築は predictRaw を使う（既存の bigramRaw を置換）
let uniquePredictions = predictRaw.filter { !candidates.contains($0) }
candidates.insert(contentsOf: uniquePredictions, at: 0)
let predictCount = uniquePredictions.count

if autoShow && historyCount == 0 && azooKeyCandidates.isEmpty && predictCount == 0 { return .dismiss }
```

**`bigramCount` のリネームを忘れない**: `doRefreshCandidates()` には `bigramCount` を参照する箇所が以下 3 箇所ある（`:445` `:446` `:461`）。すべて `predictCount` に置換する。

```swift
// :445-446
let hiraganaInHistory = candidates.prefix(predictCount + historyCount).contains(hiragana)
let katakanaInHistory = candidates.prefix(predictCount + historyCount).contains(katakana)

// :461
let historyEnd = fixedCount + predictCount + historyCount
```

漏らすと `historyEnd` のセクション境界がずれて、↑↓ キー操作時の履歴/予測セクション判定が壊れる。

#### b. `doSuggestSuccessors()` (`:345`)

```swift
let bigramTop = db.fetchBigramTop(prev: last)
let trigramTop: [String] = prev2Output.map { db.fetchTrigramTop(prev2: $0, prev1: last) } ?? []
let predictTop = trigramTop + bigramTop.filter { !trigramTop.contains($0) }
// 以降 particlesFallback の計算は predictTop を使う
let particlesFallback = isNounLike(last)
    ? InputHandler.particles.filter { !predictTop.contains($0) }
    : []
let candidates = predictTop + particlesFallback
```

#### c. `handleSuccessorMode()` fast-path (`:405`)

```swift
let fromBigram = db.fetchBigramInList(prev: last, list: matched)
let fromTrigram: [String] = prev2Output.map {
    db.fetchTrigramInList(prev2: $0, prev1: last, list: matched)
} ?? []
let merged = fromTrigram + fromBigram.filter { !fromTrigram.contains($0) }
let rest = matched.filter { !merged.contains($0) }
return (true, .show(candidates: merged + rest, historyEnd: 0, initialRow: 0))
```

### 6. リセット規則

現状 `lastCommittedOutput` はどこでもリセットしない（`docs/domain/states.md` の規約どおり）。`committedHistory` も同じ方針：明示リセット無し、確定の都度 push。これにより 3 語連続確定で trigram が正しく学習される（A → B 後に bigram(A,B); A → B → C で bigram(B,C) + trigram(A,B,C)）。

---

## 変更対象ファイル

| ファイル | 内容 |
|---------|------|
| `Sources/DatabaseManager.swift` | trigram テーブル追加（`createTables` 更新）+ 4 関数追加 |
| `Sources/InputHandler.swift` | `committedHistory` への置き換え + 3 read 箇所 + 2 write 箇所の更新 |
| `Tests/DatabaseManagerTests.swift` | bigram テスト群（`:62-106`）と並列の trigram テストを追加 |
| `Tests/InputHandlerTests.swift` | trigram 学習→予測の統合テスト 1 ケース追加 |

設定画面 (`Sources/Settings/`) には今回触らない。`BigramViewController` の `fetchAllBigram` ベースの UI/JSON はそのまま温存。

---

## テスト方針

### DatabaseManager 単体テスト（追加）

`Tests/DatabaseManagerTests.swift` に bigram と並列の以下を追加：

1. `testFetchTrigramTopEmptyDBReturnsEmpty`
2. `testFetchTrigramTopAggregatesByOutput`（同じ output が異なる input で蓄積されたとき count 合算でソート）
3. `testFetchTrigramTopOrderedByCountDesc`
4. `testFetchTrigramTopIsolatedByPrev2Prev1`（prev2 / prev1 が違えば混じらない）
5. `testFetchTrigramByReadingPrefix`（input LIKE 検索の動作）

### InputHandler 統合テスト（追加 1 ケース）

「3 語連続確定で trigram が学習され、4 語目の組成中に trigram 候補が bigram 候補の上に出る」シナリオを追加。`MockTextClient` + `DatabaseManager(inMemory: true)` で動かす。

### 手動検証

`/deploy` でビルド・インストール後（ユーザー実行）、以下を確認：

- 既存 bigram 学習・予測が回帰していない
- 3 語連続確定後、4 語目で trigram 由来の候補が先頭に並ぶ
- prev2 が無い状態（最初の 1〜2 確定）で例外なく動く
- segment モード経由の多語確定で trigram が壊れない

---

## 動作確認手順（end-to-end）

```bash
# 1. ユニットテスト
xcodegen generate
xcodebuild test -scheme keynaco -destination "platform=macOS"

# 2. ビルド + インストール（ユーザーが手動実行）
# /deploy スキルを使用
```

DB は `~/Library/Application Support/keynaco/history.db`。動作確認後に SQLite で `SELECT * FROM trigram ORDER BY count DESC LIMIT 20;` を覗くと学習が走っているか目視できる。

---

## 範囲外（PLAN260420 で言及されているが今回はやらない）

- **LRU クリーンアップ**: 組み合わせ爆発対策。PLAN260420 でも「必要」と書きつつ規模感は未定義。trigram テーブルが肥大化してきたら別タスクで対応。
- **設定画面の Trigram タブ・JSON 入出力**: BigramViewController と並列で作る価値は将来的にあるが、まずは効果検証を優先するため今回はスコープ外。
- **打鍵削減量の計測（PLAN260420 末尾の「統計」タブ）**: 独立した別タスクとして扱う。
