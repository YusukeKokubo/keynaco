# ワークアラウンド監査（macOS 26 / Swift 6）

作成: 2026-06-05  
status: **reference**（外部レビュー + コード調査の記録。未実装の整理候補あり）

## 背景

keynaco の IME 層に残る「ワークアラウンド／回避策」について、2026 年時点の macOS 26（Tahoe 系）と Swift 6 strict concurrency を前提に必要性を仕分けした。主な入力は Gemini へのプロンプト応答。本リポジトリのコード調査（`InputController`・`MarkedTextSync`・`LeftContextSource`・`InputHandler+NormalInput`）で突合済み。

**目的**: 削除してよいものと触ってはいけないものを固定し、今後のリファクタ・軽量化の判断コストを下げる。

**正本**: 挙動の詳細は各ファイルの `///` とテスト。本 PLAN は「なぜ残すか／いつ外すか」のみ。

---

## 仕分け一覧

| ID | 今も必要？ | 根拠（macOS 26 / Swift 6） | 代替・簡素化 | 検証手順 |
| --- | --- | --- | --- | --- |
| **A-1** | **必須** | TIS がサードパーティ IME を列挙する際、Bundle ID に `inputmethod` を含めないと `TISRegisterInputSource` は成功しても `TISCreateInputSourceList` に出ない（サイレント失敗の実績）。 | なし。 | `inputmethod` を含まない Bundle ID でビルドし、システム設定の入力ソースに現れるか確認。 |
| **A-2** | **必須** | IMK は ObjC ランタイムのクラス名探索に依存。Swift モジュールプレフィックス付き名は解決されない。 | `@objc(InputController)` 継続。Info.plist は `InputController`（`keynaco.InputController` 不可）。 | `@objc` を外してアクティブ化時に `IMKServer` がコントローラを生成できるか。 |
| **A-3** | **必須** | `inputText` は文字入力のみ。矢印・Tab・Enter・Esc 等は `handle(_:client:)` で受ける必要がある。 | なし。 | `handle` なしで矢印・Tab が IME に届くか。 |
| **A-4** | **推奨** | `IMKCandidates` はメンテ停滞・描画不安定の報告が多い。macOS 26 実機で `selectCandidate` が動作しなかった経験あり。 | 現状の `NSPanel` + `NSTableView`（`CandidateWindow`）維持。 | 一時的に `IMKCandidates` に戻し Electron 等で選択・描画が破綻しないか。 |
| **A-5** | **推奨** | `super.setValue` 呼び出しで IMK が純正 IME 向けモード切替を強制し、自前の `isAsciiMode` と競合してルーティングが壊れる。 | `super` を呼ばず自前状態のみ更新（現状の空 override）。 | `super` 復帰後、メニューバーから英数/かなを連打して入力不能になるか。 |
| **A-6** | **仕様** | Development 署名で `spctl -a` が rejected されるのは Gatekeeper の仕様。ワークアラウンドではない。 | 配布時は Developer ID + Notarization。 | 公証済み pkg で `spctl -a -vvv`。 |
| **B-1** | **必須**（意図確定 2026-06-05） | 入力ソース切替時、`activateServer` のあと **同じ英数/かなキーが `handle` に echo** される（bc3c628）。`ignoreNextModeSwitch` はその 1 回だけ無視。セット箇所は `activateServer` のみ（英数押下の二重送信ではない）。 | 削除不可（Core テスト `InputHandlerAsciiTests` で echo 挙動を固定）。IMK 実機で echo が消えたら削除再検討。 | 入力ソース切替直後に意図せず ASCII/かなになるか。 |
| **B-2** | **仕様** | Caps Lock は `inputText` に来ない。`flagsChanged` で LED と `isAsciiMode` を同期するのが正しい。 | なし。 | Caps Lock でモードが期待どおりか。 |
| **B-3** | **仕様** | `characters` / `baseCharacters` の使い分けは US/JIS 差の正しい `NSEvent` の使い方（Bracket モード等）。 | なし。 | US/JIS で Shift+`,` `.` 等の Bracket 遷移。 |
| **C-1** | **必須** | Electron/Chromium は空 marked text で IME 非アクティブと誤認し Enter をアプリに流す。2026 年も報告あり。 | `MarkedTextSync` で候補選択中は実テキストを marked に渡す。 | `MarkedTextSync` 無効化後、VS Code/Cursor で候補中 Enter が改行暴発するか。 |
| **C-2** | **要検証** | 未消費キー（`consumed == false`）でも `applyPostKeyDownEffects` を実行（冪等同期の意図）。macOS 26 で引っ掛かりの原因になり得る。 | `consumed == true` のみに絞る、または副作用を種類別に分離。 | リファクタ後、高速タイピング・矢印移動で marked 遅延や Electron 退行がないか。 |
| **C-3** | **必須** | Terminal/Electron 等で `selectedRange()` が `NSNotFound`。無理に surrounding を使うとクラッシュやゴミ文脈。 | `LeftContextSource.assembleProduction` のガード・キャッシュ破棄を維持。 | ガード外しで Terminal / Cursor 内蔵ターミナルで BS 連打・変換。 |
| **D-1** | **必須** | IMK SDK が Swift 6 `@MainActor` 隔離に未対応。`handle` / `init` は nonisolated のため `assumeIsolated` / `nonisolated(unsafe)` が現実解。 | **将来**: IMK 薄ブリッジ + `@MainActor` Session（IMKSwift 等を参考に別 PLAN）。 | `assumeIsolated` 除去でコンパイルエラーを確認。 |
| **D-2** | **仕様** | `KanaKanjiConverter` / Zenzai `llama_context` は非スレッドセーフ。`LockedConverter`（NSLock）は必須。 | ロック削除不可。Actor への閉じ込めは改善候補（`Task.detached` の `commit` 経路含む）。 | ロック外しで変換連打時 SIGABRT。 |
| **E-1** | **仕様** | `hiddenPendingN`（`nn` → ん + 非表示 n）は標準的ローマ字処理。 | なし。 | `InputHandlerZSequenceTests` / 組成テスト。 |
| **E-2** | **整理済**（2026-06-05） | 旧 `hasBigramContext` → `shouldRefreshWhileTypingAfterCommit`。実態は `lastCommittedOutput != nil` かつ組成非空で whileTyping 再構築。 | 挙動変更・条件見直しは別 PR・sandbox。 | 条件を常に true/false に固定して 1 文字目サジェストの差分確認。 |
| **E-3** | **仕様** | 同一ターン内の handler 状態は pre 退避必須（1 キー遅延バグの実績）。 | なし。 | `CLAUDE.md`「キー入力の挙動」参照。 |

