---
status: in-progress
created: 2026-06-12
---

# PLAN260612: 候補生成の非同期二段階化 — 打鍵エコーを AzooKey から切り離す

前提資料: [IDEA260612](../ideas/IDEA260612.md)（ホットパス計測）、[rejected.md P-1](../docs/rejected.md)（短読みスキップの失敗）

## 体感速度の正体 — CPU 総量ではなく同期ブロッキング

IDEA260612 の計測で AzooKey（`Kana2Kanji.kana2lattice`）が CPU の大半を占めることは分かった。ただし「ユーザーが遅いと感じる」のは CPU 使用率ではなく、**キーを押してから画面が反応するまでの待ち時間**である。現状のパイプラインを追うと、その待ち時間の構造はこうなっている。

```
keyDown（IMK, Main Thread）
  └─ handler.handle()
       └─ buildCandidateList(.whileTyping)
            └─ azooKeyConverter.requestCandidates()   ← 辞書 lattice + Zenzai 推論を同期実行
  └─ applyPostKeyDownCandidateAndIMK()
       └─ syncMarkedText()                            ← 打った文字が画面に出るのはここ
  └─ applyCandidateWindowEffects()                    ← 候補ウィンドウ更新
```

`requestCandidates` が返るまで marked text の更新すら走らない。つまり **AzooKey の変換時間がそのまま「打った文字が表示されるまでの遅延」になっている**。これが構造上の問題であり、AzooKey 内部の `SetAlgebra.init` がいくら速くなっても、同期で待つ限り Zenzai 推論分の遅延は消えない。

ここから導かれる抜本案は一つ: **打鍵エコー（marked text）と安価な候補は即時に返し、AzooKey は非同期で呼んで結果が届いたら候補を差し替える**。IDEA260612 の案 A（デバウンス）の正式設計がこれにあたる。

計測済みの事実が設計を後押しする:

- DB（履歴・ユーザー辞書）・数値/日時候補・`assembleCandidateList` のコストは計測上ほぼゼロ → 「AzooKey 抜きの即時候補」は実質タダで作れる
- `AzooKeyConverter` は `LockedConverter`（NSLock）で全アクセスが直列化済み。`commit()` が既に `Task.detached` から呼んでいる前例があり、背景スレッドからの `requestCandidates` 呼び出しは安全
- `CandidateAction` には `.replaceCandidates` が既にあり、表示中リストの差し替え経路の原型が存在する
- `candidateCache`（read-through LRU）があるため、非同期で温めたキャッシュは後続の同期呼び出しにも効く

## P-1 の失敗を踏まえた違い

P-1（短読みスキップ）は「読みの長さ」で AzooKey の呼び出し可否を判定して失敗した。2 文字完成語が存在する以上、**入力内容から「途中か完成か」は判定できない**。本案は判定をしない。すべての読みで AzooKey を呼ぶが、呼ぶタイミングを「打鍵の同期処理内」から「打鍵後の非同期」へ移すだけなので、候補の最終的な内容は変わらない。デバウンスによる呼び出し回数削減は副産物であって、本質は**エコーのブロッキング解消**にある。

## Phase 0: Release ビルドでの再計測（実装前の関門）

IDEA260612 の計測は **Debug ビルド**だった。ホットスポットの `SetAlgebra.init(arr...)` はジェネリクスの未特殊化コストを多分に含むため、Release（-O + whole-module optimization）では大きく縮む可能性がある。構造的なブロッキングは Release でも変わらないが、**遅延の絶対量が体感閾値を下回っているなら Phase 1 以降は不要**（案 C: 現状維持で終了）。

やること:

1. `requestCandidates` の呼び出し前後と `handle()` 全体の所要時間を `os_signpost`（または DEBUG ビルドのデバッグソケットへの計時出力）で取れるようにする
2. Release 構成でインストールし、`/keynaco-ime-sandbox` のキーシーケンス送信で per-keystroke レイテンシの p50 / p95 を取る。条件は最低 3 通り: Zenzai オフ、Zenzai オン（左文脈なし）、Zenzai オン（左文脈あり = 推論パスが動く）
3. 判断基準: **p95 が 1 フレーム（約 16ms）を超えるか**。超えないなら本 plan は abandoned にして Release 計測結果を IDEA260612 に追記して終了。超えるなら Phase 1 へ

