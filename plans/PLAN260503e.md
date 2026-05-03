# LLM 境界推定結果を boundary_pref に自動保存する

作成: 2026-05-03

## 目的

`inferSegmentBoundaries` が成功して境界を再構築した場合、ユーザーが手動調整なしに
確定したとき `boundary_pref` に自動保存する。

現状の保存条件は `isManuallyAdjusted = true` のみ。LLM が正しい境界を推論しても
それは学習されず、次回も LLM の応答を待つ必要がある。本改修後は：

```
1回目: LLM が境界推定 → 確定 → boundary_pref に保存
2回目: boundary_pref から即時境界適用（LLM 待ちなし）
```

---

## 変更方針

### 1. `SegmentState` に `isLlmBoundaryInferred` フラグを追加

```swift
// Sources/CompositionState.swift
struct SegmentState {
    var isLlmBoundaryInferred: Bool = false  // 追加
    // ...
}
```

`applyLLMBoundaries`（`InputHandler+SegmentMode.swift`）内で
`pairs.count >= 2` のとき `newState.isLlmBoundaryInferred = true` にセット。
`pairs.count == 1` のときは `applyLLMBoundaries` を経るが **`isLlmBoundaryInferred` は false のまま**（多文節再構築ではないため `boundary_pref` には保存しない）。
推論失敗で旧パス（先頭文節への全文挿入のみ）に落ちた場合も `false` のまま。

フラグが必要な理由：`llmWholeText != nil` だけでは「LLM が境界を再構築したか」と
「LLM が全文をフォールバック挿入しただけか」が区別できない。

### 2. `doConfirmSegments` の保存条件を拡張

現状の保存トリガー（`isManuallyAdjusted`）に、LLM 境界推定成功を追加する。

#### パス A: LLM 全文ショートカット（Enter 一発確定）

```swift
// 変更前
if let llmText = segmentState.llmWholeText,
   isLlmWholeTextShortcut(...) {
    // ... recordPrefixes / commitText
    // saveBoundaryPref なし ← ここを追加
}

// 変更後
if let llmText = segmentState.llmWholeText,
   isLlmWholeTextShortcut(...) {
    let fullReading = segmentState.segments.map(\.reading).joined()
    // ▼ state.segmentState = nil より前に呼ぶこと（nil 後は segments にアクセスできない）
    if segmentState.isLlmBoundaryInferred {
        db.saveBoundaryPref(fullReading: fullReading,
                            segments: segmentState.segments.map(\.reading))
    }
    state.segmentState = nil  // saveBoundaryPref はこの行より前
    // ... recordPrefixes / commitText（既存）
}
```

条件: `isLlmBoundaryInferred`（= `inferSegmentBoundaries` が **2 ペア以上**を返し `applyLLMBoundaries` が実行されたとき。1 ペアのみの成功では false）。

#### パス B: 通常確定（セグメントを個別に確定）

```swift
// 変更前
if segs.contains(where: { $0.isManuallyAdjusted }) {
    db.saveBoundaryPref(...)
}

// 変更後
if segs.contains(where: { $0.isManuallyAdjusted }) || segmentState.isLlmBoundaryInferred {
    db.saveBoundaryPref(fullReading: fullReading, segments: segs.map { $0.reading })
}
```

`isManuallyAdjusted` が true の場合も引き続き保存（手動調整が LLM 境界を上書きする）。

---

## 保存されるケースの整理

| 状況 | 保存? | 保存される境界 |
|------|-------|--------------|
| LLM 境界推定成功 + Enter 一発確定 | ✅ | LLM 推定境界 |
| LLM 境界推定成功 + セグメントを個別確定（調整なし） | ✅ | LLM 推定境界 |
| LLM 境界推定成功 + Shift+矢印で手動調整して確定 | ✅ | 手動調整後の境界（LLM 境界を上書き） |
| LLM フォールバック（推論失敗・1 文節挿入のみ） | ❌ | 保存しない |
| LLM 1 ペア成功（`inferSegmentBoundaries` が 1 文節のみで整合、`applyLLMBoundaries` 経由だが多文節ではない） | ❌ | 保存しない |
| LLM 応答なし（AzooKey 境界のまま確定） | ❌ | 保存しない（既存と同じ） |
| 手動 Shift+矢印調整（既存動作） | ✅ | 手動調整境界（既存と同じ） |

---

## 変更ファイル

### `Sources/CompositionState.swift`（軽微）
- `SegmentState` に `isLlmBoundaryInferred: Bool = false` を追加

### `Sources/InputHandler+SegmentMode.swift`（主要変更）
- `applyLLMBoundaries`: `newState.isLlmBoundaryInferred = (pairs.count >= 2)` をセット
- `doConfirmSegments` パス A（LLM ショートカット）: `saveBoundaryPref` 呼び出しを追加
- `doConfirmSegments` パス B（通常確定）: 保存条件に `|| segmentState.isLlmBoundaryInferred` を追加

### `Tests/InputHandlerSegmentTests.swift`（既存ファイルに追加）

| テストケース | 確認内容 |
|-------------|---------|
| LLM 推定境界 + Enter 一発確定 → `fetchBoundaryPref` で保存を確認 | パス A |
| LLM 推定境界 + 通常確定（フォーカス移動なし） → 同上 | パス B |
| LLM 推定境界 + 手動調整して確定 → 同上（手動境界で上書き） | パス B |
| LLM フォールバック（1 文節）+ 確定 → 保存なし | パス A/B |
| LLM なし（AzooKey 境界）+ 確定 → 保存なし | パス B |

テストは **`DatabaseManager(inMemory: true)`** をそのまま使い、確定後に **`handler.db.fetchBoundaryPref(fullReading:)`** で保存の有無・復元される読み配列を検証する（既存の `testBoundaryPrefSavedOnManualAdjust` 等と同じ方針）。`DatabaseManager` は **`final`** のためサブクラス化した `MockDatabaseManager` は使わない。

**読みの長さ**: `saveBoundaryPref` は `fullReading.count >= 4` のガードがある。境界テストで **ちょうど 4 文字**（例: 「きょうは」）を避け、**5 文字以上**（例: 「きょうはいい」＋対応するローマ字入力とスタブの `segmentize`）を推奨する。フォールバック非保存テストは 7 文字程度の読みで問題ない。

---

## `fetchBoundaryPref` のプレフィックス一致による波及効果

`fetchBoundaryPref` は `WHERE ? LIKE full_reading || '%'` で前方一致検索する。

```sql
-- 保存: full_reading = "きかいがくしゅうをする"
-- 次回 "きかいがくしゅうをすること" を入力した場合もヒットする
```

つまり LLM 境界を 1 回保存すると、その読みを**プレフィックスに含む長い読み**にも
境界が再利用される。副作用として不適切な境界が適用される可能性があるが、
`saveBoundaryPref` の `fullReading.count >= 4` ガードと GC（180日・count=1）が
品質を担保する。

---

## 実装手順

1. `CompositionState.swift` に `isLlmBoundaryInferred` を追加
2. `applyLLMBoundaries` でフラグをセット
3. `doConfirmSegments` パス A・B の保存条件を修正
4. テストを追加・実行

---

## 完了条件

- LLM 境界推定成功 + 確定で `boundary_pref` に保存される
- フォールバック・LLM なしの確定では保存されない（既存動作を維持）
- 保存後、同じ読みを再入力したとき `boundary_pref` から境界が即時適用される
- `xcodebuild test` がグリーン