---

## keynaco 側の補足（Gemini 回答との差分）

| 項目 | 補足 |
|------|------|
| A-1 | Gemini は「`.inputmethod.`」と記載したが、本リポジトリの記録・実装は **ID に `inputmethod` 文字列を含む**（例: `com.yusuke.inputmethod.keynaco`）。厳密なドット区切り形式は未検証。 |
| B-1 | `ignoreNextModeSwitch = true` は **`activateServer` のみ**（`InputController.swift`）。`handleModeSwitchKey` が英数(102)/かな(104)を消費。`InputHandlerAsciiTests` に echo 無視テスト追加（2026-06-05）。 |
| C-2 | `runKeyDown` は consumed に関係なく `applyPostKeyDownEffects` を呼ぶ（203–204 行付近の意図）。狭める場合は marked 同期と surrounding 更新を分離検討。 |
| E-2 | `addRomaji` は `count >= 2` まで `needsRefresh == false`。`shouldRefreshWhileTypingAfterCommit` があると **確定直後の 1 文字目だけ** 余分に `buildCandidateList` が走る。 |

### 関連ファイル

| 領域 | パス |
|------|------|
| キー・副作用 | `keynaco/InputController.swift` |
| 左文脈 | `keynaco/InputController+LLM.swift`, `Core/Sources/Core/LeftContextSource.swift` |
| marked text | `Core/Sources/Core/MarkedTextSync.swift` |
| モード・組成 | `Core/Sources/Core/InputHandler.swift`, `InputHandler+NormalInput.swift`, `CompositionState.swift` |
| AzooKey 直列化 | `Core/Sources/Core/AzooKeyConverter.swift` |
| ドキュメント | `CLAUDE.md`（macOS 26 IME の罠） |

---

## 結論

### 外すな（リグレッション確実）

1. **C-1** — `MarkedTextSync`（Electron 候補中 Enter）
2. **C-3** — `selectedRange` / location ガード（左文脈・Zenzai）
3. **A-1 / A-2** — TIS 列挙条件・`@objc` エクスポート

### まず整理してよい（リスク低〜中、要テスト）

1. ~~**E-2** — `hasBigramContext` のリネーム・コメント~~ ✅ 2026-06-05（`shouldRefreshWhileTypingAfterCommit`）
2. **C-2** — 未消費キーでの post-effects 限定化
3. **B-1** — 必須（activateServer のモードキー echo）。IMK 実機で echo 消滅確認まで削除不可

### 大規模 refactor 候補（別 PLAN）

- **D-1** — IMK ブリッジ + `@MainActor` ロジック分離（IMKSwift 参照）
- **D-2** — `AzooKeyConverter` の Actor 化（ロックは直列化のまま）

---

## 未着手アクション（任意）

| Step | 内容 | 完了条件 |
|------|------|----------|
| 1 | B-1 IMK 実機（入力ソース切替直後のモード） | echo 消滅時のみ削除再検討。Core テストは 2026-06-05 追加済 |
| 2 | ~~E-2 リネームのみ PR~~ | ✅ 2026-06-05 — `InputHandler+NormalInput.swift` |
| 3 | C-2 `consumed` 限定 PR | sandbox: marked 同期・VS Code/Cursor Enter・高速入力 |
| 4 | ~~B-1 フラグ削除 PR~~ | 保留 — echo は Core で再現固定。IMK 実機で消滅確認が必要 |

---

## 追加調査キーワード（英語）

- `InputMethodKit Swift 6 strict concurrency`
- `TISRegisterInputSource macOS sandboxing`
- `NSTextInputClient selectedRange NSNotFound Electron`
- `vChewing IMKSwift IMKInputSessionController`

---

## 関連

- 入力パイプライン簡素化: [`PLAN260523d.md`](PLAN260523d.md)（Step 4 `bracketOptions` 間引きは未着手）
- パフォーマンス: [`PLAN260501.md`](PLAN260501.md)（AzooKey LRU は `AzooKeyConverter.candidateCache` に統合済み）
- メタルール: [`docs/retrospectives.md`](../docs/retrospectives.md)（フラグ横断・実機検証）

## 不確実性

- **B-1**: 英数押下の二重送信ではなく activateServer の echo（bc3c628）。削除は IMK 実機で echo 消滅を確認してから。
- **A-4**: `IMKCandidates` の macOS 26.1+ での改善は未再確認。
- 外部ソース（IMKSwift / vChewing / ブログ）は設計参考であり、keynaco の採否は本リポジトリの regression + sandbox が正本。
