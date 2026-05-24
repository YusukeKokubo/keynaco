# PLAN260524: POS 分類タグ体系の改善

## 目的

- `proper_noun` に `product`（製品・サービス）と `work`（作品名）を追加
- `other` のサブカテゴリを `pos` カラムに保持（現状は `pos_tag` にのみ残る）
- `noun/verb/adjective/particle` のサブタグをプロンプトから除去してシンプル化

## 背景・根拠

- `proper_noun/product` と `proper_noun/org` の分離: TypeScript/iPhone が現状 `org` に混入している。名詞 bigram の精度向上に寄与。
- `proper_noun/work`: 作品名（ドラゴンボール等）も `proper_noun` 系として bigram・`recentProperNouns` フィルタの対象になる。NWP は将来の話で、現時点のメリットはこれに限定。
- `other` サブタグ保持: 現状は `pos_tag` にのみ残るが `pos` にも書くことで後から `SELECT DISTINCT pos` で分布確認しやすくなる。
- `noun/verb/adjective/particle` サブタグ削除: DB 側でカテゴリ単位にしか使っていないので情報損失なし。プロンプト短縮で LLM の迷いを減らす効果を期待。

## org vs product の境界定義（プロンプトに載せる）

- **org**: 採用・発表・提訴の主語になる組織。"Apple が発表した"
- **product**: 消費・利用・インストールされる対象。バージョンや価格を持つ。"iPhone を買った"

Few-shot は対比ペアで示す（Apple/org + iPhone/product をセットに）。

## 変更ファイル

### 1. `Core/Sources/Core/LLMPOSClassifier.swift`

**プロンプト（system instructions）**

```
# Role
Japanese POS Tagger for IME commit history.
Reply: "tag:confidence" (high/mid/low).

# Tagset
- noun, verb, adjective, particle
- proper_noun/[type]:
  - place (geo/facility), person (name)
  - org: Active entities that announce, hire, or decide. ("Apple が提訴した")
  - product: Consumable tools, devices, apps, or services. ("iPhone を買った")
  - work: Creative titles treated as atomic units. ("ドラゴンボールを読む")
- other/conjunction, other/interjection, other/clause, other/unknown

# Examples
Apple → proper_noun/org:high
iPhone → proper_noun/product:high
Microsoft → proper_noun/org:high
Windows 11 → proper_noun/product:high
TypeScript → proper_noun/product:high
東京 → proper_noun/place:high
田中 → proper_noun/person:mid
ドラゴンボール → proper_noun/work:high
スラムダンク → proper_noun/work:high
実装 → noun:high
確認して → verb:high
欲しい → adjective:high
が → particle:high
しかし → other/conjunction:high
ええっと → other/interjection:high
```

**`normalizeTag` の `knownPrefixes`**

追加:
```swift
"proper_noun/product", "proper_noun/work",
"other/conjunction", "other/interjection", "other/clause", "other/unknown",
```

削除（プロンプトから消えるが念のため残してもよい）:
```swift
"noun/common", "noun/suru", "noun/number",
"verb/te", "verb/ta", "verb/dict",
"adjective/i", "adjective/na", "adjective/adv",
"particle/case", "particle/topic", "particle/aux",
```
→ LLM が古いフォーマットで応答した場合でも正規化できるよう **残す**。

**`categoryFromTag`**

```swift
case "proper_noun":
    let known = ["place", "person", "org", "product", "work"]  // product, work を追加
    ...
case "other":
    // other/conjunction 等をそのまま保持
    let known = ["conjunction", "interjection", "clause", "unknown"]
    if parts.count >= 2, known.contains(parts[1]) {
        return "other/" + parts[1]
    }
    return "other"
```

### 2. `Core/Sources/CoreTests/LLMPOSClassifierTests.swift`

追加テスト:

```swift
// proper_noun の新サブカテゴリ
XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/product"), "proper_noun/product")
XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/work"),    "proper_noun/work")
XCTAssertEqual(LLMPOSClassifier.categoryFromTag("proper_noun/product:high"), "proper_noun/product")

// other サブタグ保持
XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other/conjunction"),  "other/conjunction")
XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other/interjection"), "other/interjection")
XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other/clause"),       "other/clause")
XCTAssertEqual(LLMPOSClassifier.categoryFromTag("other/unknown"),      "other/unknown")
```

既存テストの修正:
- `other/conjunction` → `"other"` になっているテストを `"other/conjunction"` に変更（L53–57）
- `particle/case` 等は引き続き `"other"` のまま（particle は pos に subcategory 不要）

## 変更しないファイル

- `DatabaseManager+History.swift`: `pos LIKE 'proper_noun%'` クエリは新サブタグを自動包含。変更不要。
- `InputController+LLM.swift`: `pos.hasPrefix("proper_noun")` で bigram 対象判定。変更不要。

## 実装順序

1. `categoryFromTag` 修正 → テスト修正・追加 → `swift test` でグリーン確認
2. `normalizeTag` の `knownPrefixes` 更新
3. プロンプト差し替え
4. `/keynaco-ime-sandbox` で TypeScript/iPhone/ドラゴンボール の分類を確認

## 既存 DB への影響

- 既存レコードの `pos = "other"` は変わらない（`pos_tag` に `other/conjunction:high` 等が残っているものは次回 backfill で上書き可能だが、今回は自動マイグレーションなし）
- `pos = "proper_noun/org"` の TypeScript 等は backfill 対象（`pos_retry = 1` にするかは任意）
