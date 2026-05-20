# Successor 候補を表層上で prefix 分割する

[IDEA260520.md](../ideas/IDEA260520.md) の実装計画。

## ゴール

Successor サジェストで「名詞＋述語」のような長い表層が 1 候補として出るとき、**名詞部分だけを別候補として並べて** ユーザーが部分採用できるようにする。元の全体候補も保持して「全部欲しい」ケースは潰さない。

## 背景の制約（重要）

Successor の候補は **「表層形のみ」** で扱われる:

- `LLMSuccessorFetcher` は表層 String を返す（読み情報なし）
- `pendingSuccessorCandidates` は表層 String 配列
- `db.fetchBigramTop` 等の N-gram も output 表層を返す（reading は別カラムだが prefix 取得では使われていない）

一方 `AzooKeyConverter.segmentize(_:leftSideContext:)` は **読み (hiragana) を受け取って** 文節分割する API のため、表層しか手元にない Successor 候補には**直接使えない**。

→ 形態素解析を持ち込まず、**助詞境界ヒューリスティック**で表層上の prefix を作る方針にする。これは Successor の用途（"名詞だけ欲しい"）に十分マッチする。

## 不変条件

| 条件 | 理由 |
|------|------|
| 元の全体候補は必ず最後に残す | "述語まで全部" 採用パスを潰さない |
| 助詞単独 prefix（"会議に" → "に" だけ）は生成しない | 意味のない部分採用を避ける |
| 助詞末尾 prefix（"会議に"）は採用するが「体言で終わる prefix」優先で並べる | 体言で切るのが多くの実用ケース |
| `successorMaxCandidates = 5` の枠を絶対超えない | UI 上の表示性能と一覧性 |
| 同一の親フレーズから生成する prefix は最大 2 個 | 1 つの長い候補が枠を独占しない |
| 1 文字（記号・ひらがな1字含む）の表層は分割しない | 早期 return |

## 設計

### 1. 助詞境界スプリッタ（純粋関数・テスト容易）

`Core/Sources/Core/InputHandler+SuccessorMode.swift` に追加:

```swift
/// 表層文字列を「助詞境界」で分割した prefix 候補列を返す（元の文字列は含めない）。
/// 例: "会議に出席する" → ["会議", "会議に"]
/// 例: "予定です"       → []   （助詞境界なし）
/// 例: "東京から大阪へ" → ["東京", "東京から", "東京から大阪", "東京から大阪へ"]
///
/// ルール:
/// - `InputHandler.particles` に含まれる助詞表層を境界として検出
/// - 多文字助詞（"から"/"まで"/"より"）を優先マッチ（最長一致）
/// - 助詞の**直前**で切った prefix（体言切り）と、助詞の**直後**で切った prefix（助詞末尾切り）を両方候補化
/// - 助詞単独で始まる prefix は生成しない（先頭が助詞のときはその助詞境界をスキップ）
/// - 重複と元の文字列と空文字列は除外
nonisolated static func splitSurfaceAtParticles(_ surface: String) -> [String] {
    guard surface.count >= 2 else { return [] }
    // 長い助詞から順に並べる（最長一致用）
    let sortedParticles = particles.sorted { $0.count > $1.count }
    var out: [String] = []
    var seen: Set<String> = []
    var idx = surface.startIndex
    while idx < surface.endIndex {
        // 先頭からの距離が 0 なら助詞境界としても prefix が空になるのでスキップ
        var matchedLen = 0
        for p in sortedParticles {
            if surface[idx...].hasPrefix(p) { matchedLen = p.count; break }
        }
        if matchedLen > 0 {
            // 体言切り prefix（助詞直前まで）
            let beforePrefix = String(surface[..<idx])
            if !beforePrefix.isEmpty, beforePrefix != surface, seen.insert(beforePrefix).inserted {
                out.append(beforePrefix)
            }
            // 助詞末尾切り prefix（助詞含む）
            let afterIdx = surface.index(idx, offsetBy: matchedLen)
            let withParticle = String(surface[..<afterIdx])
            if withParticle != surface, seen.insert(withParticle).inserted {
                out.append(withParticle)
            }
            idx = afterIdx
        } else {
            idx = surface.index(after: idx)
        }
    }
    return out
}
```

