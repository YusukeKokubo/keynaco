# POC-first: フレーズ記録のセッション横断化

## Step 1: 仮説を言語化する

コードを読んで現状を整理したうえで仮説を立てる。

---

**【機能】** 確定したフレーズ（例：「たなかたろう」→「田中太郎」）を、次回 IME 起動後（セッションをまたいだあと）の変換候補にも使えるようにする

**【課題】** 「同一セッション内だけ」という認識がどこから来ているか、まず確認が必要。コードを読んだ時点での観察：

- `recordPrefixes` / `db.record` は SQLite（`DatabaseManager.shared`）への永続書き込みであり、**プロセス再起動後も残る**
- `activateServer` でクリアされるのは `committedHistory`・`sessionTextBuffer`・`leftSideContext` の 3 つ（**メモリ上のみ**）
- 候補組み立て（`buildCandidateList`）は `fetchHistoryScoredMerged` 等で SQLite を読む
- **2026-06-04 以降、セグメントモード（Space → 文節分割確定）は削除済み**（[`docs/rejected.md`](docs/rejected.md) I-1）。Space は候補窓表示（`buildCandidateList`）に使われる

**→ 「同一セッション内だけ」の意味が 2 通り考えられる：**

| 解釈 A | 解釈 B |
|--------|--------|
| 履歴 DB には書いているが、**候補の並び・スコア**がセッション内の `committedHistory` / Zenzai 左文脈に依存しており、再起動後に体感が変わる | Zenzai 左文脈（`sessionTextBuffer`）が `activateServer` で毎回クリアされるため、Zenzai プロモートが効かない = フレーズが「再現しない」と感じている |

**【仮説】** 解釈 A が正しければ、`recordPrefixes` がすでに SQLite に書いているため、追加実装は不要（または候補順の問題）。解釈 B が正しければ、Zenzai 左文脈の永続化が別課題。

**【前提条件の確認が必要】** 「田中太郎」を一度 Enter で確定 → IME を再起動 → 再び「たなかたろう」と打って Space を押したとき、`history` テーブルにエントリがあり、`candidates` に「田中太郎」が出るかを sandbox で確認する。

---

## Step 2: 最小の検証を設計する

| 検証したいこと | 使うツール |
|---|---|
| Enter 確定後に SQLite に `reading → output` が書かれているか | sandbox + `seed_history` 相当、または `debug_ime.py` で確定後の `candidates` / `historyEnd` を確認 |
| reset（`activateServer` 相当）後も同じフレーズが候補に出るか | sandbox で reset → 入力シーケンス → Space → `candidates` を確認 |
| `sessionTextBuffer` が Zenzai プロモートに効いているか | sandbox で `set_left_context` を使い、左文脈あり/なしで候補順を比較 |

**合否基準（先に決める）：**

- SQLite に `(たなかたろう, 田中太郎)` が入っていて、reset 後も `buildCandidateList` 経由で「田中太郎」が候補に出るなら → **履歴のセッション横断はすでに動いている。追加実装は Zenzai 文脈の話か不要。**
- 入っていない、または入っていても候補に出ない → どの確定パスで書き込みが漏れているか特定する

---

## Step 3: sandbox で確認すべき具体的コマンド

```python
# 1. 「たなかたろう」を Enter で確定させて履歴記録を発生させる
send({"reset": True})
send({"type_string": "tanakataro", "then": "space"})  # 候補窓表示
send({"key": "enter"})  # commitText → db.recordPrefixes(reading:output:)

# 2. reset（activateServer 相当）後に候補を確認
send({"reset": True})
r = send({"type_string": "tanakataro", "then": "space",
          "fields": ["candidates", "historyEnd", "fixedEnd"]})
print(r["candidates"][:5])  # 「田中太郎」が history 候補として出るか？
```

**ただし注意：** sandbox の `reset` が `activateServer` と同じかどうかを確認すること。`DatabaseManager.shared` は同一プロセス内で使い回されるため、**プロセス再起動**との区別が重要。

---

## Step 4: 判断する前にやること

実装に入る前に **sandbox で実際に確認**してほしい。

```
【確認してほしいこと】
1. 「たなかたろう」を Space → 候補選択 → Enter で「田中太郎」に確定
2. reset して再度「たなかたろう」→ Space
3. candidates に「田中太郎」が出るか（historyEnd > fixedEnd か）確認

出るなら → recordPrefixes / fetchHistoryScoredMerged がすでに機能しており、
           「セッション内だけ」は Zenzai 左文脈（sessionTextBuffer）の話だと判明する
出ないなら → どの確定パスで SQLite 書き込みが漏れているか特定が必要
```

---

## よくある落とし穴（現行コード向け）

**セグメントモード前提で議論しない**  
Space → 文節分割は 2026-06 削除済み（rejected.md I-1）。デバッグ JSON の文節専用フィールドも廃止。

**「フレーズ記録」が何を指すか先に切り分ける**

| 対象 | 永続化 | セッションまたぎ |
|------|--------|------------------|
| `recordPrefixes` → SQLite `history` | ✅ | ✅（DB は残る） |
| `sessionTextBuffer`（Zenzai 左文脈） | ❌ | ❌（activateServer でクリア） |
| `committedHistory`（直近確定語リスト） | ❌ | ❌（同上） |

**Phase 2 に飛ばない**  
セッション横断の「体感」が本当に足りないか、まず Phase 1（上記 sandbox 確認）で測る。履歴がすでに効いているなら、永続化実装は過剰。

---

## まとめ

| ステータス | 内容 |
|-----------|------|
| 要確認 | sandbox で「Enter 確定 → reset → 再入力 → Space」で履歴候補が出るか確認 |
| 仮説 A（有力） | SQLite 履歴は**すでにセッションをまたぐ**。体感差は Zenzai / committedHistory のメモリ限定が原因の可能性 |
| 仮説 B | Zenzai 左文脈（sessionTextBuffer）の永続化を望んでいる → 別機能要求（コスト・混線リスクあり） |
| 実装判断 | sandbox の結果を見てから決める。Phase 1 の効果が測れないうちに Phase 2（永続化設計）に入らない |

`/keynaco-ime-sandbox` スキルで上記の確認をしてからまた話し合いましょうか？
