---
status: implemented
created: 2026-07-04
related_commit: b422602
---

# PLAN260704: 構造リファクタリング・ロードマップ

歴史的経緯の積み重ねで溜まった構造負債を、挙動を変えずに段階的に返済するロードマップ。
2026-07-04 時点のコードベース全域調査（Core 状態機械 / アプリ層非同期 / 候補・DB パイプラインの 3 方向）に基づく。

## 実装状況（2026-07-04 更新）

| Phase | 状態 | コミット |
|-------|------|----------|
| 1 dead code 掃除 | 完了 | `c070900` |
| 2 JSONLWriter 統合 | 完了 | `c070900` |
| 3 候補状態の単一正本化 | 完了（軽微な残差あり） | `c070900` |
| 4 keyDown パイプライン一本化 | 完了（軽微な残差あり） | `c070900` |
| 5 モード明示化 | **完了** | `7c13b8e`–`b422602` |
| 6 保留 | — | — |

**検証ゲート（2026-07-04）**: `./scripts/test_core_all.sh` 緑。deploy 後 sandbox 3 本（marked text / candidate cleanup / prefix focus）すべて PASS（HEAD `b422602` 一致）。

**Phase 3–4 の残差**（意図的に Phase 5 まで温存）:

- `CandidateContext.panelInteraction` は削除せず、`CandidateSession.makeContext()` がスナップショットを写す形に変更。init の nil 時フォールバック導出は後方互換のため残存
- `pendingSessionRecord` / `pendingDivergenceRecord` は `InputHandler` 上のフィールドのまま。`KeyEventPipeline.drainPendingLogs` で回収経路を一本化（`commitComposition` / `doEscape` のタイミングで書く必要があるため、戻り値への完全移行は Phase 5 と合わせて再検討）

## 目的

- **挙動は変えない**。全 Phase を通じてユーザー体感・候補順序・確定挙動は不変（behavior-preserving）
- 「同じ真実が複数箇所にある」状態を潰し、次の機能開発時の変更箇所を 1 箇所にする
- 「ドキュメントコメントで守っている不変条件」を「型と構造で守る不変条件」に置き換える

## やらないこと（non-goals）

- AzooKey / Zenzai エンジン層の変更（`LockedConverter` の設計は健全、触らない）
- スコアリングの数値・ロジック変更（`CandidateScoreBuilder` の定数は PLAN260624 の管轄）
- ビッグバン書き直し。各 Phase は独立にコミット・リリース可能で、途中で止めても資産が残る
- `DatabaseManager` の migration スキーム変更（`PRAGMA user_version` の線形 migration は問題なし）

## 背景：負債の棚卸し

### A. 状態の「同じ真実」が複数箇所にある（Core）

- **`panelInteraction` の導出が 2 箇所**: `CandidateSession.panelInteraction`（CandidateSession.swift:45）と `CandidateContext.panelInteraction`（InputHandler.swift:74）が同一の導出をそれぞれ実装。片方だけ直すと静かに乖離する
- **`isExplicitlySelected` が実質 3 箇所**: `CandidateSession`（正本）、`CandidateContext`（キーごとのスナップショット）、`handle()` 内の再導出ローカル（`wasExplicitlySelected` / `wasExplicitBeforeBackspace`）。`commitComposition` の `row_snapped_back` anomaly ガード（InputHandler.swift:276-278）は、スナップショットと live session が食い違う実例が既にあることの証拠
- **候補削除ロジックが 2 重**: `CandidateSession.removeCandidate(at:)`（:81-90）と `apply(.deleteSelected)`（:115-124）が同じ 6 行（parallel array の除去 + reset/clamp）を別々に持つ
- **`InputSessionRecord` の 12 フィールド組み立てが 2 重**: `commitComposition`（InputHandler.swift:279-293）と `doEscape`（:502-516）
- **ブラケットモードの不整合状態が構造的に作れる**: `bracketCandidates = nil` だけだと `isVisible=true && !isBracketMode` の孤児状態になり、`handleBracketModeKey` の default 分岐（InputHandler+BracketMode.swift:74-84）が防御的 `reset()` で塞いでいる。不変条件「`isExplicitlySelected ⇒ isVisible`」もコメントで宣言されているだけで構造では守られていない

