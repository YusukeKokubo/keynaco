# カーソル前文を N-gram 予測の仮想文脈として注入

## 背景

LLM・Zenzai 系は既に IMK の `before`（カーソル前テキスト）を文脈として活用している（`InputController+LLM.swift:7-32` の `resolvedLLMDocumentContextPrefix`）。具体的には:

- Zenzai: `handler.leftSideContext` 経由（`InputController.swift:372` / `412`）
- `LLMSuccessorFetcher`: `documentContextPrefix` 引数
- `LLMSegmentConverter`: `azooKeyLeftContext` 経由
- `LLMMisconversionChecker`: `surroundingText(...).prefix` 直接

一方、**N-gram（bi-gram / tri-gram / skip-bigram）・履歴 fetch は IMK `before` を一切見ていない**。
`InputHandler.lastCommittedOutput` / `prev2Output` / `mostRecentContentWords` は `committedHistory` のみを参照する（`InputHandler.swift:127-154`）。

このため次の場面で軽量 N-gram 予測が冷えたまま:

- アプリ起動直後・アプリ切替直後（`committedHistory` 空）
- 既存文書の途中をクリックして追記し始めた時
- Slack スレッド返信・メール返信・対話 UI への追記
- 議事録など、セッションをまたいで続きを書く時

LLM は走るが、確定的で即応性の高い N-gram レイヤがゼロから始まる状態。

## 目標

カーソル前テキストの末尾語を**読み取り専用の仮想 committedHistory** として N-gram 予測経路に注入し、
画面に見えている文脈を IME が即座に活用できるようにする。

## 不変条件（最優先）

| 条件 | 理由 |
|------|------|
| **学習（`recordPrefixes` / `recordNgrams` / `pushCommitted`）には絶対使わない** | 偽 bigram が DB に書き込まれる事故を防ぐ |
| **`committedHistory` が空のときだけフォールバック参照** | 実確定語の信頼度を上書きしない |
| **句読点・改行で切れた直後は注入しない** | `sentenceTerminators` による文脈リセット（A-1）の意図と整合 |
| **`committedHistory` 本体は触らない** | 既存テストと append/removeAll セマンティクスを保つ |

## 設計

### 1. データ構造

`InputHandler` に読み取り専用フィールドを追加:

```swift
/// IMK before テキスト末尾から抽出した仮想末尾語列（最大2語、新しい順ではなく古→新）。
/// 学習経路には絶対に流さない。N-gram fallback の prev1/prev2 計算のみに使う。
public var virtualHistoryPrefix: [String] = []
```

### 2. フォールバック経路

`InputHandler.swift:127-154` の3アクセサを次の方針で変更:

```swift
public var lastCommittedOutput: String? {
    committedHistory.last ?? virtualHistoryPrefix.last
}

public var prev2Output: String? {
    if committedHistory.count >= 2 {
        return committedHistory[committedHistory.count - 2]
    }
    if committedHistory.count == 1 {
        return virtualHistoryPrefix.last
    }
    return virtualHistoryPrefix.count >= 2
        ? virtualHistoryPrefix[virtualHistoryPrefix.count - 2]
        : nil
}

public func mostRecentContentWords(n: Int) -> [String] {
    var result: [String] = []
    let combined = virtualHistoryPrefix + committedHistory
    for i in stride(from: combined.count - 1, through: 0, by: -1) {
        if !InputHandler.particles.contains(combined[i]) {
            result.append(combined[i])
            if result.count >= n { break }
        }
    }
    return result
}
```

### 3. 抽出関数（`InputController` 側、新規ファイル `InputController+VirtualContext.swift`）

```swift
extension InputController {
    /// IMK before テキストの末尾から仮想 prev 1〜2 語を抽出する。
    /// 文末記号で切れた直後は空配列を返す（文脈リセットの意図に合わせる）。
    static func extractVirtualHistory(from before: String) -> [String] {
        let tail = String(before.suffix(30))

        // 文末記号で終わっていれば空。次の文の文脈は無関係。
        if let last = tail.last, "。．！？!?\n".contains(last) { return [] }

        // 直近の文区切り以降だけ見る。
        let lastBreakIdx = tail.lastIndex(where: { "。．！？!?\n".contains($0) })
        let scoped = lastBreakIdx.map { String(tail[tail.index(after: $0)...]) } ?? tail

        // 空白・読点・括弧などで分割し、後ろから 2 トークン拾う。
        let delimiters: Set<Character> = ["、", "，", " ", "\t", "（", "）", "「", "」", "(", ")"]
        var tokens: [String] = []
        var current = ""
        for ch in scoped {
            if delimiters.contains(ch) {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        // 末尾 2 トークンを古→新で返す。
        let last2 = Array(tokens.suffix(2))
        return last2
    }
}
```

**簡易抽出の妥当性**: 形態素解析せず、句読点・空白・括弧での粗分割で十分。N-gram の prev は表層形マッチなので、過剰分割しても hit せず害がないだけで済む。「東京に同行します」の末尾「東京に」がそのまま prev に入っても、`mostRecentContentWords` 内の `particles` フィルタは「に」単体トークンしか見ないため、表層 "東京に" の bi-gram が無ければスキップされる ＝ 安全側に倒れる。

### 4. セット・クリアの hook

`InputController.swift:300-310` 付近の既存ロジックを拡張:

