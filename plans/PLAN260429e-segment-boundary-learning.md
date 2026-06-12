---
status: deferred
created: 2026-04-29
related_commits:
  - 62ca888  # PLAN260603 完了後 triage: 履歴は境界を上書きしない
references:
  - plans/PLAN260603.md
  - plans/PLAN260523g.md
  - Core/Sources/Core/InputHandler+SegmentMode.swift
  - Core/Sources/CoreTests/InputHandlerSegmentTests.swift
  - scripts/check_segment_history_boundary.py
---

# PLAN260429e: B-1 セグメント境界の学習

## ステータス（2026-06-04 更新）

**`deferred`** — 本 PLAN の `boundary_pref` 方式は一度実装されたが **2026-05 に削除**（[`PLAN260523g.md`](PLAN260523g.md)）。[`PLAN260603`](PLAN260603.md) 完了後の triage でも、**変換履歴が `engineClauseEnd` を上書きしない**ことを確認済み（コミット `62ca888`）。

| 判断 | 理由 |
|------|------|
| `boundary_pref` をそのまま復活 | ❌ Desktop 寄せ（`inputLength` 正本）と二重管理になる |
| `recordPrefixes` で境界を代替 | ❌ 表層候補のみ。`あなたは`→`貴方は` を学習しても `あなた\|は` の切れ目は変わらない |
| 再開するなら | Shift+矢印で調整した **`manualClauseEnd` のみ**永続化（全文読みキー・手動確定時のみ） |

未解決 UX: 手動境界は **セッション内だけ**（`CompositionState.manualClauseEnd`）。毎回同じ Shift 調整を繰り返すユーザーにはまだ効かない。

---

## 概要（当初案・参考）

セグメントモードで `Shift+矢印` による境界調整を行って確定したとき、
その境界パターンを DB に保存する。次回同じ読みでセグメントモードに入ったとき、
AzooKey の初期分割ではなく保存済みの境界を使って再現する。

> **注意**: 以下の実装方針は 2026-04 時点の草案。現行コードは `.selecting` 寄せ（`SegmentState` + `engineClauseEnd`）であり、`segmentize` 先頭分割や `doConfirmSegments` は存在しない。

---

## 現状の問題（当時）

`doConfirmSegments()` は `isManuallyAdjusted` セグメントに 3x の重みで `recordPrefixes` と
`recordBigram` を記録する。この結果、例えば「きょう」→「今日」の変換は履歴として高優先で出てくるが、
次回「きょうはよいてんきです」を入力して Space を押すと、AzooKey は再び誤った境界でセグメント分割する。
ユーザーは毎回同じ境界調整を繰り返す必要がある。

**2026-06 補足**: 境界誤りは履歴では直らない。表層（今日）は履歴で出やすくなるが、切れ目はエンジン部分候補が決める（[`PLAN260603`](PLAN260603.md)）。

---

## 再開時のスコープ案（狭く）

1. テーブル名は `boundary_pref` でもよいが、**`engineClauseEnd` を上書きするのは `didExperienceSegmentEdition == true` の確定時のみ**
2. `enterSegmentMode` では `defaultClauseEnd` のあと、保存値があれば `manualClauseEnd` 相当で初期化（AzooKey 結果より優先するかは POC 必須）
3. 変換履歴（`history`）とは独立。`penalizeAll` / Backspace 連動は [`PLAN260503c`](PLAN260503c.md) を踏襲
4. テスト: [`testHistoryDoesNotOverrideSegmentClauseEnd`](../Core/Sources/CoreTests/InputHandlerSegmentTests.swift) と併存する「pref あり時のみ境界が変わる」ケース

検証コマンド（履歴非干渉の回帰）:

```bash
cd Core && swift test --filter testHistoryDoesNotOverrideSegmentClauseEnd
python3 scripts/check_segment_history_boundary.py
```

---

## 実装方針（当初案・アーカイブ）

<details>
<summary>2026-04 草案（実装後削除済み。参照用に折りたたみ）</summary>

### 1. `boundary_pref` テーブルを追加

```sql
CREATE TABLE IF NOT EXISTS boundary_pref (
    full_reading  TEXT NOT NULL PRIMARY KEY,
    boundaries    TEXT NOT NULL,
    used_at       INTEGER NOT NULL
);
```

### 2. `DatabaseManager` にメソッドを追加

`saveBoundaryPref` / `fetchBoundaryPref`（完全一致のみ）。

### 3. `doConfirmSegments()` で境界を保存

`isManuallyAdjusted` なセグメントが1つ以上ある場合のみ保存。

### 4. `enterSegmentMode()` で境界を参照

`fetchBoundaryPref` ヒット時は `segmentize` より優先（当時の設計）。

### 変更ファイル（当時）

| ファイル | 変更内容 |
|---------|---------|
| `DatabaseManager.swift` | `boundary_pref` テーブル・API |
| `InputHandler+SegmentMode.swift` | 参照・保存 |

### テスト（当時）

1. 保存テスト 2. 再現テスト 3. 非保存テスト 4. フォールバックテスト

### 考慮事項（当時）

- 境界マッチは完全一致のみ
- GC: 180 日未使用削除
- 上書き: 最後の確定を優先

### 規模見積もり（当時）

3〜4時間

</details>

---

## 関連

- 削除作業: [`PLAN260523g.md`](PLAN260523g.md)
- 文節境界正本: [`PLAN260603.md`](PLAN260603.md)
- LLM 境界保存案（同様に obsolete）: [`PLAN260503e.md`](PLAN260503e.md)
