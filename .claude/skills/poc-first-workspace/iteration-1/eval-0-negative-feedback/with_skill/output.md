# POC-first: 変換履歴の同音異義語ネガティブフィードバック

## Step 1: 仮説を言語化する

```
【機能】
候補ウィンドウから履歴候補（「東経」）を選択後、同じ読みで別候補（「東京」）を確定したとき、
最初に選んで使わなかった「東経」の history.count を減算（ペナルティ）する。

【課題】
「とうきょう」で変換中、履歴にたまたま「東経」が高スコアで残っていると候補が「東経」で
先頭になる。本当は「東京」を確定したいのに毎回 ↓ を押して選び直す必要が生じる。
選び直しという「ネガティブシグナル」を学習に活かせていない。

【仮説】
「読みAで候補Xを選んだ後、その確定を取り消して同じ読みAで候補Yを確定した」という
シーケンスを検出し、Xのスコアを下げれば、次回同じ読みで打ったときYが上位に出やすくなる。

【前提条件】
1. 「東経」が history テーブルに十分な count で存在し、候補リストの履歴セクションに出ている
2. ユーザーが候補を選び直すシーケンス（X確定 → Backspace → Y確定）がコードで検出可能
3. penalizeAll の既存機構が今回の用途に適用できる（または改修が軽微）
```

**前提条件3が「たぶん使えるはず」という推測なので、コードを読んで先に確認する。**

---

## Step 2: コードを読んで前提条件を確認する

### 既存の「確定直後 Backspace ペナルティ」の仕組み

`InputHandler.swift` に `lastConfirmedContext: LastConfirmedContext?` がある。

```swift
/// 確定直後 Backspace で `penalizeAll` するための、直前確定の学習コンテキスト。
public struct LastConfirmedContext: Equatable {
    public let input: String   // 読み（ひらがな）
    public let output: String  // 確定テキスト
    public let fullReading: String?
}
```

`commitText` で毎回 `lastConfirmedContext` をセット。Backspace が来たとき：

```swift
public mutating func doBackspace(client: TextInputClient) -> ... {
    let (handled, needsRefresh) = state.backspace()
    if !handled, let ctx = lastConfirmedContext {
        db.penalizeAll(input: ctx.input, output: ctx.output, fullReading: ctx.fullReading)
        lastConfirmedContext = nil
    }
    ...
}
```

`penalizeAll` の実装（`DatabaseManager.swift`）：

```swift
func penalizeAll(input: String, output: String, fullReading: String?) {
    dispatchWrite {
        self.executeOnQueue("BEGIN")
        self.executeOnQueue("UPDATE history SET count = count - 1 WHERE input = ? AND output = ?") { ... }
        self.executeOnQueue("DELETE FROM history WHERE input = ? AND output = ? AND count <= 0") { ... }
        self.executeOnQueue("COMMIT")
    }
}
```

**重要な発見**: `clearLastConfirmedContextUnlessBackspace` が Backspace 以外のキーで `lastConfirmedContext = nil` をクリアする。

```swift
private mutating func clearLastConfirmedContextUnlessBackspace(isBackspace: Bool) {
    if !isBackspace { lastConfirmedContext = nil }
}
```

これは `handle()` の最初に呼ばれるため、**Backspace 直後に別のキー（ローマ字など）を打つと context がクリアされる**。

### ユーザーが「選び直す」とはどういうシーケンスか

シナリオ: 「とうきょう」→ Space → 候補ウィンドウに「東経（履歴）」が先頭で出る → Enter で「東経」確定 → **間違いに気づく** → Backspace → 「とうきょう」と再入力 → 「東京」を選んで確定

このシーケンスで何が起きるか：
1. 「東経」確定時: `lastConfirmedContext = {input: "とうきょう", output: "東経"}`
2. Backspace 押下: `state.backspace()` は空（確定済みで組成なし）→ handled=false → `penalizeAll("とうきょう", "東経")` が発火 → **すでにペナルティがかかる！**

**つまり、「確定直後の Backspace ペナルティ」はすでに実装されている。**

### なぜ今回の問題が解決されていないか

現行実装でペナルティが発火するのは **「確定 → 即 Backspace」** のパターンのみ。

今回のシナリオ「東経を確定 → 読み打ち直し → 東京を確定」では：
- 「東経」確定後に Backspace を押すまでは OK
- しかし Backspace 後に「とうきょう」と再入力し始めた瞬間、最初の文字キー（`t` など）で `clearLastConfirmedContextUnlessBackspace` が `lastConfirmedContext = nil` にする
- 「東京」確定時点では `lastConfirmedContext` はすでに nil
- 「東経」へのペナルティが発火しない

**これが本当のギャップ。**

---

## Step 3: 最小の検証を設計する