```swift
if handler.state.composedHiragana.isEmpty {
    cachedSurroundingContext = nil
    handler.virtualHistoryPrefix = []
} else if composedHiraganaWasEmpty && !handler.state.composedHiragana.isEmpty {
    if let ctx = SurroundingIMKContext.fetch(from: imkSenderForSurrounding) {
        let loc = adapter.selectedRange().location
        if loc != NSNotFound {
            cachedSurroundingContext = (loc, ctx)
            // committedHistory が空のときだけ意味があるが、毎回セットして問題ない
            // （アクセサが空時のみ参照するので）
            handler.virtualHistoryPrefix = Self.extractVirtualHistory(from: ctx.before)
        }
    }
}
```

加えて、`cachedSurroundingContext` をクリアする既存箇所（`InputController.swift:212` / `297` / `471`）で同時に `handler.virtualHistoryPrefix = []` する。

### 5. 影響範囲

`virtualHistoryPrefix` がフォールバックする経路:

| 呼び出し元 | 効果 |
|-----------|------|
| `InputHandler+SuccessorMode.swift:60` `committedHistory.suffix(3)` | LLMSuccessor の context として送られる。**ここは触らない**（実確定語のみ） |
| `db.fetchTrigramTop(prev2:prev1:)` | virtual の prev1/prev2 でヒットすればトップに昇格 |
| `db.fetchBigramTop(prev:)` | 同上 |
| `mostRecentContentWords(n: 2)` の skip-bigram | 仮想 content word を起点に skip-bigram |
| 格助詞 fallback の `isNounLike(last)` | virtual の末尾が体言なら fallback 助詞が出る |

**`successorLLMContext` には virtual を混ぜない**こと（既に LLM 側は `before` を別経路で受け取っているので二重注入になる）。これは `committedHistory.suffix(3)` のコピーを取る既存実装が自動的に満たす。

### 6. pendingRomaji 先読み（Successor モード前段）

`InputHandler+Candidates.swift:117` 周辺の `buildPendingCandidateList` も `lastCommittedOutput` / `prev2Output` 経由でフォールバックを継承する。
意図せず効くので、リグレッションテストで挙動を固定する。

## テスト計画

`Core/Sources/CoreTests/` 配下に `InputHandlerVirtualContextTests.swift` を追加:

| ケース | 期待 |
|--------|------|
| `committedHistory` 空 + `virtualHistoryPrefix = ["東京"]` で「に」予測が出る | bi-gram fallback 経由でヒット |
| `committedHistory = ["昨日"]` + `virtual = ["東京"]` で `prev2 = "東京"` になる | コンビネーションで tri-gram の prev2 を仮想語が埋める |
| `committedHistory = ["昨日", "は"]` のとき virtual は無視される（2 件以上ある） | 仮想語が実履歴を上書きしないこと |
| `extractVirtualHistory("こんにちは。")` → `[]` | 文末記号後リセット |
| `extractVirtualHistory("昨日は東京に")` → `["は東京に"]` or `["昨日は東京に"]` | 句読点なしは 1 トークン扱い |
| `extractVirtualHistory("昨日、東京に")` → `["東京に"]` | 読点で分割 |
| `extractVirtualHistory("Hello world")` → `["Hello", "world"]` | 空白分割 |
| 学習経路で virtual が `recordNgrams` に流れないこと | DB スパイで bigram テーブルに virtual 由来行が無いことを確認 |

加えて `ScenarioRegressionTests.swift` に 1 ケース追加:

```
1. シナリオ: 「東京は」を確定 → コミット履歴クリア（アプリ切替を模す）
   → before = "東京は" のまま「に」と打鍵
   → Successor モード前段で「に」相当の候補が pendingRomaji 先読みで提示される
```

`MockTextClient` には IMK `before` をモックする経路が必要。`DebugSocketServer.swift:1099`（MockClient の `attributedSubstring`）が既にテスト経路として存在するので、これを参考に `InputHandlerTestCase` に最小限のフックを足す（あるいは `virtualHistoryPrefix` を直接セットしてテストする — こちらの方が簡単）。

## ロールアウト・観測

- 設定画面に `UserDefaults` フラグ `virtualHistoryEnabled`（デフォルト true）を追加。問題が出たら無効化できる導線
- `EventViewerWindow` のスナップショットに `virtualHistoryPrefix` の値を表示する DEBUG ログを追加すると、効いている場面の体感が確認しやすい

## 期待効果

- アプリ切替・カーソル移動直後の 1 文目から bi-gram / tri-gram / skip-bigram 予測が立つ
- Successor モードの格助詞 fallback も仮想前文が体言なら発火
- Apple Intelligence 無効デバイスでも文脈活用が効く
- 既存の Zenzai / LLM 経路には一切影響しない（独立した経路）

## 規模・優先度

| 項目 | 評価 |
|------|------|
| 実装規模 | 半日〜1日（抽出関数 + アクセサ修正 + テスト 5〜8 本） |
| リスク | 低（フォールバックのみ・学習経路非干渉・フラグで無効化可能） |
| 期待効果 | 中〜高（毎日のアプリ切替・返信フロー全般に効く） |
| 依存 | なし（既存の `cachedSurroundingContext` を再利用するだけ） |

## 着手前の確認事項

1. `MockTextClient` から IMK `before` を渡せるか（テストフィージビリティ）
2. `successorLLMContext` への virtual 注入が起きないことを再確認（既存コードの `committedHistory.suffix(3)` コピー位置）
3. `InputHandler` のフィールド追加が `@MainActor` / Sendable 制約に抵触しないか（`String` のみなので問題ないはず）
