まず現在の実装を調べるよ。

（調査後）

## 現状の把握

`sessionTextBuffer` は Zenzai（LLM 変換）の左文脈として使われとるバッファ。問題は `activateServer` のここ：

```swift
// InputController.swift:105
ic.handler.sessionTextBuffer = ""
```

アプリ切替（別ウィンドウにフォーカスが移って戻ってくる）のたびに `activateServer` が呼ばれ、バッファがゼロクリアされとる。つまり「同一セッション内のみ記録」になっとる。

---

## 実装方針の提案

### 方針A: `UserDefaults` にバッファを永続化する（シンプル）

`activateServer` でリセットせず、前回の末尾を `UserDefaults` から復元する。

```swift
// activateServer 内
let saved = UserDefaults.standard.string(forKey: "sessionTextBuffer") ?? ""
ic.handler.sessionTextBuffer = saved
```

確定のたびに `appendToSessionBuffer` の後で `UserDefaults` に保存する。

**問題点**:
- `sessionTextBuffer` は最大 50 字で滑り窓なので永続化しても大した情報量はない
- 再起動をまたいでも前回の文脈が残り続けるので「古い文脈で誤プロモーション」が起きうる
- アプリ（クライアント）をまたいで 1 本のバッファを共有するため、「Slack の文脈で Xcode を変換」みたいな混線が発生する

### 方針B: アプリ別・時刻つき文脈を SQLite に保存する（推奨）

`DatabaseManager` に `recent_context` テーブルを追加する。

```sql
CREATE TABLE IF NOT EXISTS recent_context (
    bundle_id TEXT NOT NULL,
    context   TEXT NOT NULL,
    saved_at  INTEGER NOT NULL,
    PRIMARY KEY (bundle_id)
);
```

- `deactivateServer` 時に `(currentAppBundleID, sessionTextBuffer, now)` をアップサート
- `activateServer` 時に同じ `bundle_id` かつ `saved_at` が 30 分以内なら復元、古ければ空スタート

これでアプリごとに文脈が分かれ、古くなったら自然に消える。

### 方針C: IMK の `surroundingText` を activateServer で取得して補完する

`activateServer` の直後に `SurroundingIMKContext.fetch` を呼んでカーソル前テキストを取得し、それを `sessionTextBuffer` の初期値にする。

**問題点**:
- `activateServer` のタイミングは IMK 的に `surroundingText` がまだ取得できないことがある（既存コードでも `composedHiragana` が空→非空になるタイミングで取得する理由がこれ）
- 長い文書のカーソル前テキストが 50 字以上あっても正しく使える
- ただし、アプリが `surroundingText` を返さない場合（Electron 系等）は効かない

---

## 実際に何が「フレーズ」か確認

「フレーズ記録」という言葉が `sessionTextBuffer` を指しとるか、`committedHistory`（N-gram 的な直前確定語バッファ）を指しとるか、どちらやろか？

- `sessionTextBuffer`: Zenzai 左文脈用、最大 50 字の滑り窓テキスト
- `committedHistory`: 最大 5 件の直前確定語リスト（Zenzai・AzooKey の左文脈候補として使う）

`committedHistory` も `activateServer` で `[]` リセットされとる（105 行目 `ic.handler.committedHistory = []`）。

---

## 推奨実装（方針B）の具体的な変更点

1. **`DatabaseManager+History.swift`** か新しい `DatabaseManager+Context.swift` に `saveContext` / `loadContext` メソッドを追加
2. **`InputController.swift`**:
   - `deactivateServer`: `handler.sessionTextBuffer` と `handler.committedHistory` を保存
   - `activateServer`: `sessionTextBuffer = ""` を復元ロジックに置き換え（30 分以内のみ）
3. **`InputHandler.swift`** の `appendToSessionBuffer` は変更なし

まず「フレーズ記録」が `sessionTextBuffer` と `committedHistory` のどちら（あるいは両方）を指しとるか確認させてほしい。それによって実装の細かい部分が変わってくるで。
