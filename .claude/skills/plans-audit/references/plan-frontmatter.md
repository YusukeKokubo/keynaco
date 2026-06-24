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

### 拡張フィールド（オプション）

特定のスキル経由で作成された plan は、そのスキルが追加情報を contract として固定するために
拡張フィールドを使う。**audit スクリプトは無視するで本体スキーマには影響せん**。
ただし plan-audit の人手 triage で読み取り対象になるため、命名は本ファイルで集約しとく。

#### `keynaco-perf-cycle` 由来 plan

パフォーマンス改善サイクルの「目的軸 + ベースライン + 検証 window」を契約として固定する。

```yaml
---
status: draft | in-progress | implemented
created: 2026-MM-DD
objective_axis: CPU-waste | UX-pain | latency | accuracy
baseline_at: 2026-MM-DDTHH:MM:SS    # ベースライン計測時刻（ISO8601）
baseline_window: 24h                 # /keynaco-latency-profiler の --since 値
sample_threshold:                    # implemented に進む閾値
  sessions: 5
  confirmations: 100
# 以下は status: implemented 時に追記
verified_at: 2026-MM-DDTHH:MM:SS
verified_window: 24h                 # baseline_window と同一値であるべき
verified_sample:
  sessions: 7
  confirmations: 142
related_commit: <hash>
---
```

ルール:
- `verified_window` は `baseline_window` と同一値であるべき（before/after の対称性）
- `verified_sample` のいずれかが `sample_threshold` を下回るなら `status: in-progress` のまま据え置く
- `objective_axis` は 1 つだけ。複数軸を同時最大化する plan は分割する

詳細は `.claude/skills/keynaco-perf-cycle/SKILL.md` を参照。

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

## Phase 進捗マーカー（推奨）

Plan を Phase / マイグレーション段階に分けて書く場合は、各 Phase 見出しの直下に Markdown チェックボックスを置く。`status: implemented` を付ける前に **すべて `- [x]` が埋まっとるか** を audit が機械的に検出する。

```markdown
### Phase 1: 履歴・辞書統合
- [x] CandidateScoreBuilder 導入
- [x] 既存テストの期待順序を更新

### Phase 2: hiraganaPreferred スコア化
- [x] fixedSlot=.hiragana 削除
- [x] HiraganaPreferredBuiltins dismiss 維持

### Phase 3: dead code 削除
- [x] HistoryPrefixPromotion.swift 削除
- [x] InitialRowPolicyResolver 削除
```

**ルール**:

- Phase 区切りを使わん小さい plan では不要（チェックボックスを書かない plan は audit が静観する）
- `- [ ]` / `- [x]` を含む plan で `status: implemented` を付けるなら、`- [ ]` がゼロになっとる必要がある（`verify_references.sh` が検出）
- Phase 単位で `- [x]` が部分的なときは `status: in-progress` のまま据え置く
- 「触らない判断」をした項目は `- [~] 触らない判断` のように note 付き斜線で書くか、Phase ごと削除する。`- [ ]` のまま残すと永遠に audit に挙がる

**なぜ**: PLAN260624 で「Phase 3 dead code 削除」のうち `maxHighHistoryCount` 撤去だけ漏れて 1 日放置された。frontmatter `status: implemented` は付いとったが、本文の Phase リストとの整合性を見る仕組みが無かったため気づけなかった。チェックボックスは見た目に進捗が分かり、grep でも機械チェックできる。

## 既存記述との互換性

既存の `**状態**: オープン` / `**状態**: 完了` のような markdown 記述は legacy 扱いで認識する。新規 plan は frontmatter を優先する。

## なぜ必要か

多数の plan の **状態が外から見えない** ため、リンク切れが発生しても気付けなかった。Frontmatter で機械的にライフサイクルを管理することで、`plans-audit` skill が:

1. **status 別の俯瞰**: 各状態に何件あるか即座に分かる
2. **stale draft の検出**: 30 日以上 draft のままの plan を可視化
3. **参照整合性**: `related_commit` が実在するか、`related_rejected` が rejected.md にあるかを照合