Zenzai 推論（llama.cpp）は数十 ms オーダーになりやすく、Zenzai オン環境では閾値超えの公算が高いと予想するが、数字を取ってから進む。

### Phase 0 計測結果（2026-06-12 実施）

計測ツール: `CoreSlowTests/AzooKeyBenchmarkTests.swift`（`swift test -c release --filter AzooKeyBenchmarkTests`。fast 並列と競合しないよう slow ターゲット）と  
Debug ビルドのデバッグソケット `benchmark` コマンド（`DebugSocketServer+Commands.swift` に追加）。

| 条件 | n | mean | p50 | p95 | max |
|------|---|------|-----|-----|-----|
| **Release / Zenzai off / cold miss** | 20語 | 5.4ms | 3.9ms | **16.8ms** | 16.8ms |
| Release / Zenzai off / cache hit | 100回 | 0.0ms | 0.0ms | 0.0ms | 0.0ms |
| Debug / Zenzai off / cold miss | 20語 | 82ms | 70ms | 260ms | 260ms |
| Debug / Zenzai on / model warm / cold miss | 20語 | 97ms | 79ms | 269ms | 269ms |

Debug→Release の高速化倍率は AzooKey の Swift コード部分で約 15×。

**判断: Phase 1 へ進む。**

理由:
1. Release / Zenzai off の p95 = 16.8ms — 1 フレーム（16ms）をわずかに超えた
2. Zenzai が有効かつ左文脈ありの場合、Debug で +10〜15ms の追加コスト。Release でも加算されるため確実に 16ms 超え
3. 体感遅延の根因は「AzooKey が同期で返すまで marked text（打った文字の表示）が更新されない」という構造そのもの。p95 の絶対値以上にこの構造が問題
4. キャッシュヒット時は 0ms — ボトルネックは純粋に cold-miss パス

補足: `AzooKeyConverter.requestCandidates` に `os_signpost`（Instruments / xctrace 取得用）と `os_log(.debug)` によるタイミング出力を追加済み。Release ビルドでも `log stream --predicate 'subsystem == "jp.leaner.keynaco"'` で確認できる。

## Phase 1: InputHandler に「AzooKey 注入」経路を作る（純粋ロジック、同期のまま） ✅ 2026-06-12

非同期化の前準備として、`collectCandidateSources` を「安価ソース収集」と「AzooKey 呼び出し」に分離し、**AzooKey 候補を外から渡してリストを組み立てられる経路**を public にする。

```swift
// 概形（命名は実装時に調整）
mutating func buildCandidateListWithoutAzooKey(trigger:) -> (action: CandidateAction, pendingReading: String?)
//   AzooKey 候補を空としてアセンブル。AzooKey を呼ぶべきだった場合は pendingReading に読みを返す
mutating func rebuildCandidateList(reading: String, azooKeyCandidates: [String]) -> CandidateAction
//   呼び出し時点の state.composedHiragana == reading のときだけ有効。安価ソースは再収集して合成
```

設計上の不変条件:

- 既存の `buildCandidateList(trigger:)`（同期・AzooKey 込み）は**そのまま残す**。`.explicit`（Space）経路と全ユニットテストは無変更で通り続ける
- `zenzaiPromoted` の導出・候補優先順位（ひらがな固定 → ユーザー辞書 → Zenzai → 履歴 → 数字/日時 → AzooKey）・`fixedEnd`/`historyEnd` の意味は一切変えない。`rebuildCandidateList` は同じ `assembleCandidateList` を通すだけ
- `.whileTyping` の「候補ゼロなら出さない」「機能語第一候補なら出さない」抑制は、**差し替え後の最終リストに対して**も同じ判定を適用する

この Phase は純粋 Swift のみで完結し、`InputHandler*Tests` でユニットテスト可能。コミット単位として独立。

