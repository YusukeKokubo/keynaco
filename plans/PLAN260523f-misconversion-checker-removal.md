# Step 1: `LLMMisconversionChecker` 削除

作成: 2026-05-23  
親計画: [`PLAN260523e-ime-simplification-phase2.md`](PLAN260523e-ime-simplification-phase2.md)

## ゴール

確定後のオンデバイス LLM 誤変換スキャン（F4 相当）を **完全削除** する。IME 入力パイプラインから切り離し、LLM リソースを POS 分類に集中させる。

## 背景

- 確定のたびに 0.5 秒デバウンス後 `LanguageModelSession` を起動（`InputController+LLM.swift:62`）
- IME 変換そのものには寄与せず、事後監査＋メニューバー `⌨!` / バナー通知のみ
- [`PLAN260523c-ime-feature-audit.md`](PLAN260523c-ime-feature-audit.md) では通知改善で維持したが、**入力体験のコスト（LLM 競合・誤検知ノイズ）> 有益性** と再判断

## 削除対象

| 操作 | ファイル |
|------|----------|
| ファイル削除 | `Core/Sources/Core/LLMMisconversionChecker.swift` |
| ファイル削除 | `Core/Sources/CoreTests/LLMMisconversionCheckerTests.swift` |
| static プロパティ削除 | `keynaco/InputController.swift` — `static let misconversionChecker` |
| メソッド削除 | `keynaco/InputController+LLM.swift` — `scheduleMisconversionCheck` |
| 呼び出し削除 | `keynaco/InputController.swift` — `applyPostKeyDownEffects` 内 `scheduleMisconversionCheck`（`insertText` 後） |
| 呼び出し削除 | `keynaco/InputController.swift` — `commitComposition` 内 `scheduleMisconversionCheck` |
| cancel 整理 | `keynaco/InputController.swift` — `cancelOnDeviceLLMTasks` から `misconversionChecker.cancel()` 分岐を削除（関数ごと削除 or POS のみ残す形に簡素化） |
| 通知名削除 | `Core/Sources/Core/NotificationNames.swift` — `keynacoMisconversionIssueFound` / `keynacoMisconversionCleared` |
| AppDelegate 整理 | `keynaco/AppDelegate.swift` — 以下を削除 |
| | - `MisconversionNotification` enum |
| | - `misconversionIssueObserver` / `misconversionClearObserver` |
| | - `misconversionDetail` / `misconversionPopover` / `misconversionTextView` |
| | - `setupMisconversionPopover` / `setupMisconversionNotifications` |
| | - `postMisconversionNotification` / `clearMisconversionNotifications` |
| | - `applyMisconversionIssue` / `applyMisconversionCleared` / `showMisconversionPopoverIfNeeded` / `toggleMisconversionPopover` |
| | - `updateStatusItemTitle` の `⌨!` 分岐（Successor `⌨…` のみ残す） |
| | - `statusBarButtonClicked` の誤変換 Popover 分岐 |
| | - `UNUserNotificationCenterDelegate` 実装（誤変換専用なら削除） |

## 残すもの

- `LLMPOSClassifier` / `schedulePOSClassification` / `performPOSBackfill`
- `keynacoSuccessorPendingChanged` 通知と `⌨…` 表示
- `SurroundingIMKContext`（Zenzai 左文脈・POS 以外でも使用中）

## ドキュメント更新

| ファイル | 変更 |
|----------|------|
| `docs/domain/glossary.md` | 「F4（誤変換検出）」節を削除 |
| `docs/domain/architecture.md` | `InputController` / `NotificationNames` / `SurroundingIMKContext` から誤変換言及を削除 |
| `CLAUDE.md` | LLM 機能一覧から `LLMMisconversionChecker` を削除 |
| `CHANGELOG.md` | 削除を記録（任意） |

## 検証

```bash
cd Core && swift test
xcodebuild test -scheme keynaco -destination "platform=macOS"
```

手動:

- 確定後にメニューバーが `⌨!` にならないこと
- Successor 保留時は従来どおり `⌨…` になること
- 通常変換・セグメント・Successor が退化しないこと

## リスク

| リスク | 対策 |
|--------|------|
| 誤変換に気づけなくなる | ユーザーは確定結果を直接見ている。将来必要なら設定トグル付きで再導入 |
| AppDelegate の通知権限リクエストが orphan | 誤変換専用なら `requestAuthorization` ごと削除 |

## 完了条件

- [ ] 上記ファイル削除・整理完了
- [ ] テストパス
- [ ] domain docs / CLAUDE.md 更新
