# LLM クレンジング（ユーザーレビュー）実装計画

## 目標

`FoundationModels`（オンデバイス LLM）で `history` / `bigram` のエントリを評価し、
怪しいエントリを設定画面の「クレンジング」タブに一覧表示してユーザーが確認してから削除できるようにする。

---

## 完成イメージ

```
[ Bi-gram | ユーザー辞書 | 変換履歴 | Zenzai | クレンジング ]

  ┌─ LLM がフラグを立てたエントリ（8 件）─────────────────────────────────┐
  │ テーブル   直前の語   読み        確定テキスト   判定      理由         │
  │ history   —          ks          草             ⚠ suspect  読みと不一致  │
  │ bigram    草          www         wwww           🗑 delete   無意味な列    │
  │ history   —          とうきょ    東京            ✓ keep    (非表示)      │
  │ ...                                                                      │
  └──────────────────────────────────────────────────────────────────────────┘
  [選択削除]  [suspect/delete をすべて削除]          [再スキャン]  スキャン中…▓▓▓░░░
```

- `keep` 行は表示しない（怪しいもの限定）
- 選択行は Delete キーでも削除可能（`DeletableTableView` 流用）
- FoundationModels 未利用環境（Apple Intelligence 非対応機）では「Apple Intelligence が必要です」メッセージを表示

---

## ファイル構成（新規作成 / 変更）

| ファイル | 種別 | 内容 |
|--------|------|------|
| `Core/Sources/Core/LLMCleanser.swift` | 新規 | 評価ロジック（`LLMCleanser` actor） |
| `keynaco/Settings/CleanserViewController.swift` | 新規 | 設定タブ UI |
| `keynaco/Settings/SettingsWindowController.swift` | 変更 | 「クレンジング」タブ追加 |
| `Core/Sources/Core/DatabaseManager+Ngram.swift` | 変更 | `deleteTrigram` / `deleteSkipBigram` 追加（将来用、今回は history / bigram のみ） |

---

## Step 1: `LLMCleanser`（Core）

### 公開インターフェイス

```swift
// Core/Sources/Core/LLMCleanser.swift
import FoundationModels

public actor LLMCleanser {

    public enum Verdict: String, Sendable {
        case suspect  // ユーザー確認推奨
        case delete   // 明らかなノイズ
    }

    public struct FlaggedEntry: Sendable {
        public let table: String           // "history" | "bigram"
        public let historyKey: (input: String, output: String)?   // history 行のキー
        public let bigramKey: (prev: String, input: String, output: String)?  // bigram 行のキー
        public let display: String         // 表示用文字列（例: "ks → 草"）
        public let verdict: Verdict
        public let reason: String          // LLM が返した短い理由
    }

    public init() {}

    /// history / bigram を評価して suspect/delete エントリを返す。
    /// `onProgress(completed:total:)` は Main Actor から呼ばれる。
    public func evaluate(
        db: DatabaseManager,
        onProgress: @MainActor @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [FlaggedEntry]
}
```

### 内部処理フロー

```
1. db.fetchAllHistory()  → HistoryEntry[]
2. db.fetchAllBigram()   → BigramEntry[]
3. history + bigram を 30 件ずつのバッチに分割
4. 各バッチを LanguageModelSession に投げて @Generable で構造化出力を受け取る
5. verdict が keep のものを除外して FlaggedEntry[] にまとめる
```

### @Generable スキーマ

```swift
@Generable
private struct BatchResult {
    @Guide(description: "各エントリの判定結果")
    var items: [ItemResult]

    @Generable
    struct ItemResult {
        @Guide(description: "エントリの通し番号（0始まり）")
        var id: Int
        @Guide(description: "keep / suspect / delete のいずれか")
        var verdict: String
        @Guide(description: "10文字以内の判定理由（日本語）")
        var reason: String
    }
}
```

### プロンプト

```
あなたは日本語IMEの学習データ品質チェッカーです。
以下のエントリを評価し、verdict を返してください。

- keep   : 自然な日本語変換
- suspect: やや不自然（ユーザー確認推奨）
- delete : 明らかな誤変換・ノイズ（読みと変換が意味的に無関係、記号列など）

history エントリ: 読み → 確定テキスト のペア
bigram エントリ : 直前の語 | 読み → 確定テキスト の組

---
[{"id":0,"type":"history","input":"ks","output":"草"}, ...]
```

### FoundationModels 可用性チェック

```swift
guard case .available = SystemLanguageModel.default.availability else {
    throw CleanserError.unavailable  // UI 側でメッセージ表示
}
```

---

## Step 2: `CleanserViewController`（App）

### UI 構成

```
NSView
├── NSStackView (vertical)
│   ├── statusLabel  ("LLM がフラグを立てたエントリ N 件" / "スキャン中..." / "Apple Intelligence が必要です")
│   ├── NSScrollView + NSTableView (flagged entries)
│   └── bottomBar (NSStackView horizontal)
│       ├── deleteSelectedButton "選択を削除"
│       ├── deleteAllButton      "すべて削除"
│       └── scanButton           "スキャン" / "キャンセル"
└── NSProgressIndicator (indeterminate, スキャン中のみ表示)
```

### テーブルカラム

| identifier | タイトル | 幅 |
|-----------|---------|-----|
| `table`   | テーブル | 80 |
| `prev`    | 直前の語 | 120 |
| `input`   | 読み    | 120 |
| `output`  | 確定テキスト | 200 |
| `verdict` | 判定    | 70  |
| `reason`  | 理由    | 160 |

- verdict セルは絵文字 + 文字列（⚠ suspect / 🗑 delete）で色分け
- `keep` エントリは `data` 配列に入れない（フィルタ済みのもの一覧）

### 状態管理

```swift
private enum ScanState {
    case idle
    case scanning(task: Task<Void, Never>)
    case done(count: Int)
    case unavailable  // Apple Intelligence 非対応
}
```

- `scanning` 中はスキャンボタンを「キャンセル」に変え `task.cancel()` で中断可能
- `unavailable` では tableView を非表示にしてメッセージラベルを表示

### 削除処理

```swift
private func deleteEntry(_ entry: LLMCleanser.FlaggedEntry) {
    if let k = entry.historyKey {
        DatabaseManager.shared.deleteHistoryEntry(input: k.input, output: k.output)
    } else if let k = entry.bigramKey {
        DatabaseManager.shared.deleteBigram(prev: k.prev, input: k.input, output: k.output)
    }
}
```

---

## Step 3: `SettingsWindowController` へのタブ追加

```swift
let cleanserItem = NSTabViewItem(viewController: CleanserViewController())
cleanserItem.label = "クレンジング"
tabVC.addTabViewItem(cleanserItem)
```

ウィンドウ幅は既存の 720pt のまま使用（CleanserViewController のカラム合計が収まる）。

---

## Step 4: テスト

- `LLMCleanser` は actor なので `XCTest` の `async` テストで検証可能
- FoundationModels が使えない CI 環境では `availability == .unavailable` パスのみテスト（`CleanserError.unavailable` を throw するパス）
- UI テストは採用しない（IME の E2E テスト方針と同じ理由）

---

## 考慮事項

- **バッチサイズ**: 30件/バッチ。大きすぎるとコンテキスト上限に当たる可能性があるため小さめに設定。プロダクションで調整。
- **is_preset 行**: `bigram` の `is_preset = 1` 行は evaluate 対象から除外（既存の GC 方針と同じ）
- **trigram / skip_bigram**: Phase 2 以降。今回は history と bigram のみ。
- **自動実行**: Phase 3（今回は手動スキャンのみ）