## Phase 2: InputController に非同期オーケストレーション ✅ 2026-06-12

`.whileTyping` のときだけ、キー処理は `buildCandidateListWithoutAzooKey` の結果（即時候補 + marked text 同期）で返し、AzooKey は debounce 付きの背景タスクで呼ぶ。

コミット: `b0ffc8f`（`7847cbd` Phase 1 の上に積む）。

```
keyDown ─ 同期: 即時候補で .show / .dismiss、marked text 更新（ここまで数 ms）
        └ 非同期: debounce 60–80ms → Task.detached で requestCandidates
                  → MainActor へ hop → ガード判定 → rebuildCandidateList → 候補窓差し替え
```

InputController 側に持つ状態は 2 つだけに抑える:

- `candidateGeneration: Int` — keyDown ごとにインクリメント。非同期結果の適用時に一致しなければ破棄（古い読みの結果で上書きしない）
- `pendingAzooKeyWork: DispatchWorkItem?`（または `Task`）— 次の keyDown でキャンセル。これがデバウンスを兼ねる

差し替えを**適用しない**ガード条件（generation 一致に加えて）:

- `state.composedHiragana` が要求時の読みと不一致（組成が進んだ・消えた）
- `candidateSession.isExplicitlySelected == true`（ユーザーが矢印で選択を始めた後にリストをすり替えない）
- 組成が終了している（確定・Escape 済み）

注意点（既知の罠との突き合わせ):

- **pre/post 規約**: 非同期コールバック内で `handler.*` を読み書きする。コールバックは「次のキー以降」に相当するので post 読みで正しいが、ガード判定に使う値（読み・generation）は**タスク生成時にキャプチャ**しておくこと。コールバック時点の handler から読み直すとガードの意味がなくなる
- **Electron / marked text**: 即時経路で従来どおり実テキストを marked text に設定するため、空 marked text 問題は発生しない。差し替えは候補ウィンドウと session のみで marked text には触れない（選択行が変わらない限り）
- **Swift 6 strict concurrency**: `requestCandidates` は `AzooKeyConverter`（`@unchecked Sendable`、Lock 直列化済み）のメソッドなので `Task.detached` から呼べる。結果適用は `MainActor` へ hop。`LockedConverter` の不変条件（converter 参照をクロージャ外に出さない）には触れない
- **Lock 渋滞**: 連打中に古いリクエストが Lock 待ちで滞留しないよう、`withLock` 取得**前**に generation をチェックして stale なら呼ばずに捨てる。デバウンスがあれば実際に滞留するのは稀だが、保険として入れる

検証は 3 層: (1) Phase 1 のユニットテスト、(2) `/keynaco-ime-sandbox` E2E — 状態依存・タイミング依存の機能なので必須（feedback_e2e_state_features）。サンドボックスは差し替え完了を待ってから状態を読む必要があるため、デバッグソケットに「pending AzooKey あり/なし」を出すと決定的にテストできる、(3) `test_marked_text_sandbox.sh` の回帰。

### Phase 2 実装でわかったこと（2026-06-12）

**設計判断の着地点**

| 計画時の案 | 実装 |
|-----------|------|
| `pendingAzooKeyWork: DispatchWorkItem?` | `AzooKeyAsyncScheduler`（`Task` + generation）。`InputController` と Debug ソケットで共有 |
| `buildCandidateListWithoutAzooKey` を handle から直接呼ぶ | `deferAzooKeyWhileTyping` フラグ + `buildCandidateListForTrigger` に集約。ユニットテストはデフォルト `false` で既存同期経路を維持 |
| `.replaceCandidates` で差し替え | **未使用**。`rebuildCandidateList` が返す `.show` / `.dismiss` をそのまま `candidateSession.apply`（`historyEnd` / `zenzaiRow` / `initialRow` を落とさない） |
| `pendingAzooKeyReading` を handle 戻り値に載せる | `public private(set)` + `notePendingAzooKeyReading` / `clearPendingAzooKeyReading`（extension から `private(set)` に直接書けないため） |

**うまくいった点**

