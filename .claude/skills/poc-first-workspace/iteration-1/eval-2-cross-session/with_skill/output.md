# POC-first: フレーズ記録のセッション横断化

## Step 1: 仮説を言語化する

コードを読んで現状を整理したうえで仮説を立てるで。

---

**【機能】** セグメントモードで確定した複数文節の結合フレーズ（例：「たなかたろう」→「田中太郎」）を、次回 IME 起動後（セッションをまたいだあと）の変換にも使えるようにする

**【課題】** 今の「同一セッション内だけ」という認識がどこから来ているか確認が必要。コードを読んだ時点での観察：

- `doConfirmSegments` の `db.recordPrefixes(reading: fullReading, output: confirmed)` は SQLite（`DatabaseManager.shared`）への永続書き込みであり、構造上はセッションをまたいで機能するはず
- `activateServer` でクリアされるのは `committedHistory`・`sessionTextBuffer`・`leftSideContext` の 3 つ（メモリ上のみ）
- `buildSegmentCandidates` は `fetchHistoryExact` / `fetchHistoryPrefix` で SQLite を読んでいる

**→ 「同一セッション内だけ」の意味が 2 通り考えられる：**

| 解釈 A | 解釈 B |
|--------|--------|
| `recordPrefixes` は動いているが、**セグメントモード内のキャッシュ** `segmentCandidateCache` が再起動でクリアされるため、次のセッションで候補が異なる位置に出る | Zenzai 左文脈（`sessionTextBuffer`）がセッション内のみ保持されるため、Zenzai プロモートが効かない = フレーズが「再現しない」と感じている |

**【仮説】** 仮に解釈 A が正しければ、`recordPrefixes` がすでに SQLite に書いているため、実装は不要（すでに動いている）。解釈 B が正しければ、Zenzai 左文脈の永続化が課題。

**【前提条件の確認が必要】** 「田中太郎」を一度セグメントモードで確定 → IME を再起動 → 再び「たなかたろう」と打ったとき、history テーブルに `(input="たなかたろう", output="田中太郎")` があるかを確認することで前提を裏付けられる。

---

## Step 2: 最小の検証を設計する

| 検証したいこと | 使うツール |
|---|---|
| `doConfirmSegments` 後に SQLite に `fullReading → confirmed` が書かれているか | sandbox の `seed_history` 相当 or `debug_ime.py` で確定後に `db.fetchHistoryExact` の結果を確認 |
| 再起動後に同じフレーズがセグメント候補に出るか | sandbox で reset → 入力シーケンスを送って `candidates` を確認 |
| `sessionTextBuffer` がセッション外で Zenzai に影響しているか | sandbox で `set_left_context` を使って左文脈ありの場合と比較 |

**合否基準（先に決める）：**

- SQLite に `(たなかたろう, 田中太郎)` が入っていて、reset 後も `buildSegmentCandidates` の `fetchHistoryExact("たなかたろう")` で拾えるなら → **すでにセッションをまたいで機能している。実装不要。**
- 入っていない、または入っていても候補に出ない → 実装が必要（どのパスで漏れているか特定する）

---

## Step 3: sandbox で確認すべき具体的コマンド

```python
# 1. セグメントモードで「たなかたろう」を確定させてフレーズ記録を発生させる
send({"reset": True})
send({"type_string": "tanakataro", "then": "space"})  # セグメントモード入り
# Enter で確定 → doConfirmSegments が呼ばれ db.recordPrefixes("たなかたろう", "田中太郎") のはず

# 2. reset（activateServer 相当）後に候補を確認
send({"reset": True})
r = send({"type_string": "tanakataro", "then": "space",
          "fields": ["candidates", "isSegmentMode", "segmentTexts"]})
print(r["candidates"])  # 「田中太郎」が先頭付近に出るか？
```

**ただし注意：** sandbox の `reset` が `activateServer` と同じかどうかを確認すること。`DatabaseManager.shared` は同一プロセス内で使い回されるため、プロセス再起動との区別が重要。

---

## Step 4: 判断する前にやること

実装に入る前に **sandbox で実際に確認**してほしい。

```
【確認してほしいこと】
1. 「たなかたろう」をセグメントモード（Space）で「田中」+「太郎」に確定
2. reset して再度「たなかたろう」→ Space でセグメントモード
3. candidates に「田中太郎」が出るか確認

出るなら → recordPrefixes がすでに機能していて、
           「セッション内だけ」は Zenzai 左文脈の話だと判明する
出ないなら → どのパスで SQLite 書き込みが漏れているか特定が必要
```

---

## SKILL.md の落とし穴メモが示す教訓

> 「フレーズ記録は `commitComposition` に同じコードがすでにあり、`doConfirmSegments` の漏れだった——コードを読んでいれば計画段階で分かった」

今回は逆で、コードを読むと `doConfirmSegments`（SegmentMode.swift:294）と `commitComposition`（InputHandler.swift:215）の**両方に**フレーズ全体の `recordPrefixes` が実装されているのが見える。つまり実装自体は存在する。

**「同一セッション内だけ」という体験が事実なら、sandbox で再現させてから原因を特定する。今すぐ実装を追加するのは早い。**

---

## まとめ

| ステータス | 内容 |
|-----------|------|
| 要確認 | sandbox で「セグメント確定 → reset → 再入力」で候補が出るか確認 |
| 仮説 A（有力） | recordPrefixes は SQLite に書いており、セッションまたぎは**すでに動いている**可能性がある |
| 仮説 B | Zenzai 左文脈（sessionTextBuffer）のセッションまたぎを望んでいる → これは別の機能要求 |
| 実装判断 | sandbox の結果を見てから決める |

`/keynaco-ime-sandbox` スキルで上記の確認をしてからまた話し合いましょうか？