`particles` 静的リストは既に [`InputHandler.swift:93`](../Core/Sources/Core/InputHandler.swift) に存在: `["が", "を", "に", "で", "へ", "と", "から", "まで", "より", "の", "は", "も"]`。これをそのまま使う。

### 2. 並び順ポリシー（純粋関数）

```swift
/// 親フレーズ毎に最大 maxPerParent 個の prefix だけ採用し、元の親の直前に挿入する。
/// 体言切り（助詞を含まない）を優先する。
nonisolated static func expandSuccessorPrefixes(
    candidates: [String],
    maxPerParent: Int = 2,
    totalLimit: Int = LearningThresholds.successorMaxCandidates
) -> [String] {
    var out: [String] = []
    var seen: Set<String> = []
    for c in candidates {
        let prefixes = splitSurfaceAtParticles(c)
        // 体言切り（particles で終わらないもの）を先に
        let nounEnd = prefixes.filter { p in !InputHandler.particles.contains(where: { p.hasSuffix($0) }) }
        let particleEnd = prefixes.filter { p in InputHandler.particles.contains(where: { p.hasSuffix($0) }) }
        var picked: [String] = []
        for p in (nounEnd + particleEnd) {
            if picked.count >= maxPerParent { break }
            if seen.contains(p) { continue }
            picked.append(p)
            seen.insert(p)
        }
        for p in picked { out.append(p) }
        if seen.insert(c).inserted { out.append(c) }
        if out.count >= totalLimit { break }
    }
    return Array(out.prefix(totalLimit))
}
```

### 3. 適用箇所

[`InputHandler+SuccessorMode.swift:163-174`](../Core/Sources/Core/InputHandler+SuccessorMode.swift)（`handleSuccessorMode` の `.default` ケース内、`merged` を組み立てて `.show` に渡す直前）に挿入:

```swift
// 既存
var merged = filtered
var mergeSeen = Set(filtered)
for w in successorLLMSurfaceExtras where mergeSeen.insert(w).inserted {
    merged.append(w)
}
// 追加: prefix 展開
let expanded = InputHandler.expandSuccessorPrefixes(candidates: merged)
// 後続の `Array(merged.prefix(...))` を `expanded` に置換
return (true, .show(candidates: expanded,
                    historyEnd: 0, initialRow: 0, predictionEnd: 0, fixedEnd: 0))
```

`pendingSuccessorCandidates = []` のクリア等は既存通り維持。

### 4. 確定経路の挙動

`confirmSuccessor(_ particle: String, client:)` ([`+SuccessorMode.swift:67`](../Core/Sources/Core/InputHandler+SuccessorMode.swift)) はそのまま使える:

- ユーザーが prefix 版（"会議"）を選んだら、その文字列で bi-gram / prefixes が記録される → 次回 "会議" が単独で出やすくなる（望ましい挙動）
- ユーザーが親（"会議に出席する"）を選んだら従来通り

**追加対応不要**。既存のパスが文字列単位で動くので prefix だろうが親だろうが透過に扱える。

### 5. 1打目フィルタとの相互作用

[`+SuccessorMode.swift:135-156`](../Core/Sources/Core/InputHandler+SuccessorMode.swift) の1打目フィルタは「読み先頭の `kana` で前方一致するかどうか」を見ている。prefix は親の先頭文字を共有するので:

- 親が読みフィルタを通れば、その prefix も同じ先頭文字を共有 → 通る
- 親が通らなければ prefix も通らない（無関係なものは出ない）

→ **既存フィルタの後段で prefix 展開すれば矛盾しない**。設計上、`filtered` + `successorLLMSurfaceExtras` を merge した後に `expandSuccessorPrefixes` をかける順序が正しい。

### 6. N-gram 由来候補にも適用

