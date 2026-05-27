# Apple Intelligence（FoundationModels）ナレッジ

keynaco での Apple Intelligence 利用に関する知見・実験結果の蓄積。

---

## サンドボックス制約（最重要）

IME Extension（Input Method Extension）は通常アプリより厳しいサンドボックスが適用される。

| API | IME Extension | Settings / 本体アプリ |
|-----|:---:|:---:|
| `respond(to:)` プレーンテキスト | ✅ 動作確認済み | ✅ 動作確認済み |
| `respond(generating:)`（Guided Generation） | ❌ ハング（Error 159） | ✅ 動作確認済み |
| Tool Calling（`struct: Tool`） | ❌ ハング（Error 159） | ⚠️ 未確認 |

**根本原因**: Guided Generation と Tool Calling は `generatived` / `com.apple.modelcatalog.catalog` への XPC 通信を経由する。IME サンドボックスがこの XPC を拒否する。エラーも例外も返さずデッドロックするため原因特定が困難。

**判断基準**: IME Extension 内で Apple Intelligence を使う場合は `respond(to:)` プレーンテキスト方式のみ使える前提で設計する。

---

## `respond(to:)` プレーンテキスト方式の注意点

### フォーマット指示への追従性が低い

`YES|NO|MAYBE <reason>` のような厳密なフォーマットを指示しても守られないことが多い。実測では：
- `YES|YES|reason` のように判定を重複出力
- 判定と理由が矛盾（「common word なので不要」と書きながら YES を返す）
- 複数行にまたがる出力

→ パース側でできるだけ寛容に処理するか、判定の先頭トークンだけ見る設計にする。

### 日本語分類タスクへの適性

2026-05-27 の固有名詞検出 POC（`scripts/poc_proper_noun_ai.swift`）の結果：

| 期待 | 実際の判定 | 件数 |
|------|-----------|------|
| NO（一般語・技術用語） | YES（全誤り） | 7/7 |
| YES（固有名詞） | YES（正解） | 2/2 |
| 不明 | YES（全件） | 6/6 |

**全 15 件すべて YES**。NO を一度も返さなかった。YES 方向に強いバイアスがかかっており、「入力」「仕事」「チーム」などの明確な一般語も固有名詞と判定した。

**結論**: 細粒度の日本語語彙分類（固有名詞 vs 一般語の区別）には不向き。AzooKey 辞書の `lcid` ルールベース分類の方が精度・速度ともに上。

### 向いているタスク・向いていないタスク

| 向いている | 向いていない |
|-----------|------------|
| 文章要約（話題・キーワード抽出） | 細粒度の品詞分類 |
| 粗い二値判定（「この文章は日本語か」等） | 複数クラスの分類 |
| バッチ・バックグラウンド処理 | リアルタイム入力補助 |
| Settings / 本体アプリ側の処理 | IME Extension 内の処理 |

---

## コマンドラインスクリプトでのデッドロック

Swift スクリプトで `@MainActor` な Task と `DispatchSemaphore.wait()` を組み合わせると**デッドロックする**。

```swift
// ❌ デッドロック: sema.wait() が main スレッドを止め、@MainActor Task が実行できない
let sema = DispatchSemaphore(value: 0)
Task { @MainActor in
    // ... async work ...
    sema.signal()
}
sema.wait()  // ← main スレッドをブロック → Task が走れない
```

```swift
// ✅ RunLoop スピンで main スレッドを解放したまま待つ
var finished = false
Task {
    // ... async work ...
    finished = true
}
while !finished {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}
```

---

## 可用性チェック

```swift
guard case .available = SystemLanguageModel.default.availability else {
    // Apple Intelligence 非対応 or 未設定の環境
    return
}
```

Apple Intelligence は対応デバイス・言語設定が必要。使えない環境では何もしない（フォールバック設計を前提にする）。

---

## 関連ドキュメント

- `docs/rejected.md` — H-1: `@Generable` 構造化出力の不採用理由（IME サンドボックスによるハング）
- `plans/PLAN260527.md` — Apple Intelligence を使った日記自動生成の実装計画
- `scripts/poc_proper_noun_ai.swift` — 固有名詞検出 POC スクリプト（2026-05-27）
- `keynaco/Debug/DebugGuidedGenerationTest.swift` — 本体アプリでの Guided Generation 動作確認ツール（2026-05-27）