- Phase 1 の注入 API がそのまま Phase 2 の非同期適用に接続できた。`InputHandler` に `Task` を入れずに済んだ。
- `deferAzooKeyWhileTyping` により `AzooKeyCacheTests` 等の既存 fast テストは無変更のまま通る。
- 即時経路は安価ソースのみ（数 ms）で返り、AzooKey cold-miss のブロッキングが marked text から切り離された — plan の本質どおり。

**ハマった点（次に触る人向け）**

1. **Debug ソケットの `wait_azoo_key` と MainActor デッドロック**  
   同期 `processCommand` 内で `RunLoop.main.run` して pending を待つと、待っている間に `Task { @MainActor }` の AzooKey タスクが進まない。`processCommandAsync` に統一し、`wait_azoo_key` は `await azooKeyScheduler.waitUntilIdle()` で解決した。本番 IMK はキーイベント間で MainActor が自然に回るため顕在化しにくいが、サンドボックスは async 化が必須。

2. **E2E / 回帰テストのタイミング依存**  
   defer 有効時、`type_string "kanzi"` 直後は `candidates=[]`・`pendingAzooKey=true`（即時候補が空のため `.dismiss`）。Space や `↓` のテストは **`wait_azoo_key` を挟まないと失敗する**。`test_marked_text_sandbox.py` の該当シナリオと integrity check（space 前の候補リスト比較）を更新済み。

3. **`benchmark` コマンドの意味が変わる**  
   defer 有効時は `handler.handle()` 同期部分のみ計測。Phase 0 数字との比較は `wait_azoo_key` 後の end-to-end、または benchmark に `includeAzooKey` オプションを足す必要がある（未実装）。

**UX の実測印象（sandbox + 手動確認）**

- 安価ソースなしの読み（`kanzi` 等）: 打鍵直後はひらがな marked text のみ → 70ms debounce + AzooKey 後に候補窓が初出。plan の「空ウィンドウ → 充填」ではなく「ウィンドウなし → 出現」で、チラつきより「一瞬何も出ない」感の方が目立つ可能性あり。
- Space（`.explicit`）は同期 AzooKey のまま。打鍵は速くなったが **変換ボタン押下はまだ待つ** — Phase 3 の動機は実装後も有効。
- 最終候補リストは `assertInjectPathMatchesSync` / snapshot テストで同期版と一致することを確認。

**検証結果（実装時）**

- `./scripts/test_core.sh` green（`InputHandlerDeferAzooKeyTests` 追加）
- `xcodebuild test -scheme keynaco` green
- `./scripts/test_marked_text_sandbox.sh` 9/9 + integrity green（`wait_azoo_key` 挿入後）

## Phase 3（任意）: Space 即時化 — rich キャッシュの先読み ✅ 2026-06-12

`candidateCache` のキーは `richCandidates` フラグを含むため、打鍵中（`rich=false`）に温めたキャッシュは **Space 押下（`.explicit` = `rich=true`）には効かない**。Space は「変換したい」という最も体感に効く瞬間なのに、毎回フルの AzooKey + Zenzai リッチ変換を同期で待っている。

Phase 2 の非同期基盤に乗せて、デバウンス後の AzooKey 呼び出しを `richCandidates: true` で投げる（または `false` の取得後に idle で `true` も先読みする）と、Space 押下時はキャッシュヒットで即時表示になる。表示中の `.whileTyping` リストは rich 結果から従来どおりのフィルタで作れるかを確認の上、`rich=true` 一本化が成立すればキャッシュも一段シンプルになる。

### Phase 3 計測結果（2026-06-12 実施）

計測ツール: `AzooKeyBenchmarkTests`（Release）、`AzooKeyRichEquivalenceTests`（実辞書 20 語）。

| 条件 | n | mean | p50 | p95 | max |
|------|---|------|-----|-----|-----|
| Zenzai off / rich=false / cold miss | 20 | 5.6ms | 4.1ms | 17.8ms | 17.8ms |
| Zenzai off / rich=true / cold miss | 20 | 4.1ms | 2.5ms | 13.8ms | 13.8ms |
| Zenzai off / rich=true / left context | 20 | 4.1ms | 2.5ms | 13.8ms | 13.8ms |

