---
name: plans-audit
description: |
  keynaco リポジトリの `plans/PLAN*.md` / `plans/POC*.md` のライフサイクル（draft / in-progress / implemented / abandoned / superseded）を可視化・監査するスキル。書きっぱなしの plan が滞留する問題を検出し、忘れられた検討案件を triage 対象として浮かび上がらせる。

  次のような場面で積極的に使うこと:
  - ユーザーが「plans 整理して」「plans の状態どうなってる？」「古い PLAN 残ってない？」「未着手の plan ある？」と言ったとき
  - 月次・四半期の棚卸し
  - 新しい大きな機能の検討を始める前（過去の類似 plan が眠っていないか確認）
  - `docs/rejected.md` に新エントリを追加した直後（対応する plan の status を `abandoned` に更新するため）
---

# keynaco plans/ ライフサイクル監査

## 原則

plan は書いた瞬間に時間が止まり、3 ヶ月後には「これは今でも生きているのか」を本人ですら判断できなくなる。`docs/principles.md` の「ドキュメントはコードから引き出せない情報限定」の延長で、**plan に明示的なライフサイクル状態を持たせることで、ドキュメント自体の腐敗を防ぐ**。

詳しい frontmatter 規約は [`references/plan-frontmatter.md`](references/plan-frontmatter.md) を参照。

## 使い方

リポジトリルートで以下を実行:

```bash
./.claude/skills/plans-audit/scripts/audit_all.sh
```

3 つの Step が順次実行される（個別実行は `scripts/<step>.sh` を直接呼ぶ）:

| Step | スクリプト | 何を見るか |
|---|---|---|
| 1 | `extract_status.sh` | 各 plan の status を frontmatter / legacy 記法から抽出して集計 |
| 2 | `find_stale.sh` | draft / in-progress / unknown のまま長期間更新がない plan を検出（既定 30 日） |
| 3 | `verify_references.sh` | `related_commit` / `related_rejected` / `superseded_by` の実在を確認 |

stale 判定の閾値を変えるには環境変数:
```bash
PLANS_AUDIT_STALE_DAYS=90 ./scripts/audit_all.sh
```

## triage の進め方

スクリプトの出力を読んで、各 plan を以下のいずれかに分類する:

### 1. status が unknown の plan（legacy）

72 件以上の legacy 状態があるので **一気には片付けない**。優先順位:

1. **最近触った（直近 30 日以内）** unknown → frontmatter を追加して `status: in-progress` or `draft`
2. **古い（30 日以上前）unknown** → ファイル内容を読み、以下のいずれか:
   - 実装完了している（git log でコミット履歴から判断可）→ `status: implemented` + `related_commit`
   - 検討して捨てた → `status: abandoned` + `rejected.md` にエントリ作成 + `related_rejected`
   - より新しい plan に置き換わった → `status: superseded` + `superseded_by`
   - 判断が付かない → 保留（次回 triage に持ち越す）

backfill は 1 回のセッションで 5-10 件ずつが現実的。

### 2. stale plan（30 日以上更新なし）

`find_stale.sh` の出力に挙がる plan は「**忘れられた**」候補。各々について:

- まだ着手意欲があるなら触る（追記 or 状態更新）
- 着手しないなら `status: abandoned` で凍結
- より新しい plan に置き換わったなら `status: superseded`

放置すると次回も同じリストに上がる。

### 3. 参照不整合のある plan

`verify_references.sh` で検出された不整合は **即座に修正**:

- `related_commit` が存在しない → コミット ID を git log から再特定するか削除
- `related_rejected` が rejected.md にない → rejected.md にエントリを作成するか参照を削除
- `superseded_by` が plans/ にない → ファイル名タイポか、後継 plan が消えた

## やってはいけないこと

- **legacy plan を全件一気に backfill**: 72 件もあるので、丁寧にやろうとして頓挫するパターン。1 セッション 5-10 件ずつ
- **status を勝手に推測して付ける**: 「implemented っぽい」だけで `implemented` を付けるのは禁止。`related_commit` で確証を取れない場合は `unknown` のままにする
- **`abandoned` を付けるだけで rejected.md にエントリを作らない**: `principles.md` の「『記録』と『照会』は疎結合にしておく」原則で、捨てた理由を別途残す価値がある。`related_rejected` 付け忘れは Step 3 で検出される

## 不変条件

- `status: implemented` を付けるなら `related_commit` を必ず書く（Step 3 が検出する）
- `status: abandoned` を付けるなら `rejected.md` にエントリを作成し `related_rejected` で結ぶ
- スクリプトは **read-only**。書き換えは人間が判断する

## TODO（将来）

- [ ] frontmatter なしの新規 plan を作成しようとした場合に警告する pre-commit hook
- [ ] `status: abandoned` の plan が rejected.md にエントリ化されているかの逆方向チェック
- [ ] git log と `related_commit` の妥当性確認（コミットが本当に plan の内容を実装しているか）— 現状は cat-file で存在チェックのみ

## 関連

- [`references/plan-frontmatter.md`](references/plan-frontmatter.md): frontmatter スキーマと書き方
- `docs/principles.md`「ドキュメントはコードから引き出せない情報限定」
- `docs/rejected.md`（abandoned plan の行き先）
- `.claude/skills/docs-audit/SKILL.md`（姉妹スキル: ドキュメント全般の drift 検出）