### B. keyDown パイプラインが 3 重に複製されている（アプリ層）

- `InputController.runKeyDown`（InputController.swift:251-295）と `DebugSocketServer.handleKeyEvent`（+Commands.swift:427-506）と `benchmarkSimulateKey`（:640-666）が、pre スナップショット → `handle()` → post 適用 → 非同期スケジュールの同じ手順を手書きで 3 回実装している。パイプラインを変えるたびに 3 箇所を手動で揃える必要がある
- **非同期の stale 判定ガードが 5 箇所**: `AzooKeyAsyncScheduler.schedule` 内の 4 段チェック（:85, :94, :105, :112）に加え、`applyAsyncAzooKeyResult`（InputController+AzooKeyAsync.swift:65-68）と `applySandboxAzooKeyResult`（DebugSocketServer+AzooKeyAsync.swift:53-56）が同じ 4 条件（generation / reading 一致 / not explicit / composing 中）をほぼ逐語コピー
- **選択行保持ヒューリスティック**（非同期結果到着時に前回選択テキストが残っていれば `selectedRow` を復元、InputController+AzooKeyAsync.swift:90-102）は純粋な状態ロジックなのに InputController に居るためユニットテストが無い
- debounce 入力の組み立ても本番と sandbox で 2 重（InputController+AzooKeyAsync.swift:33-41 / DebugSocketServer+AzooKeyAsync.swift:28-32）
- pre/post 読み分け（CLAUDE.md の「1 キー遅延バグ」）は規約でしか守られていない。特に `applyPostKeyDownEffects` の `leftContextIMKCache` ローカル往復（InputController.swift:218-228）は 10 行の間、真実が 2 つ並存する aliasing hazard

### C. ログ基盤のコピペ 4 重奏

- `writeJSONLine(_:to:)` がほぼバイト単位で同一のまま 4 ファイルに存在: FetchLogger.swift:138 / InputQualityLogger.swift:87 / CandidateDivergenceLogger.swift:83 / TypingLatencyStats.swift:408（grep で確認済み）
- 30 日 / 行数上限の `trimIfNeeded` が 3+1 箇所、buffer + 閾値 flush パターンが 3 箇所。retrospectives の「DRY は rule of two」に対して 4 つ目まで放置されている

### D. dead code・化石（機械的に消せる）

grep で production 呼び出しゼロを確認済み:

| 対象 | 状態 |
|------|------|
| `DatabaseManager.fetchHistoryExact` / `fetchHistoryPrefix` | テスト専用（`fetchHistoryExactScored` / `fetchHistoryScoredMerged` に置換済） |
| `DatabaseManager.fetchUserDict` / `fetchUserDictPrefix` | テスト専用（`fetchUserDictCombined` に置換済） |
| `fetchUnclassifiedHistory(limit:) -> [String]` | 呼び出しゼロ（`fetchUnclassifiedHistoryEntries` に置換済） |
| `fetchDailyLog(for:)` / `countDailyLog(for:)` | 呼び出しゼロ。daily_log の読み経路は全滅、書き込みのみ生存 |
| `diary` テーブル | CREATE のみで SELECT/INSERT ゼロの dead schema |
| `AzooKeyCandidate.segmentCount` | 全候補で計算されるが読み手ゼロ（filter は `Candidate.data.count` を直接使用） |
| `InputController+LLM.swift` | ファイル名が化石。中身は LLM を呼ばず `AzooKeyPOSClassifier` のみ |
| `HiraganaPreferredBuiltins.swift:3,5` | 削除済み LLM 分類へのコメント残存 |
| `handleBracketChar` の `modifiers` 引数 | 受け取るが未読 |
| `applyPostKeyDownCandidateAndIMK` sandbox オーバーロード | 引数 3 つ（`consumed` / `composedHiraganaWasEmpty` / `didInsertText`）を受け取って捨てている |

- **`HistoryEntry` の名前衝突**: トップレベル `HistoryEntry`（HistoryEntry.swift:15、スコアラー用）と `DatabaseManager.HistoryEntry`（DatabaseManager.swift:336、`fetchAllHistory` 用）。`extension DatabaseManager` 内では非修飾名が nested 側に解決され、外側の型を shadow する実 footgun
- **recency 減衰式が 3 実装**: SQL 文字列 `recencyExpr`・Swift `HistoryEntry.score(now:)`・GC の long-only 変種