候補リスト等価性（Zenzai off、20 語 × 文脈なし/あり）: **rich true/false 完全一致**。

Zenzai on の計測は SPM テストバンドルにモデルがないためスキップ（本番バンドルでは従来どおり動作）。

**判断: Option A（`richCandidates: true` 一本化）を採用。**

理由:
1. Zenzai off では rich 追加コストなし（同一変換・キャッシュキーのみ変化）
2. whileTyping 最終リストは rich 結果でも同期版と等価（slow テストで確認）
3. Option B（二段先読み）は AzooKey 2 回/読みで Lock 渋滞リスクが増えるだけ

### Phase 3 実装

- `AzooKeyAsyncScheduler.schedule`: `richCandidates: true` に変更。`LockedGeneration` で detached 起動前の stale 破棄
- デバッグソケット `benchmark`: `includeAzooKey: "space"` で type → `wait_azoo_key` → Space `handle()` 計測（async 経路）
- 同期 benchmark も `onKeyDown` + `scheduleSandboxAzooKeyIfNeeded` 経路に揃えた

### 検証結果

- `./scripts/test_core.sh` green（`AzooKeyRichPrefetchCacheTests`・`InputHandlerDeferAzooKeyTests` rich 検証追加）
- `keynacoTests/AzooKeyAsyncSchedulerTests` green（rich フラグ・stale スキップ）
- `./scripts/test_marked_text_sandbox.sh` — keynaco 未起動のため CI 環境では未実行（Phase 2 と同様、実機 IME アクティブ時に回帰確認推奨）

Space 即時化の効果（実測 2026-06-12、Zenzai on、`includeAzooKey: space` n=50）:

| 指標 | 値 |
|------|-----|
| p50 | 0ms |
| p95 | 0.1ms |
| max | 0.1ms |
| exceeds16ms | false |

`wait_azoo_key` 後の Space は rich キャッシュヒットで即返る。Phase 3 前は毎回 cold miss（p95 ~14–18ms）。計測コマンド:

```json
{"benchmark": {"sequence": "kanzi", "repeat": 50, "includeAzooKey": "space"}}
```

- `./scripts/test_marked_text_sandbox.sh` 9/9 + integrity green（keynaco 起動後 2026-06-12 確認）

## Phase 3.5: 完全勝利 — Space prefetch join + 即時ひらがな ✅ 2026-06-12

Phase 3 後の残ギャップ:

1. **Space が `onKeyDown` で debounce 中の prefetch を潰す** — `kanzi` 直後 Space で cold miss
2. **安価ソースなし読みは AzooKey 到着までウィンドウ非表示** — `assembleCandidateList` の early dismiss
3. **Zenzai on の rich 等価性** — SPM では未検証

### 実装

| 変更 | 内容 |
|------|------|
| `AzooKeyAsyncScheduler.warmRichCacheForExplicit` | debounce キャンセル → 同期 `rich=true` でキャッシュ温め |
| `InputController` / Debug ソケット | Space の `onKeyDown` **前**に warm を呼ぶ |
| `CompositionState.composedHiraganaAfterAbsorbingPending` | absorb 後読みの非破壊見積もり |
| `assembleCandidateList` | `deferAzooKeyWhileTyping` 時は early dismiss をスキップ → ひらがな/カタカナ即時 `.show` |

### 検証

- `./scripts/test_core.sh` green（`testDefer_immediateFixedHiraganaWhileAzooKeyPending` 等）
- `keynacoTests/AzooKeyRichEquivalenceHostedTests` — Zenzai on で rich/non-rich 一致
- ベンチ: `includeAzooKey: "space_immediate"`（`wait_azoo_key` なし）で即 Space の計測が可能

### 受け入れ状態（完全勝利チェックリスト）

