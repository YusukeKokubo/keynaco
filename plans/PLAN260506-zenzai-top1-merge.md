# Zenzai top-1 候補を候補リスト前半に融合

## 背景・目的

Zenzai（ニューラル仮名漢字変換）は左側文脈を考慮して上位候補をリランキングするが、
現在の `buildCandidateList` では bi-gram 予測・履歴の後ろに AzooKey 候補がまとめて並ぶため、
DB に学習履歴がある語では Zenzai の最良推薦が埋もれてしまう。

左側文脈がある場合に限り、Zenzai の top-1 候補をユーザー辞書の直後（bi-gram 予測の手前）に
固定挿入することで、文脈理解を候補選択に直接反映させる。

**`isZenzaiEnabled` の意味**: これはユーザー設定（Zenzai を有効にしているか）を反映するフラグであり、
モデル URL 未取得などで実際のリランキングがフォールバックしている場合でも `true` になる。
プロモートはベストエフォート（「Zenzai の推薦」ではなく「AzooKey 辞書 top-1」）という扱いとし、
コメントでその旨を明記する。

## 目標候補順序（Zenzai 有効 + leftSideContext あり の場合）

```
[ひらがな] [カタカナ]   ← fixedCount（変更なし）
[ユーザー辞書]          ← fixedCount .. fixedEnd（変更なし）
[Zenzai top-1 ★]       ← adjustedFixedEnd-1（Shift+Delete 不可）
[bi-gram/tri-gram 予測]
[高スコア履歴]          ← top-1 が履歴と一致する場合は履歴に残る（後述）
[残り AzooKey 候補]     ← top-1 は除去済み
[低スコア履歴]
```

**履歴セクションとの重複について**: `highHistory` に top-1 と同じ表層が含まれる場合（高スコア学習済み語が Zenzai 1 位と一致するケース）、プロモート行と履歴行に同じ文字列が二重出現する。これは **許容する**（`historySeen` は変更しない）。理由：学習済みの語は履歴セクションに残ることでユーザーの慣れた配置を壊さない。将来必要なら別タスクとして検討する。

**初期フォーカスについて**: `initialRow` は `fixedCount` 基準のまま変更しない（Zenzai top-1 を自動選択にはしない）。初期フォーカスを Zenzai 行にする場合は別タスク。

## 変更ファイルと手順

### Step 1: `AzooKeyConverting` プロトコルに `isZenzaiEnabled` を追加

**ファイル**: `Core/Sources/Core/AzooKeyConverting.swift`

```swift
public protocol AzooKeyConverting: AnyObject, Sendable {
    var isZenzaiEnabled: Bool { get }   // ← 追加
    func requestCandidates(hiragana: String, leftSideContext: String?, richCandidates: Bool) -> [String]
    // ... 既存のまま
}
```

プロトコルの `extension` にデフォルト実装 `var isZenzaiEnabled: Bool { false }` を追加する。
これにより下記の既存モックはコンパイルエラーなしにデフォルト `false` を使用する：

- `MockAzooKeyConverter`（`CoreTests/`）
- `SegmentBoundaryMockAzooKey`（`CoreTests/`）
- `LLMFallbackForcingMockAzooKey`（`CoreTests/`）
- `ScenarioS01KanjiMockConverter` 等（`CoreTests/`）
- `BoundaryPrefLLMMock*` 系（`CoreTests/`）

Step 4 のテスト用モックは `var isZenzaiEnabled: Bool = true` を明示的に宣言して上書きする。

### Step 2: `AzooKeyConverter` に `isZenzaiEnabled` を実装

**ファイル**: `Core/Sources/Core/AzooKeyConverter.swift`

既存の `private let zenzaiEnabled: Bool` を参照してプロパティを公開する。

```swift
// ユーザー設定の Zenzai 有効フラグ（モデルの実際のロード状態は反映しないベストエフォート）
public var isZenzaiEnabled: Bool { zenzaiEnabled }
```

### Step 3: `buildCandidateList` に Zenzai top-1 差し込みロジックを追加

**ファイル**: `Core/Sources/Core/InputHandler+Candidates.swift`

#### 現在のデータフロー（変更前、実コード順）

```
1. azooKeyCandidates = requestCandidates(...)
2. historySeen = Set(historyScored)
3. azooKeyUniq = azooKeyCandidates.filter { !historySeen }
4. candidates = highHistory + azooKeyUniq
5. candidateSeen = historySeen ∪ Set(azooKeyUniq)
6. uniquePredictions = predictRaw.filter { !candidateSeen }
7. candidates.insert(contentsOf: uniquePredictions, at: 0)  // 予測を先頭へ
8. fixedCandidates（カナ）を先頭に insert
9. userDict を fixedCount 位置に insert → fixedEnd = fixedCount + userDictCount
10. historyEnd = fixedEnd + predictCount + highHistoryCount
11. numberCandidates / dateTimeCandidates を historyEnd 位置に insert
12. lowHistory を末尾 append
13. return .show(..., fixedEnd: fixedEnd)
```

#### 変更箇所

`azooKeyUniq` から top-1 を除くだけだと `candidateSeen` に top-1 が含まれなくなり、
**N-gram 予測が同じ表層を返したとき「プロモート行」と「予測ブロック」に同じ語が二重出現する**。
これを防ぐため、`candidateSeen`（予測の重複除去集合）には
**プロモート前の `azooKeyCandidates` 全体から作った集合**を用いる。

