# Plan ファイルの frontmatter 規約

`plans/PLAN*.md` / `plans/POC*.md` 新規作成時はファイル冒頭に YAML frontmatter を付ける。

## ファイル名

```
PLANYYMMDD[-letter]-<slug>.md
POCYYMMDD[-letter]-<slug>.md
```

- **ID**（`PLAN260612` 等）: 本文見出し `# PLAN260612: …` と frontmatter の参照用。日付 + 同日複数なら末尾 letter。
- **slug**: 英小文字 kebab-case の概要（2〜5 語）。Finder / `ls` で内容が分かるようにする。
- 例: `PLAN260605-workarounds-audit.md`、`PLAN260612-async-candidate-pipeline.md`

本文中の plan ID（`PLAN260612:`）はファイル名と独立してよい。リンク・`superseded_by` は **リネーム後のファイル名**（`.md` 付き）を使う。

## スキーマ

```yaml
---
status: draft | in-progress | implemented | abandoned | superseded
created: 2026-MM-DD
related_commit: <hash>           # status: implemented のとき
related_rejected: F-1            # status: abandoned のとき（rejected.md のエントリ番号 / 見出し）
superseded_by: PLAN260528-history-segment-noise.md  # status: superseded のとき
---
```

## status の意味

| 値 | 意味 | 次の遷移先 |
|---|---|---|
| `draft` | 検討中・未着手 | in-progress / abandoned / superseded |
| `in-progress` | 実装中 | implemented / abandoned |
| `implemented` | 実装完了。`related_commit` を記載 | （終端） |
| `abandoned` | 検討・実装の途中で捨てた。`related_rejected` で rejected.md エントリへリンク | （終端） |
| `superseded` | より新しい plan に置き換えられた。`superseded_by` で後継ファイル名 | （終端） |

## 例

### 実装完了 plan

```yaml
---
status: implemented
created: 2026-05-25
related_commit: 5edf2bc
---

# PLAN260525: ...
```

### 不採用になった plan

```yaml
---
status: abandoned
created: 2026-04-29
related_rejected: E-1
---

# PLAN260429: Backspace 再変換
```

## 既存記述との互換性

既存の `**状態**: オープン` / `**状態**: 完了` のような markdown 記述は legacy 扱いで認識する。新規 plan は frontmatter を優先する。

## なぜ必要か

多数の plan の **状態が外から見えない** ため、リンク切れが発生しても気付けなかった。Frontmatter で機械的にライフサイクルを管理することで、`plans-audit` skill が:

1. **status 別の俯瞰**: 各状態に何件あるか即座に分かる
2. **stale draft の検出**: 30 日以上 draft のままの plan を可視化
3. **参照整合性**: `related_commit` が実在するか、`related_rejected` が rejected.md にあるかを照合
