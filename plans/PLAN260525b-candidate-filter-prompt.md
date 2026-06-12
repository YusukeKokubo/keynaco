---
status: implemented
created: 2026-05-25
related_commit: b8e059e
---

# PLAN260525b: 候補フィルタ改善 + LLM プロンプト改善

施策 A（ブロックリスト化）は [`b8e059e`](b8e059e) で完了。施策 B はのち AzooKey 辞書 lcid 分類（`bffcc71`）で置き換え。

## 背景

[POC260525b-generable-pos-classification.md](POC260525b-generable-pos-classification.md) で構造化出力（@Generable）が macOS 26 Beta の IME サンドボックス制限により使用不可であることを確認。
現実的な代替施策として以下の2つを実施する。

## 施策A: フィルターをブロックリスト方式に変更

### 問題

現在の候補表示フィルタは allowlist 方式：

```swift
// DatabaseManager.swift（推定）
WHERE pos = 'noun' OR pos LIKE 'proper_noun%'
```

LLM が業務名詞（設定・申請・担当者・チーム等）を `other` に誤分類するとそのまま候補から除外される。
全体の59%が `other` に分類されているため、よく使う語のほとんどが候補に出ない状態。

### 変更内容

`POSLabelV2.shouldHideFromCandidates` はすでに実装済み：

```swift
public var shouldHideFromCandidates: Bool {
    switch self {
    case .particle, .otherConjunction, .otherInterjection:
        return true
    default:
        return false
    }
}
```

DB クエリのフィルタを allowlist から blocklist に切り替える：

```sql
-- 変更前（allowlist）
WHERE pos = 'noun' OR pos LIKE 'proper_noun%'

-- 変更後（blocklist）
WHERE pos IS NULL
   OR pos NOT IN ('other/conjunction', 'other/interjection')
   AND NOT (pos = 'other' AND pos_tag LIKE 'particle%')
```

または Swift 側でフィルタリング：

```swift
// 候補取得後に shouldHideFromCandidates でフィルタ
entries.filter { entry in
    guard let pos = entry.pos,
          let label = POSLabelV2(posString: pos) else { return true }  // 未分類は表示
    return !label.shouldHideFromCandidates
}
```

### 期待効果

- `other` に誤分類された設定・申請・担当者・チーム等が即座に候補に出るようになる
- LLM 分類精度に関係なく安定する
- particle（課題を、価値が等）・conjunction（しかし等）は引き続き非表示

## 施策B: LLMPOSClassifier のプロンプト改善

### 問題

現行プロンプトはサ変名詞（設定・申請・同期等）を動詞語幹と混同して `other` / `verb` に誤分類する。

### 変更内容

`LLMPOSClassifier` の Instructions に few-shot ルールを追加：

```swift
LanguageModelSession(model: model, instructions: """
You are a Japanese POS tagger for IME input history.
Respond with ONLY a single label. No explanation, no punctuation.

Labels: noun, verb, adjective, other

Rules:
- Suru-verb noun stems WITHOUT する attached -> noun
  (設定, 申請, 同期, ログイン, 表示, 承認, 保存, 登録, 削除, 更新, 変更, 追加, 確認)
- Phrases with case particle suffix (課題を, 価値が) -> other
- Conjunctions (しかし, ただし, また) -> other

Examples:
設定 -> noun
申請 -> noun
担当者 -> noun
チーム -> noun
データ -> noun
取引先 -> noun
確認して -> verb
教えて -> verb
課題を -> other
しかし -> other
""")
```

### 防御的パース（既存強化）

```swift
let sanitized = response.content
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
    .components(separatedBy: .whitespaces).first ?? ""

let validLabels = ["noun", "verb", "adjective", "other"]
let matched = validLabels.first { sanitized.hasPrefix($0) } ?? "other"
```

## 実装順序

1. 施策A（フィルタ変更）を先に入れて UX を即改善
2. 施策B（プロンプト改善）を続けて入れて LLM 分類精度を向上
3. 両方コミット後、sandbox で実動作確認

## 成功基準

- 設定・申請・担当者・チーム・データ・取引先が変換候補に表示されること
- 「課題を」「価値が」「しかし」が候補に出ないこと
- LLM 分類ログ（OS Log）で noun 比率が上がっていること

## 関連

- [POC260525b-generable-pos-classification.md](POC260525b-generable-pos-classification.md) - @Generable POC 検証結果