`merged` には:
- 1打目フィルタを通った N-gram 候補（`filtered`）
- LLM 由来の `successorLLMSurfaceExtras`

両方が含まれる。`expandSuccessorPrefixes` を全体にかければ、過去に学習してしまった「予定です」のような複合 bi-gram も自然に救済される（["予定", "予定です"] になる）。

## テスト計画

新規ファイル `Core/Sources/CoreTests/InputHandlerSuccessorPrefixTests.swift`:

| ケース | 期待出力 |
|--------|---------|
| `splitSurfaceAtParticles("会議に出席する")` | `["会議", "会議に"]` |
| `splitSurfaceAtParticles("予定です")` | `[]`（助詞なし） |
| `splitSurfaceAtParticles("東京から大阪へ")` | `["東京", "東京から", "東京から大阪", "東京から大阪へ"]`（"から" を最長一致） |
| `splitSurfaceAtParticles("にこにこ")` | `[]`（先頭助詞は境界として無視） |
| `splitSurfaceAtParticles("私は")` | `["私"]`（助詞末尾の `"私は"` は元と等しいので除外） |
| `splitSurfaceAtParticles("お")` | `[]`（1文字） |
| `expandSuccessorPrefixes(["会議に出席する", "予定です"])` | `["会議", "会議に", "会議に出席する", "予定です"]`（体言切り優先） |
| `expandSuccessorPrefixes([...], maxPerParent: 1)` | 親 1 つあたり 1 prefix のみ |
| 重複親と重複 prefix の除去 | seen で潰される |
| 5 枠超過時の打ち切り | totalLimit が効いている |

`ScenarioRegressionTests.swift` に E2E 1 ケース追加: 「`successorLLMSurfaceExtras` に "会議に出席する" を直接セットし、1打目 "k" で `["会議", "会議に", "会議に出席する"]` が出る」シナリオ。

`/keynaco-ime-sandbox` で実機確認すべきケース:
- 「予定です」が既に bi-gram にあるユーザーで、Successor から prev → ["予定", "予定です"] の順で出るか
- LLM が「会議に出席する」を返したケース（プロンプト依存なので Apple Intelligence 有効環境で観察）

## 影響範囲・既存テストへの影響

- `InputHandlerSuccessorTests.swift`: prefix 展開で候補配列が変わるケースが出るので **既存期待値の更新が必要**。特に「Successor で `["A", "B"]` が出る」系のテストが、prefix が増えて `["a-prefix", "A", "B"]` に変わるケース
- `ScenarioRegressionTests.swift`: Successor を経由するシナリオの期待出力を再確認
- `EventViewerWindow` / `IMESandboxWindow`: 表示のみで挙動には影響なし

## ロールアウト

`LearningThresholds.swift` に `successorPrefixSplitEnabled: Bool = true` 相当のフラグを置く案もあるが、退行リスクが低く効果が大きい変更なのでフラグなしで投入してよい。問題が出たら revert する。

## 規模・優先度

| 項目 | 評価 |
|------|------|
| 実装規模 | 0.5〜1 日（純粋関数 2 個 + 適用箇所 1 行 + テスト 10 本程度） |
| リスク | 低（純粋関数追加と1点挿入のみ。既存ロジックは無改変） |
| 期待効果 | 高（毎日の体感に直結。"名詞だけ採用"が即可能になる） |
| 依存 | なし |

## 着手前の確認事項

1. `InputHandlerSuccessorTests.swift` の既存ケースのうち、prefix 展開で候補が増えるものをリストアップ（事前に grep で `"会議に|に出席|から|まで|より|です|ます"` 等を含むテストデータを把握しておく）
2. `successorMaxCandidates = 5` の体感: prefix が増えると上位の bi-gram 上位が押し出される可能性。`maxPerParent = 2` で問題ないか実機サンドボックスで確認
3. 「私は」のように助詞で終わる 2 文字親フレーズが prefix 展開で「私」だけになるケース、ユーザーが期待するか（直感的にはむしろ嬉しいはず）
