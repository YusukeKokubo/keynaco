---
name: docs-audit
description: |
  keynaco リポジトリのドキュメント（CLAUDE.md・docs/**/*.md・.claude/skills/**/SKILL.md・memory ファイル）と実装の整合性を機械的にチェックし、drift している記述・削除済み機能への残存参照・嘘の主張を洗い出す監査スキル。

  次のような場面で積極的に使うこと:
  - ユーザーが「ドキュメントと実装の整合性を確認して」「drift チェックして」と言ったとき
  - 大きなリファクタリング・機能削除・コミット後に副作用としてのドキュメント陳腐化を確認したいとき
  - 月次ペースの定期点検（手動運用 or `/schedule` 経由）
  - 新規参入者ガイドを更新する前
  - `rejected.md` に新エントリを追加した直後（削除済み機能の残骸チェック）
---

# keynaco ドキュメント整合性監査

## 原則

`docs/principles.md` の「ドキュメントはコードから引き出せない情報限定」「memory・ドキュメントを引用する前に grep verify」を実行手順化したもの。drift しているドキュメントは無いより悪い（嘘の能動的拡散）ので、機械的に検出する。

## 監査の流れ

各 step は **コード = 真実、ドキュメント = 派生** という前提で進める。ドキュメント記述がコードと食い違うときはドキュメントを直す（コードを直すことは原則ない）。

### Step 1: ドキュメント内の識別子の実在確認

`docs/` 配下と CLAUDE.md・SKILL.md にバッククォート付きで現れる識別子（関数名・型名・フラグ名・テーブル名・ファイル名）が、現コードベースに実在するか grep で照合する。

```bash
# 識別子を抽出（バッククォート囲み・英字始まり・3文字以上）
grep -rhoE '`[A-Za-z][A-Za-z0-9_+/.]{2,}`' \
  /Users/yusuke/work/ykey/CLAUDE.md \
  /Users/yusuke/work/ykey/docs/ \
  /Users/yusuke/work/ykey/.claude/skills/*/SKILL.md \
  2>/dev/null \
  | sed 's/`//g' | sort -u > /tmp/doc-identifiers.txt

# コード側に存在しないものを抽出
while read id; do
  # ファイル名っぽいものはファイル探索、それ以外は中身検索
  if echo "$id" | grep -qE '\.(swift|md|py|json)$'; then
    test -z "$(find /Users/yusuke/work/ykey -name "$id" -not -path '*/.build/*' -not -path '*/checkouts/*' 2>/dev/null)" && echo "MISSING_FILE: $id"
  else
    grep -rqE "(\b|\.)$(echo "$id" | sed 's/[+]/\\+/g')(\b|\()" \
      /Users/yusuke/work/ykey/Core/Sources \
      /Users/yusuke/work/ykey/keynaco \
      /Users/yusuke/work/ykey/keynacoTests \
      --include="*.swift" 2>/dev/null \
      || echo "MISSING_SYMBOL: $id"
  fi
done < /tmp/doc-identifiers.txt
```

**誤検出が多い場合**: 一般的な英単語（`true`/`false`/`Optional` 等）は除外する。Swift 標準型もノイズになる。

### Step 2: 削除済み機能の残骸チェック

`docs/rejected.md` から「削除済み」と判定された機能名を抽出し、実装・テスト・他ドキュメント・memory に残存していないか確認する。

```bash
# rejected.md から見出しを抽出
grep -E "^## " /Users/yusuke/work/ykey/docs/rejected.md

# 個別に grep（例: Successor が削除済みなら）
grep -rn "Successor\|isSuccessorCandidateActive" \
  /Users/yusuke/work/ykey/keynaco \
  /Users/yusuke/work/ykey/Core/Sources \
  /Users/yusuke/work/ykey/.claude/skills \
  /Users/yusuke/work/ykey/CLAUDE.md \
  /Users/yusuke/work/ykey/docs \
  2>/dev/null \
  | grep -v "rejected.md"
