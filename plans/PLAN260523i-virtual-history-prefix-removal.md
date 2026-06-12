# Step 4: `virtualHistoryPrefix` 廃止

作成: 2026-05-23  
親計画: [`PLAN260523e-ime-simplification-phase2.md`](PLAN260523e-ime-simplification-phase2.md)

## ゴール

IMK `before` テキストから抽出した仮想 prev 語列（`virtualHistoryPrefix`）を廃止し、**セッション内 `committedHistory` のみ** を noun-bigram / Successor の prev 参照源にする。

## 背景

- `VirtualHistoryExtractor` が `before` 末尾 30 文字を区切り文字で分割し最大 2 語を返す
- `lastCommittedOutput` / `effectivePrevWords` が `virtualHistoryPrefix` にフォールバック（`InputHandler.swift:128`）
- `InputController` で **handle 前** にセットする必要があり、タイミングバグの温床（[`docs/domain/architecture.md`](../docs/domain/architecture.md) handler ライフサイクル表）
- Step 3 で `buildPendingCandidateList` を削除すると、handle 前セットの **主理由の一つが消える**

## 削除対象

| 操作 | ファイル |
|------|----------|
| ファイル削除 | `Core/Sources/Core/VirtualHistoryExtractor.swift` |
| フィールド削除 | `InputHandler.swift` — `virtualHistoryPrefix` |
| フォールバック削除 | `InputHandler.swift` — `lastCommittedOutput` を `committedHistory.last` のみに |
| 同上 | `effectivePrevWords`（または同等プロパティ）— `virtualHistoryPrefix + committedHistory` 合成を `committedHistory` のみに |
| セット削除 | `keynaco/InputController.swift` — 新規組成開始時の `VirtualHistoryExtractor.extract` 呼び出し（2 箇所）と関連 `= []` クリア |
| 設定削除 | `keynaco/Settings/VirtualHistorySettings.swift` — ファイルごと削除（`virtualHistoryEnabled` トグル） |
| スナップショット | `InputHandlerSnapshot.swift` / `+Snapshot.swift` — `virtualHistoryPrefix` フィールド |
| デバッグ | `DebugSocketServer+Commands.swift` — extract / セットコメント |
| デバッグ | `DebugSocketServer.swift` / `IMESandboxWindow.swift` — レスポンスフィールド |
| テスト削除 | `Core/Sources/CoreTests/InputHandlerVirtualContextTests.swift` |
| テスト更新 | `ScenarioRegressionTests.swift` — `virtualHistoryPrefix` 手動セット箇所削除 |

### `VirtualHistorySettings.isEnabled` ガード

`InputController.swift` の以下条件から設定参照を削除（機能自体がなくなるため）:

```swift
if composingWasEmpty, VirtualHistorySettings.isEnabled, ...
    ic.handler.virtualHistoryPrefix = VirtualHistoryExtractor.extract(...)
```

## 残すもの

- `committedHistory` / `pushCommitted` / 句読点スキップ / `sentenceTerminators` リセット
- `lastConfirmedNounOutput`（LLM POS 分類後）
- `leftSideContext` / Zenzai 左文脈（別系統）

## 挙動変化

| シナリオ | 削除前 | 削除後 |
|----------|--------|--------|
| 新規ドキュメント先頭から入力 | `committedHistory` のみ | 同左 |
| 既存文書の **文中** にカーソル置き、keynaco で初入力 | `before` 末尾語で noun-bigram prev が効く | **セッション確定履歴が空なら prev なし** → Successor / 組成中予測なし |
| Electron 等で `before` 取れない環境 | 既に virtual も効かない | 同左 |

文中挿入時の Successor 初期精度低下は **許容するトレードオフ**（ヒューリスティック依存をやめる）。

## ドキュメント更新

| ファイル | 変更 |
|----------|------|
| `docs/domain/glossary.md` | `virtualHistoryPrefix` 節削除。`lastCommittedOutput` のフォールバック説明更新 |
| `docs/domain/architecture.md` | handler ライフサイクル表から `virtualHistoryPrefix` 行削除 |
| `CLAUDE.md` | virtualHistory 言及があれば削除 |

設定 UI はスコープ外だが `VirtualHistorySettings.swift` 削除により **設定画面からの参照** があれば合わせて除去（grep `VirtualHistory`）。

## 検証

```bash
cd Core && swift test
rg virtualHistory VirtualHistoryExtractor
```

手動 / sandbox:

1. 空ドキュメント: `tokyo` 確定 → Successor 正常
2. 既存文「今日は」+ カーソル末尾 → 新規 keynaco セッションで `k` → **組成中 noun-bigram 予測なし**（退化期待）
3. 同条件で一度 `漢字` 確定後 → `committedHistory` 経由で Successor 動作

## リスク

**中** — 文中編集ワークフローで初回予測が弱くなる。ただし virtual の抽出精度も保証されていなかった。

## 依存

- **Step 3 完了後推奨**（pending 先読み削除で InputController の handle 前ロジックが簡素化される）
- Step 1・2 と独立 PR も可能

## 完了条件

- [ ] `VirtualHistoryExtractor` / `virtualHistoryPrefix` 全参照削除
- [ ] `VirtualHistorySettings.swift` 削除
- [ ] テスト更新・パス
- [ ] glossary / architecture 更新