### E. モードが 6 個の独立フラグから毎キー再構成される（最深部）

「今どのモードか」は単一の enum ではなく、`isAsciiMode`（**process-global `nonisolated(unsafe) static var`**）・組成非空・`isVisible`・`isExplicitlySelected`・`bracketCandidates != nil` の組み合わせから `KeyDispatch.route` が毎回導出する。加えて:

- `ignoreNextModeSwitch` は `handle()` の 4 分岐 + `handleModeSwitchKey` の計 5 箇所で防御的にリセットされる（1 箇所忘れるとバグ）
- `pendingAzooKeyReading` / `pendingSessionRecord` / `pendingDivergenceRecord` の 3 つの「書いておいて後で InputController が回収する」out-parameter フィールド
- `assembleCandidateList` は約 120 行で、候補構築の入口が 4 つ（`buildCandidateList` / `buildCandidateListForTrigger` / `buildCandidateListWithoutAzooKey` / `rebuildCandidateList`）
- Core が `import AppKit` に依存（`NSEvent.ModifierFlags` / `NSRange`）

## 方針

1. **低リスク・機械的なものから順に**。dead code 掃除 → コピペ統合 → 状態の単一正本化 → パイプライン統合 → モード構造化、の順で各 Phase の変更半径を前の Phase が小さくする
2. **各 Phase 完了ごとに**: `./scripts/test_core_all.sh` + `xcodebuild test` + sandbox 回帰 3 本（`test_marked_text_sandbox.sh` / `test_candidate_cleanup_sandbox.sh` / `test_prefix_focus.py`）を全通し。状態依存の Phase 4-5 は `/keynaco-ime-sandbox` で E2E 確認を追加
3. **保護テストを正本と即断しない**（retrospectives「バグ仕様の固着」）。リファクタ中に既存テストが邪魔になったら、git log で fix の意図を読み、実装 enum ではなくユーザー体感をアサートする形に書き直す
4. **同じ if 分岐に乗った別経路を実機で再点検**（retrospectives「フォールバック撤廃」の教訓）。特に Phase 5 のフラグ統合は、ユニットテスト全緑でも sandbox で機能境界（hiraganaPreferred・ブラケット・英数切替）を必ず流す

## Phase 分割

### Phase 1: dead code・化石の掃除

- [x] `fetchHistoryExact` / `fetchHistoryPrefix` / `fetchUserDict` / `fetchUserDictPrefix` を削除し、依存テストは Scored/Combined 系 API でアサートし直す
- [x] `fetchUnclassifiedHistory` / `fetchDailyLog` / `countDailyLog` を削除
- [x] `diary` テーブルの CREATE を削除 + migration で `DROP TABLE IF EXISTS diary`（実行前に実 DB を SELECT して空を確認 — retrospectives「destructive な DB 操作」）
- [x] `AzooKeyCandidate.segmentCount` を削除（`fromConverted` の呼び出し側も同時整理）
- [x] `InputController+LLM.swift` → `InputController+POS.swift` にリネーム、`HiraganaPreferredBuiltins` の stale コメント修正
- [x] `DatabaseManager.HistoryEntry` を `StoredHistoryRow` 等にリネームして名前衝突を解消
- [x] `handleBracketChar` の未使用 `modifiers` 引数、`applyPostKeyDownCandidateAndIMK` sandbox オーバーロードの捨て引数 3 つを削除
- [x] recency 減衰式の Swift 側 2 実装に「SQL `recencyExpr` が正本」の `///` を付け、GC 変種を可能なら統合

**効果**: 以降の Phase の grep ノイズが消える。リスクほぼゼロ。

### Phase 2: ログ基盤の統合（JSONLWriter）

- [x] `JSONLWriter`（open/seek/write/close + `LogTimestamp`）を新設し、4 つの `writeJSONLine` を置換
- [x] trim ポリシー（日数 + 最大行数 + UserDefaults による日次ゲート）をパラメタ化して 3+1 箇所を統合
- [x] buffer + 閾値 flush（50/10/10）を共通の `BufferedJSONLLogger` に寄せる（`TypingLatencyStats` の keep-N 変種は無理に寄せない。合わなければ writer 共有のみ）

