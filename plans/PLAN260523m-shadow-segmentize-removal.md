# Step 3: 確定時 shadow segmentize 学習削除

作成: 2026-05-23  
親計画: [`PLAN260523j-ime-simplification-phase3.md`](PLAN260523j-ime-simplification-phase3.md)（Phase 3 Step 2）

## ゴール

候補を Enter で確定したとき、**非同期 `segmentize` で部分語を `recordPrefixes` する隠れ学習** を削除する。文節単位の学習は **Space → セグメントモード** の明示経路に集約する。

## 背景

`doConfirmSelection`（`InputHandler+BracketMode.swift`）は、4 文字以上の日本語読みを候補確定するとき:

1. フル読みで `recordPrefixes`（通常確定）
2. `Task.detached` で `segmentize` → 各セグメントを追加 `recordPrefixes`

ユーザーから見えず、Space セグメントモードと役割が重複する。テスト [`InputHandlerSegmentLearningTests.swift`](../Core/Sources/CoreTests/InputHandlerSegmentLearningTests.swift) が存在するが、意図的な「隠れ機能」として保守コストに見合わない。

## 削除対象

| 操作 | ファイル |
|------|----------|
| ブロック削除 | `Core/Sources/Core/InputHandler+BracketMode.swift` — `doConfirmSelection` 内 `segmentizeMinReadingLength` 以降の `Task.detached { segmentize ... }` 全体 |
| 定数削除 | `Core/Sources/Core/InputHandler+CandidatesUtil.swift` — `segmentizeMinReadingLength`（他参照なし） |
| ファイル削除 | `Core/Sources/CoreTests/InputHandlerSegmentLearningTests.swift` |

## 残すもの

- セグメントモード本体（Space → `enterSegmentMode` → Enter 確定時の `recordPrefixes`）
- `doConfirmSelection` の通常 `recordPrefixes` + `conv.commit` + `commitText`
- `tryManualBisection` / Shift+矢印境界調整

## 挙動変化

| 操作 | 削除前 | 削除後 |
|------|--------|--------|
| `purojekutowosusumeru` Enter で「プロジェクトを進める」確定 | 非同期で `ぷろじぇくと→プロジェクト` 等が部分学習される | フル読み `recordPrefixes` のみ |
| Space → セグメント確定 | 文節ごと学習（変更なし） | 同左 |

## ドキュメント

- `docs/domain/architecture.md` — shadow 学習の言及があれば削除
- glossary に該当節なし

## 検証

```bash
cd Core && swift test --filter InputHandlerSegment
cd Core && swift test --filter InputHandlerCandidates
```

sandbox:

- `setteigamen` Space → セグメント確定 → 各文節が `recordPrefixes` されること（従来どおり）
- 通常 Enter 確定（Space なし）で部分語が history に増えないこと

## リスク

| リスク | 深刻度 | 備考 |
|--------|--------|------|
| Space を使わず長文を一発確定するユーザー | 中 | 部分語の履歴 prefix が貯まらなくなる。セグメントモード利用を促すトレードオフ |
| AzooKey `commit` は維持 | — | 辞書エンジン側学習は影響なし |

## 完了条件

- [ ] shadow segmentize ブロック削除
- [ ] `InputHandlerSegmentLearningTests.swift` 削除
- [ ] セグメントモードテストパス
