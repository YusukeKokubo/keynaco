# LLM変換結果からセグメント境界を逆算する

作成: 2026-05-03  
更新: 2026-05-03（レビュー反映）

## 目的

`LLMSegmentConverter` が返した変換テキスト（例: `"機械学習をする"`）を、
元のひらがな読み（例: `"きかいがくしゅうをする"`）にアライメントし、
AzooKey の初期境界よりも良い文節境界を自動で適用する。

現状は LLM 結果を `segments[0].candidates[0]` に全文テキストとして挿入するだけで、
境界自体は変えていない。本改修では境界そのものを LLM 結果ベースで再構築する。

---

## 方針

### アライメントアルゴリズム（`inferSegmentBoundaries`）

入力: `hiragana: String`（読み全体）、`llmText: String`（LLM変換結果）  
出力: `[(reading: String, token: String)]?`（各セグメントの読みと変換テキストのペア。失敗時 `nil`）

#### ステップ 1: LLM 出力をトークン列に分割

文字種の境界でトークンに区切る（同一文字種の連続を 1 トークン）。  
ただし **漢字とカタカナは別トークンとして分ける**（混在は稀だが読みが異なるため）。

文字種の定義:
- 漢字: `\u{4E00}`–`\u{9FFF}` + CJK 拡張 + CJK 互換
- カタカナ: `\u{30A0}`–`\u{30FF}`
- ひらがな: `\u{3040}`–`\u{309F}`
- ASCII・記号: その他

前処理: `llmText` 先頭・末尾の空白、LLM が付加しがちな句読点（`。、．，` など）を除去してからトークン化する。

例: `"機械学習をする"` → `["機械学習", "を", "する"]`

#### ステップ 2: 各トークンの読み長さを決定

**ひらがなトークン**: 読みと直接対応するため `token.count` 文字を読みから消費。  
LLM が表記を変えて読み文字数がずれた場合は即 `nil`（strict 対応が前提）。

**漢字・カタカナトークン**: **最短一致（shortest match）** を採用する。  
残り読みの先頭 1 文字から順に試し、`candidatesForSegment(reading:)` の返す候補列に
`token` と**完全一致**（`candidates.contains { $0 == token }`）する最初の長さで確定する。

最短一致を選ぶ根拠: AzooKey の `candidatesForSegment` は「その読みで変換できる先頭候補群」を返す。
より短い読みでその表記が候補に出た場合、それが正しい最小単位の読みである。
読みを余分に伸ばすと次のトークンが読みを持てなくなる（greedy なので長く取るとずれる）。

#### ステップ 3: Greedy left-to-right で読みを全消費

全トークンを処理し終えたとき `remaining` が空なら **成功**。
残りがあれば **失敗 → `nil`** を返す。

#### ステップ 4: 漢字・カタカナで候補が見つからない場合の fallback

`candidatesForSegment` が 1〜N 文字すべての試行で完全一致しない場合:

```
# 例: token = "ABC社"（候補に存在しない固有名詞）
# remaining = "えびーしーしゃのきむら"

# fallback: token に対応する最長の読みプレフィックスを既存 azooKey セグメント境界から探す
# （候補一致なしは「辞書にない語」= AzooKey が分割した境界の 1 セグメント読みを流用）
# 見つからなければ nil（全体フォールバック）
```

具体的には:
1. 最後の `azooKeyConverter.segmentize` 結果（`enterSegmentMode` 時点のキャッシュ）を参照
2. 現在の `remaining` 先頭から始まる最初のセグメントの読みを取得し、それを消費
3. そのセグメントに対応する `token` のプレフィックスを候補として採用
4. トークン文字数と読み文字数が想定外にずれた場合は `nil`

> 注: `enterSegmentMode` が行う `segmentize` 結果を `SegmentState` か `InputHandler` に保持しておく必要がある。
> 現状は `segments.map(\.reading)` として間接的に残っているので、これを利用する。

### 境界確定後の処理（`applyLLMBoundaries`）

アライメント成功時:
- 推定ペア（例: `[("きかいがくしゅう","機械学習"), ("を","を"), ("する","する")]`）をもとに `buildSegmentCandidates` を再実行
- **`prev` の渡し方**: セグメント `i` の `prev` には「セグメント `i-1` の LLM トークン（`pairs[i-1].token`）」を渡す。これが LLM の文脈に最も近い bi-gram キーとなる。セグメント `0` の `prev` は既存の `lastCommittedOutput` を使用
- 各セグメントの `candidates` 先頭に対応する LLM トークンを挿入
- `SegmentState.segments` を新しいセグメント列で置き換え
- `llmWholeText` を設定（Enter 一発確定の shortcut を維持）
- `focusedIndex = 0`、`isManuallyAdjusted = false`（境界学習は Enter 確定時のみ）

アライメント失敗時:
- 現状の `applyLLMSegmentResult` の挙動（全文を `segments[0].candidates[0]` に挿入）にフォールバック

---

## 変更ファイルと責務

### 1. `Sources/LLMSegmentConverter.swift`（修正）

```swift
// 新規追加
static func inferSegmentBoundaries(
    hiragana: String,
    llmText: String,
    azooKey: AzooKeyConverting
) -> [(reading: String, token: String)]?
```