**効果**: ログ 1 本追加するコストが激減。retrospectives「新ロジック導入と同時に計装する」の実行コストを下げる布石。

### Phase 3: 候補状態の単一正本化

- [x] `CandidateContext.panelInteraction` を削除し、`CandidateSession.panelInteraction` の値をスナップショット時に写す（導出ロジックを 1 箇所に）— 実装は `makeContext()` スナップショット。フィールド自体は残し init フォールバックのみ温存
- [x] `CandidateSession.removeCandidate` と `apply(.deleteSelected)` の重複 6 行を片方に集約。ついでに UI 削除ボタン経路（`InputController.onDelete`）とキーボード Shift+Delete 経路の二重実装を Core の単一メソッド経由に揃える — `removeRows(at:)` に集約。UI 経路の DB/marked 同期は Controller 側のまま
- [x] `InputSessionRecord` の組み立てを factory（`sessionTracker` 側）に集約し、`commitComposition` / `doEscape` の 12 フィールド重複を解消
- [x] `ScoredCandidate.Source` → 表示ラベル/セクション文字列の 3 箇所マッピング（CandidateBuildDiagnostics / CandidateScoreBuilder / InputHandler.swift:320-324）を `CandidateRowSection` 起点の 1 箇所に統合

**効果**: 「候補リストの状態を触る変更」の変更箇所が常に 1 つになる。

### Phase 4: keyDown パイプラインの一本化

- [x] 非同期結果の適用可否判定（generation / reading / explicit / composing の 4 条件）と選択行保持ヒューリスティックを Core の純粋関数（例: `AsyncCandidateArrival.resolve(session:reading:generation:)`）に抽出し、ユニットテストを付ける — `AsyncCandidateArrival` + `AsyncCandidateArrivalTests`
- [x] `applyAsyncAzooKeyResult`（本番）と `applySandboxAzooKeyResult`（sandbox）を上記関数の薄い呼び出しにする
- [x] debounce 入力の組み立て（inter-key interval + policy）を 1 箇所に — `AzooKeyDebouncePolicy`
- [x] `runKeyDown` の手順（pre スナップショット → handle → post 適用 → 非同期スケジュール）を共有型（例: `KeyEventPipeline`）に抽出し、`InputController` / `DebugSocketServer.handleKeyEvent` / `benchmarkSimulateKey` の 3 実装を 1 つに。pre/post の読み分けはパイプライン内部に閉じ込め、呼び出し側から `handler` フィールドの生読み書きを消す
- [x] `DebugSocketServer.swift:1142-1145` の独自 marked text 再構成を `MarkedTextSync.resolve` 経由に置換
- [x] `pendingSessionRecord` / `pendingDivergenceRecord` の write-then-drain をパイプラインの戻り値に変える（out-parameter フィールドの削減）— `KeyEventPipeline.drainPendingLogs` で回収経路を統一。フィールド自体は Phase 5 と合わせて再検討

**効果**: CLAUDE.md の「pre/post 1 キー遅延バグ」注意書きが構造で保証される。sandbox と本番の挙動乖離（過去に何度も調査コストを払った）が原理的に消える。E2E は sandbox 回帰 3 本 + `/keynaco-ime-sandbox` 手動シナリオ（組成→候補→確定、ブラケット、英数切替、非同期到着タイミング）で確認。

### Phase 5: モードの明示化・不変条件の構造化

Phase 3-4 で状態の読み書き経路が絞れた後にやる。ここが一番深い変更なので、着手前に本 plan を見直して分割を再検討する。

**着手前メモ（2026-07-04）** — 独立コミット系列として推奨する順序:

1. **5a** `ignoreNextModeSwitch` の take パターン集約（変更半径小・テスト容易）
2. **5b** `CandidateSession` 不変条件の構造化（`apply` / setter 内。ブラケット防御 `reset()` 撤廃はここ）
3. **5c** 候補構築入口の単一化 + `assembleCandidateList` 分割（非同期経路 `withoutAzooKey` / `rebuild` との整合が難所）
4. **5d** `isAsciiMode` の注入可能ホルダー化（テスト全ファイルの `setUp` リセットが連鎖する）
5. **5e** `KeyDispatchInput` enum 化 — **差分が膨らむならスキップ可**（不変条件の構造化までで止める判断を維持）