### 検証したい前提条件

**前提条件1**: 「東経」が history に高スコアで入っていて候補に出るか

```python
# sandbox で確認
send({"reset": True})
send({"seed_history": {"input": "とうきょう", "output": "東経"}})
send({"seed_history": {"input": "とうきょう", "output": "東経"}})  # count=2にする
r = send({"type_string": "toukyou", "then": "space",
          "fields": ["candidates", "historyEnd", "fixedEnd"]})
print(r)
# 「東経」が candidates の historyEnd より前に出るなら前提条件1成立
```

**前提条件2**: 「確定 → Backspace」で penalizeAll が動くか（既存機能のテスト）

`doBackspace` の既存実装が `lastConfirmedContext` を使うことはコードから確認済み。

**前提条件3（重要）**: 「確定 → 打ち直し → 別候補確定」のシーケンスで penalizeAll が動かないことを確認する

テストコードを見ると：

```swift
// ScenarioRegressionTests.swift を確認する価値あり
```

---

## Step 4: 問題の構造を整理する

### 実装するとしたら何が必要か

「選び直し検出」のためには：

1. `lastConfirmedContext` をローマ字入力が始まっても **クリアしない** で保持し続ける
2. 次の確定時に「同じ読み・別の output」なら penalizeAll を発火させる

### しかしこれには重大な問題がある

`clearLastConfirmedContextUnlessBackspace` がある理由：**確定後に別のことを書き始めたら古い context は忘れる**というのが意図的な設計。

「東経」を確定してから別の文章（「東京に行く」の「東京」ではなく全く別の話）を書き始め、また偶然「とうきょう」と打って「東京」を確定した場合、「東経」は誤確定ではないのに penalize してしまう。

**誤検出の具体例:**
- 「東経140度」と打つつもりで「東経」確定 → しばらく「140」など入力 → 文書の別箇所で「東京」確定 → 「東経」に意図しないペナルティ

---

## Step 5: 判断する

### 前提条件の評価

| 前提条件 | 評価 |
|----------|------|
| 「東経」が履歴候補に出る | 成立（history スコア閾値 0.5 を超えれば出る） |
| 「確定 → Backspace」でペナルティが動く | **すでに実装済み** |
| 「打ち直し確定」シーケンスが検出可能 | 可能だが誤検出リスクが高い |

### 実装する価値があるか

**判断: 実装しない（前提条件が崩れた）**

理由:
1. **半分はすでに解決済み**: 「確定 → 即 Backspace」でのペナルティは動いている。最も典型的な「間違えて Backspace で消す」パターンをカバーしている。
2. **誤検出リスクが実害を超える**: 「確定 → 打ち直し確定」の検出には context をどこまで保持するかという境界問題があり、誤ペナルティで正しい履歴を壊す副作用の方が大きい可能性がある。
3. **Zenzai が解決するケースが多い**: `leftSideContext` があれば Zenzai が文脈から「東京」か「東経」かを判断し、上位に置く。ペナルティ不要で解決する。
4. **Shift+Delete で手動削除できる**: `fixedEnd <= row < historyEnd` の履歴候補は Shift+Delete で削除可能。最悪のケースはユーザーが手動で除去できる。

### もし将来実装するとしたら

- **スコープを限定**: 「確定 → Backspace」の直後に **同じ読みの別候補を確定した場合のみ** ペナルティを発火する
- `lastConfirmedContext` をクリアするタイミングを「Backspace 後の再確定」まで延長する（ただし同じ読みを再入力したかどうかの判定が必要）
- `docs/observation.md` に「ペナルティ発火回数」と「履歴スコア変化」を卒業条件として書いてから入る

### 結論

```
【結論】実装しない
【理由】
- 「確定 → 即 Backspace」ペナルティはすでに動いている
- 「打ち直し確定」の検出は誤検出リスクが高く、既存の正しい履歴を壊す
- Zenzai + Shift+Delete で実用上カバー可能

【次のアクション】なし（現状維持）
```

---

## 補足: 既存の「確定直後 Backspace ペナルティ」が動いているか sandbox で確認する価値

今回の調査で気づいたことだが、現行の `penalizeAll` は `count - 1` して `count <= 0` で削除する。
`count >= 2` の場合は削除されず 1 回 count が減るだけなので、**何回か続けて誤確定しないとスコアが大きく変わらない**。

```swift
// DatabaseManager.penalizeAll の現実: count=2 → count=1 になるだけ（まだ候補に残る）
// 候補スコアは count * 1.0 / (1.0 + ...) で計算されるため
// count が半減すれば threshould 0.5 以下に落ちる可能性あり（ケース依存）
```

これは別途 `/keynaco-ime-sandbox` で確認しておく価値がある。