```swift
// top-1 プロモート候補の決定（ユーザー設定 ON + 文脈あり のときのみ）
let zenzaiPromoted: String? = {
    guard azooKeyConverter.isZenzaiEnabled,
          azooKeyLeftContext != nil,          // 空文字は azooKeyLeftContext が nil になる
          let top1 = azooKeyCandidates.first else { return nil }
    return top1
}()

// azooKeyUniq: 履歴重複除去 + プロモート済み top-1 を除外
let azooKeyUniq = azooKeyCandidates.filter {
    !historySeen.contains($0) && $0 != zenzaiPromoted
}
var candidates = highHistory + azooKeyUniq

// candidateSeen には azooKeyCandidates 全体（top-1 含む）を使い、
// 予測ブロックへの top-1 の二重掲載を防ぐ
let azooKeyAll = Set(azooKeyCandidates)
let candidateSeen = historySeen.union(azooKeyAll)
let uniquePredictions = predictRaw.filter { !candidateSeen.contains($0) }
let predictCount = uniquePredictions.count
candidates.insert(contentsOf: uniquePredictions, at: 0)
```

`fixedEnd` 計算の直後（ユーザー辞書 insert の後）に top-1 を差し込む：

```swift
// Zenzai top-1 をユーザー辞書の直後に固定挿入（Shift+Delete 不可）
var zenzaiTop1Count = 0
if let top1 = zenzaiPromoted, insertedSet.insert(top1).inserted {
    candidates.insert(top1, at: fixedEnd)
    zenzaiTop1Count = 1
}
let adjustedFixedEnd = fixedEnd + zenzaiTop1Count
```

以降の `fixedEnd` 参照を `adjustedFixedEnd` に置き換える：
- `historyEnd = adjustedFixedEnd + predictCount + highHistoryCount`
- `predictionEnd = adjustedFixedEnd + predictCount`
- `candidates.insert(contentsOf: uniqueNumberCandidates, at: historyEnd)` ← 自動的に正しい位置
- `return .show(..., fixedEnd: adjustedFixedEnd)` ← **戻り値も `adjustedFixedEnd` を渡す**

> **配置の確認**: `uniquePredictions` の insert は上記コード（step 7）で `adjustedFixedEnd` 計算より前に完了している。カナ・ユーザー辞書が既に先頭に並んでいるため、Zenzai top-1 の insert 後に予測の位置調整は不要。

### Step 4: テスト追加

**ファイル**: `Core/Sources/CoreTests/InputHandlerCandidatesTests.swift`

Zenzai 有効な `MockAzooKeyConverter` を用意（`isZenzaiEnabled = true` を上書き）して以下の 5 ケースを追加：

1. **基本プロモート**: `isZenzaiEnabled=true` + `leftSideContext` あり → top-1 が `candidates[adjustedFixedEnd-1]` に入り、`CandidateAction` の `fixedEnd` が +1 されること
2. **Shift+Delete 不可**: プロモートされた top-1 の行インデックス < `adjustedFixedEnd` であること（削除可能範囲外）
3. **辞書ブロックから除去**: AzooKey 辞書ブロック（`historyEnd` 以降）に top-1 と同じ文字列が現れないこと
4. **予測ブロックから除去**: N-gram 予測が top-1 と同じ表層を返したとき、予測ブロック（`fixedEnd`〜`predictionEnd`）にも top-1 が現れないこと（`candidateSeen` が全体を参照することの検証）
5. **無効条件**: `isZenzaiEnabled=false` または `leftSideContext` が `nil`（空文字）のとき、top-1 が固定位置に入らず候補順が変わらないこと

### Step 5: ドキュメント更新

**`CLAUDE.md`**: 「候補表示の優先順位」リストに `[Zenzai top-1]`（ユーザー辞書の直後）行を追加。

**`docs/domain/glossary.md`**: `fixedEnd` の定義に「Zenzai top-1 プロモート時は +1 される」旨を追記。

**`docs/domain/states.md` または `scenarios.md`**: 候補表示の優先順序セクションに `[Zenzai top-1]` 行を追加し、`CLAUDE.md` と内容を揃える。

## 変更の影響範囲

| 項目 | 影響 |
|------|------|
| `CandidateAction.fixedEnd` | Zenzai 有効 + 文脈あり の場合に +1 |
| Shift+Delete | `adjustedFixedEnd <= row < historyEnd` が削除可能範囲。Zenzai top-1 は `adjustedFixedEnd` 未満なので誤削除不可 |
| AzooKey 辞書ブロック | top-1 が除外されるため 1 件減る（重複表示なし） |
| 予測ブロック | top-1 と同じ表層の N-gram 予測は除外される |
| 履歴ブロック | top-1 が高スコア履歴と一致する場合は二重表示を許容（意図的） |
| `initialRow` | 変更なし（Zenzai 行は自動フォーカスしない） |
| `autoShow` 時 | 差し込みロジックは動く（autoShow フラグで制限しない） |
| セグメントモード | `buildCandidateList` を呼ばないため影響なし |
| Successor モード | 同上、影響なし |
| 既存テストのモック | デフォルト `false` のため変更不要 |

## 完了条件

- [ ] `AzooKeyConverting` に `isZenzaiEnabled` が追加され全モックでコンパイル通過
- [ ] `buildCandidateList` が Zenzai 有効 + leftSideContext あり のとき top-1 を `adjustedFixedEnd-1` に挿入する
- [ ] top-1 が辞書ブロック・予測ブロックに重複して現れない
- [ ] `return .show(...)` の `fixedEnd` 引数が `adjustedFixedEnd` になっている
- [ ] 新規テスト 5 件が通る
- [ ] 既存テストが全て通る
- [ ] `CLAUDE.md` + `docs/domain/` の候補順序説明を同コミットで更新する