```

**判定**: `rejected.md` 自身は記録目的なので削除済み機能名が登場するのは正しい。**それ以外のファイル**に登場するのは drift。

### Step 3: 数値の整合性

「N テーブル」「N タブ」「N ファイル」のような **数値主張** は drift しやすい。実装側の宣言と照合する。

```bash
# DB テーブル数: CREATE TABLE の出現数
grep -c "CREATE TABLE IF NOT EXISTS" /Users/yusuke/work/ykey/Core/Sources/Core/DatabaseManager.swift

# Settings タブ数: addTabViewItem の出現数
grep -c "addTabViewItem" /Users/yusuke/work/ykey/keynaco/Settings/SettingsWindowController.swift

# Settings ファイル数
ls /Users/yusuke/work/ykey/keynaco/Settings/ | wc -l
```

ドキュメントの記述（例: 「5 テーブル」「6 タブ」「9 ファイル」）と一致しなければ drift。

### Step 4: memory の verify

`~/.claude/projects/-Users-yusuke-work-ykey/memory/MEMORY.md` を読み、各 memory ファイル冒頭の `originSessionId` や作成日が古いものは内容を grep verify する。

```bash
# memory 一覧
ls /Users/yusuke/.claude/projects/-Users-yusuke-work-ykey/memory/

# 各 memory に登場する識別子をコードベースに照合（手動 step）
```

stale な memory を見つけたら、内容を現状に合わせて更新するか、不要なら削除する。

### Step 5: CLAUDE.md / SKILL.md 内の重複検出

CLAUDE.md とプロジェクト memory（feedback/project タイプ）・SKILL.md が同じ情報を重複保持していないか確認する。重複は drift の温床。**1 箇所に寄せる**のが原則:

- 「セッション横断で常に効かせたい preference」→ memory
- 「プロジェクト固有の永続情報」→ CLAUDE.md
- 「skill 起動時に必要なコンテキスト」→ SKILL.md

## 報告フォーマット

監査結果は重大度別にまとめる:

```markdown
## 重大度別サマリ

### 🔴 High（嘘の記述・能動的誤情報）
- `docs/foo.md:LL`: X と書いているが実コードは逆。修正必須

### 🟡 Medium（古い・実状とズレ）
- `CLAUDE.md:LL`: N タブと書いているが実装は M タブ

### 🟢 Low（軽微・残骸）
- `keynaco/Debug/Bar.swift:LL`: 削除済み機能のキー名が残存（無害だが原則違反）
```

各項目に **ファイルパス:行番号** を必ず付ける。修正可能なものは具体的な書き換え案を提示する。

## やってはいけないこと

- **コードを書き換えてドキュメントに合わせる**: 原則として禁止。コードが真実、ドキュメントが派生。例外は「ドキュメントの方が正しく、コードがバグっている」と判明したときのみで、その判定には別途証拠（テスト・コミットメッセージ・rejected.md エントリ）を要する
- **rejected.md の機能名を削除する**: rejected.md は記録目的なので削除済み機能名が登場するのは正しい。drift とは別カテゴリ
- **整合させるためにドキュメントを書き足す**: 「N テーブル」を 6 から 7 に更新するなら良いが、新しい behavior spec を docs/ に追記するのは原則違反。`///` コメントに書く

## 不変条件

- 監査は **read-only 中心**。発見した drift を修正する場合も、ユーザーに修正計画を提示してから着手する
- 「すべて整合している」と報告する前に、少なくとも Step 1〜3 を実行している
- 監査スクリプトを `scripts/` に永続化したくなったら、それは別途 PR とする（このスキル自身は手順書）

## 関連

- `docs/principles.md`「ドキュメントはコードから引き出せない情報限定」
- `docs/principles.md`「memory・ドキュメントを引用する前に grep verify」
- `docs/rejected.md`（削除済み機能の正本）