| 項目 | 状態 |
|------|------|
| 打鍵エコー非ブロッキング | ✅ Phase 2 |
| Space キャッシュヒット（prefetch 完了後） | ✅ Phase 3 |
| Space 即押し（debounce 中） | ✅ Phase 3.5 warm |
| 打鍵中ひらがな/カタカナ即時表示 | ✅ Phase 3.5 |
| Zenzai on rich 等価性 | ✅ hosted test |

## 追記: 母音限定 whileTyping の副作用対策（2026-06-14）

`deferAzooKeyWhileTyping` 導入後、`handleRomaji` に **母音/`n` キーだけ** `buildCandidateListForTrigger(.whileTyping)` を呼ぶ最適化を追加した（子音は `.none` で候補据え置き）。AzooKey 非同期スケジュールも母音/`n` のみ。

### 症状（ユーザー報告・sandbox 再現）

打鍵中に「入力を受け付けなくなる」ことがある。調査の結果、キーは常に `consumed: true` で、**見た目と確定の不整合**が原因だった。

| 操作 | 修正前の挙動 |
|------|-------------|
| 候補表示中に子音連打 | `markedText` は凍結、`pendingRomaji` だけ増加 |
| 上記のまま Enter | `selectedText`（かなプレースホルダ）で確定し **pending が消失** |
| 例 `kanzi` + `b` + Enter | `marked='かんじ'` のまま → `inserted=['かんじ']` |

3 要因の重なり:

1. 子音打鍵 → `CandidateAction.none`（候補 visible のまま）
2. `MarkedTextSync` が passive 時のローマ字尾を marked から隠す（**候補非表示時も同ルールが走っていた**）
3. Enter → `doConfirmSelection` が候補語を優先し pending を捨てる

### 判断: 母音限定は残し、子音時は dismiss

| 案 | 採否 | 理由 |
|----|------|------|
| 母音限定を削除 | 不採用 | `buildCandidateListWithoutAzooKey` の読みは `composedHiragana` のみ。毎キー再構築しても pending 中はリストが変わらず、marked 凍結は `MarkedTextSync` 側が残る |
| 子音 + `needsRefresh` → `.dismiss` | **採用** | 候補を閉じれば marked に `composingText` が出る。差分最小で AzooKey debounce 方針も維持 |
| Enter 時 pending 保護 | **採用** | passive + `pendingRomaji` 非空なら `commitComposition(.hidden)` で `finalizedText` を確定 |

### 実装（`380456c`）

| ファイル | 変更 |
|---------|------|
| `InputHandler+NormalInput.swift` | 子音 + `needsRefresh` → `.dismiss`（`.none` 廃止） |
| `MarkedTextSync.swift` | ローマ字尾の非表示は **`candidateVisible` 時のみ** |
| `InputHandler+CandidateInput.swift` | passive + trailing romaji 時の Enter は候補語ではなく組成確定 |

### 検証

- `./scripts/test_core.sh` — `InputHandlerCompositionTests`・`VowelKeyRegressionTests`・`MarkedTextSyncTests` 追加/更新
- sandbox（`/deploy` 後 `380456c`）— 13/13 checks:
  - `ai` 候補中 `k` → `visible=false`, `marked='あいk'`
  - `kanzi` + `b` + Enter → `inserted=['かんじb']`
  - `かんじ` + `su` → 候補再表示

### 残る UX 論点（観察）

- 候補の on/off チラつき（`あい` → `k` で閉じ → `ku` で再表示）。許容かは実運用で判断
- `n` を母音キー扱いするルールは [PLAN260428](PLAN260428-successor-pending-romaji.md) 由来。本件とは独立だが説明コストは残る
- Electron の Enter 経路は sandbox では再現しない（[PLAN260605](PLAN260605-workarounds-audit.md) C-1）。実機確認は別途

## 追記: 母音限定 → 全キー rebuild への revert（2026-07-09）

母音限定 whileTyping の副作用対策として上で入れた 3 点セット（子音 `.dismiss` / MarkedTextSync `composedHiragana` 分岐 / `.hidden` フォールバック）は、`ri-` + `n` + Enter の実運用ログで新たな WYSIWYG 崩れを生んだ:

| 状態 | 修正前 |
|------|-------|
| marked | `りー` |
| row 0 | `リーナー`（historyPrefix） |
| Enter で commit | `りーん` |

`n` は `vowelKeys` に含まれるため `handleRomaji` が `.whileTyping` rebuild → candidate visible 維持 → `MarkedTextSync` case 3 が `n` を隠す → Enter が `finalizedText`（`りー` + `ん`）を commit、の連鎖。marked も row 0 も commit と食い違う 3 重不整合。

### 判断: 3 段 dance をやめて素直な IME 挙動に統一

| 変更 | 理由 |
|------|------|
| `InputHandler+NormalInput.swift`: `vowelKeys` / `isVowelKey` 削除、`needsRefresh ? .whileTyping : .dismiss` に統一 | 子音でも rebuild する。composedHiragana が変わらない子音の rebuild はキャッシュヒットするだけで実害は無し |
| `MarkedTextSync.swift`: case 3（passive + candidateVisible + ASCII pending で `composedHiragana` を返す分岐）削除 | pending 尾を隠す必然性が消えた。marked = composingText で marked と commit（`finalizedText`）が n → ん だけずれる標準 IME 挙動に |

### 検証

- `./scripts/test_core.sh` 540/540 pass。旧挙動を固めた 3 テストを新挙動に書き換え:
  - `VowelKeyRegressionTests` → `WhileTypingPendingRomajiTests`（子音でも候補維持、`ri-` + `n` + Enter で `りーん`）
  - `testConsonantAfterWhileTypingDismissesCandidatesAndShowsPending` → `KeepsCandidatesAndShowsPending`
  - `testEnterAfterConsonantDismissCommitsFullComposition` → `testEnterAfterConsonantCommitsFullComposition`
  - `MarkedTextSyncTests.testPassiveCompose_hidesTrailingRomajiTail` → `showsTrailingRomajiTail`
- `kanzi` + `b` + Enter → `かんじb` は引き続き成立（`testEnterWithPassiveCandidateAndPendingCommitsFinalizedText` 継続 pass）

## Phase 4（別トラック・任意）: AzooKey 上流への貢献

`SetAlgebra.init(arr...)` のホットスポットは AzooKeyKanaKanjiConverter（OSS）内部。Release 計測（Phase 0）でもこれが支配的なら、upstream の該当箇所（`kana2lattice` 系）をプロファイルして PR を出す選択肢がある。keynaco 側の構造改善とは独立に進められるが、効果の不確実性と往復コストを考えると Phase 2 完了後の余力次第。

## チラつき対策（UX 上の受け入れ条件）

二段階表示の最大のリスクは「候補が一瞬で書き換わる視覚ノイズ」。以下を受け入れ条件とする:

- 差し替えは打鍵ごとに最大 1 回（デバウンスにより、連打中は差し替え自体が発生しない）
- 即時候補が空（履歴もユーザー辞書もない読み）の場合、ウィンドウは出さずに AzooKey 到着時に初めて出す。「空ウィンドウ → 充填」の見せ方はしない
- 差し替えで `initialRow` の挙動（ひらがな優先・Zenzai promote）が従来の同期版と同じ最終状態に収束すること（スナップショットテストで担保）

## やらないこと

- 読みの長さ・内容による AzooKey スキップ（P-1 で棄却済み）
- `.explicit`（Space）経路の非同期化。Space は「ユーザーが変換結果を待つ」明示操作であり、ここで途中状態を見せる価値はない。Phase 3 のキャッシュ先読みで自然に速くする
- `InputHandler` 内部へのタイマー・Task 持ち込み。純粋 struct + 同期テスト可能性は維持し、時間軸の管理は InputController に閉じる

## 出口

- Phase 0 で Release の p95 が閾値未満 → status: abandoned、計測結果を IDEA260612 へ追記
- Phase 2 完了でこの plan の主目的は達成。Phase 3 / 4 は計測結果を見て個別判断
- **実機 smoke**: 子音 dismiss 修正は sandbox 13/13（2026-06-14）。Electron Enter・連打チラつきは未記録