- 純粋関数。`AzooKeyConverting` を DI で受け取り `candidatesForSegment` を呼ぶ
- テスト可能にするため `static` かつ `AzooKeyConverting` プロトコル依存

### 1b. `Tests/SegmentBoundaryTests.swift`（新規）

ステップ 1 完了直後に追加し、`inferSegmentBoundaries` を単体で検証する。

| ケース | 読み | LLM出力 | 期待境界（reading 列） |
|--------|------|---------|----------------------|
| 複合語 | きかいがくしゅう | 機械学習 | `["きかいがくしゅう"]` |
| 助詞あり | きかいがくしゅうをする | 機械学習をする | `["きかいがくしゅう","を","する"]` |
| カタカナ語 | じゅうどう | 柔道 | `["じゅうどう"]` |
| アライメント失敗（文字数不一致） | きょうはいい | 今日はいい天気 | `nil` |
| AzooKey と同じ境界 | きょうは | 今日は | `["きょう","は"]` |
| ひらがな読みずれ（LLM 表記変更） | おかあさん | お母さん | `["お","かあ","さん"]` or `nil`（辞書依存） |

### 2. `Sources/InputHandler+SegmentMode.swift`（修正）

既存 `applyLLMSegmentResult` を以下のように拡張:

```swift
mutating func applyLLMSegmentResult(text: String) {
    // 1. inferSegmentBoundaries を呼ぶ
    // 2. 成功 → applyLLMBoundaries(pairs:)
    // 3. 失敗 → 従来の全文挿入 fallback
}

// 新規追加（private）
private mutating func applyLLMBoundaries(
    pairs: [(reading: String, token: String)],
    fullReading: String
)
```

### 3. regression 確認

既存の `InputHandlerSegmentTests.swift`（存在すれば）と `xcodebuild test` 全体で確認。

---

## 境界アライメントの詳細ロジック（擬似コード）

```
tokenize("機械学習をする") → ["機械学習", "を", "する"]

remaining = "きかいがくしゅうをする"
result = []

token = "機械学習"（漢字）
  try len=1: candidatesForSegment("き").contains { $0 == "機械学習" }? No
  try len=2: candidatesForSegment("きか").contains { $0 == "機械学習" }? No
  ...
  try len=6: candidatesForSegment("きかいがくしゅう").contains { $0 == "機械学習" }? Yes
  → reading = "きかいがくしゅう"
  remaining = "をする", result = [("きかいがくしゅう","機械学習")]

token = "を"（ひらがな）
  reading = "を"（直接消費）
  remaining = "する", result = [..., ("を","を")]

token = "する"（ひらがな）
  reading = "する"
  remaining = "", result = [..., ("する","する")]

全消費 → 成功
```

`inferSegmentBoundaries` 内では `AzooKeyConverting.candidatesForSegment(reading:)` のみを呼ぶ（`InputHandler.segmentCandidateCache` は参照しない）。
境界再構築後は `applyLLMBoundaries` が `segmentCandidateCache.removeAll()` し、以降の `buildSegmentCandidatesCached` が旧読みキーを誤って再利用しないようにする。

---

## 考慮事項・リスク

| 項目 | 対策 |
|------|------|
| LLM が句読点を追加/変更する | トークン化前に句読点を除去。除去後も文字数ずれがあれば `nil` で fallback |
| 漢字連続中に LLM がスペースを挿入する | 前処理で半角・全角スペースを除去してからトークン化 |
| `candidatesForSegment` が遅い | `segmentCandidateCache` を活用。LLM 応答後の非同期処理なので UX をブロックしない |
| LLM が誤変換する | アライメント成功でも誤変換の場合はユーザーが ↑↓ で別候補を選ぶ。現状と同等 |
| 境界の自動変更に気づかない | `applySegmentMarkedText` で marked text が即更新されるため視覚フィードバックあり |
| 1 セグメント入力（境界変化なし） | `pairs.count == 1` でも LLM トークンを `candidates[0]` 先頭に挿入して `llmWholeText` をセット |
| カタカナ語が辞書に弱い | fallback（既存 AzooKey セグメント境界を流用）で最低限吸収。fallback も失敗なら `nil` |
| ひらがなトークンで LLM が表記変更（例: `おかあさん` → `お母さん` の "`か`ア" ずれ） | 読み文字数が一致しない時点で即 `nil`。strict 対応は意図どおり |

---

## ドキュメント更新（`docs/domain/`）

本改修は「セグメントモードに入った直後に LLM 結果で境界が自動変更される」という
新しい状態遷移を加える。リリース時に以下を確認・更新すること（コードと同じコミット）:

- `docs/domain/states.md`: セグメントモード進入後の LLM 結果適用タイミングの記述
- `docs/domain/scenarios.md`: アライメント成功 / 失敗それぞれの入力トレース例

---

## 完了条件

- `inferSegmentBoundaries` が上記テストケースをすべてパス（`nil` ケースも含む）
- 「きかいがくしゅうをする」→ Space → LLM 結果到着後に "機械学習 / を / する" の 3 文節として表示される
- LLM 未応答・アライメント失敗時は現状の AzooKey 境界のまま（regression なし）
- `xcodebuild test` がグリーン
- `docs/domain/` の該当箇所を同コミットで更新