- [x] `CandidateSession` の不変条件（`isExplicitlySelected ⇒ isVisible`、bracket 時の候補整合）を setter/apply 内で構造的に保証し、`handleBracketModeKey` の防御的 `reset()` を不要にする — `enforceInvariants` / `setBracketCandidates(nil)`→`endBracketMode()` / escape・enter は `.dismiss` のみ
- [x] `ignoreNextModeSwitch` の 5 箇所リセットを、`handle()` 冒頭の 1 箇所（消費型 take パターン）に集約
- [x] `InputHandler.isAsciiMode` の process-global static を注入可能な状態ホルダーに移す（テストの `setUp` リセット必須という罠も一緒に消える）— インスタンス `var isAsciiMode`（`InputController.handler` / sandbox `handler` が正本）
- [x] 候補構築の入口 4 つを「トリガー enum を受ける単一入口」に統合し、約 120 行の `assembleCandidateList` を（dismiss 判定 / ソース収集 / スコア構築 / 診断）に分割 — `buildCandidateList(for:azooKey:)` + `CandidateListAzooKeySupply` / `whileTypingPreScoreDismissReason`・`buildScoredLayout`
- [x] `KeyDispatchInput` の 6 bool を、可能なら状態 enum（待機 / ASCII / 組成中 / passive / explicit / bracket — docs/domain/states.md と同型）由来に置き換える — `KeyDispatchMode`（passive/explicit は `.candidatePanel` に統合。ルート分岐に不要なため）

**効果**: docs/domain/states.md の状態遷移図とコードが同型になり、状態依存バグ（実績のあるクラス）の発生源を塞ぐ。

### Phase 6（保留・別 plan 化候補）

着手条件が満たされるまで本 plan では扱わない。必要になったら分割して別 plan を切る:

- **Core の AppKit 依存除去**（`NSEvent.ModifierFlags` / `NSRange` を自前型に）: Phase 5 で `KeyDispatchInput` を触るついでに安くなる可能性があるが、単独の価値はテスト環境の純化のみ。急がない
- **`DatabaseManager` の責務分割**（history / userDict / hiraganaPreferred / dailyLog / POS）: migration は健全で実害が薄い。history 系に次の大きな機能が入るときに再評価

## リスクと対策

| リスク | 対策 |
|--------|------|
| 保護テストが「バグ仕様」を固着していて、リファクタで正しく壊れる | git log で fix 意図を確認 → ユーザー体感アサートに書き直す（retrospectives 準拠）。無言でテストを実装追従させない |
| Phase 4-5 の状態変更が sandbox でしか出ないタイミングバグを生む | 各 Phase 末に sandbox 回帰 3 本 + `/keynaco-ime-sandbox` 手動シナリオ。ユニット全緑を根拠に skip しない |
| `diary` DROP が実は使われていた | 実 DB を `mode=ro` で SELECT して空を目視してから migration に入れる |
| 広い述語での一括置換（rename 等）が目的外を巻き込む | Phase 1 の rename は 1 対象 1 コミット。ビルド + 全テストを対象ごとに回す |
| DB 直編集後の WAL/page cache 罠で検証が空回り | DB を触る Phase 1 検証は keynaco 再起動後に sandbox を見る（retrospectives 準拠） |

## 検証ゲート

各 Phase を `- [x]` で埋めても、以下が全部通るまで次 Phase に進まない:

1. `./scripts/test_core_all.sh` 緑
2. `xcodebuild test -scheme keynaco` 緑
3. `./scripts/test_marked_text_sandbox.sh` / `./scripts/test_candidate_cleanup_sandbox.sh` / `./scripts/test_prefix_focus.py` 緑
4. `/deploy` → 実機で日本語入力の主要動線（組成 → Space → 選択 → Enter、ブラケット、英数切替、Shift+Delete）を一巡

Phase 4 完了時点で CLAUDE.md の pre/post 注意書きを `KeyEventPipeline` 前提に更新済み。全 Phase 完了時に `docs/domain/states.md` を実装に合わせて更新する。
