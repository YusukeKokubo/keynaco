# PLAN260505c: LLMCandidateScorer 廃止（事後並べ替え撤去）

## 背景

`LLMCandidateScorer` は Space 押下後に Foundation Models を非同期で呼び出し、
候補ウィンドウの表示後に `moveRow()` で順番を入れ替える。
ユーザーから見ると候補が突然並び替わる不可解な挙動になる。

Zenzai（AzooKey のニューラルリランカー）が有効な場合、
`requestCandidates()` の時点で既に `leftSideContext` を考慮した候補順が返ってくるため、
`LLMCandidateScorer` は機能的に重複している。

Zenzai 有無にかかわらず `LLMCandidateScorer` を完全廃止する。理由：

- `confidence == .low` は既に無視 → 高精度ではない
- `autoShow` 時は `confidence == .high` かつ `index != 0` のみ適用 → 寄与が限定的
- Zenzai オフのユーザーにも同じ「突然の並び替え」問題が起きている

### トレードオフ（受け入れ判断）

- Zenzai オフ時は、旧スコアラーがしていた「文書左文脈に基づく候補並べ替え」が一切なくなる。
  長文編集アプリでのみ効いていたケースは後退しうるが、突然の並び替えによる UX 悪化と比べ許容できると判断。
- Zenzai の `leftSideContext` によるリランクと旧スコアラーの `resolvedLLMDocumentContextPrefix`
  は完全同値ではない。本変更は「LLM による事後ソートの撤去」であり、Zenzai が同機能を代替するわけではない点に注意。

## 削除スコープ

### Core/Sources/Core/

- **`LLMCandidateScorer.swift`** — ファイルごと削除
- **`InputHandler.swift`** — フィールド削除（4つ）
  - `pendingScorerGlobalIndices: [Int]`（L130）
  - `pendingScorerStrings: [String]`（L131）
  - `lastScorerEligible: Bool`（L133）
  - `lastCandidateListAutoShow: Bool`（L135）
- **`InputHandler+Candidates.swift`** — スコープ節に準拠して以下を削除
  - `scorerGlobalIndices` 構築ブロック（L288–300）
  - フィールドへの代入 5 行（L310–317）
  - `clearPendingScorerForDismiss()` メソッド（L323–328）および呼び出し（L187）
  - `resetScorerPending()` メソッド（L331–333）および呼び出し（L347、L421）
  - `isComposedHiraganaEligibleForScorer()` メソッド（L336–342）
- **`InputHandler+SuccessorMode.swift`**
  - `resetScorerPending()` 呼び出し（L36）
- **`InputHandler+SegmentMode.swift`**
  - `resetScorerPending()` 呼び出し（L11）

### Core/Sources/CoreTests/

- **`LLMCandidateScorerTests.swift`** — ファイルごと削除

### keynaco/（アプリターゲット）

- **`CandidateWindow.swift`**
  - `moveRow(from:)` メソッド（L216）— scorer 廃止後に呼び出し元ゼロになる
  - L214 のコメント（`pendingScorerGlobalIndices` 前提の記述）を削除
- **`InputController.swift`**
  - `static let candidateScorer = LLMCandidateScorer()`（L113）
  - `applyCandidateScorerScheduling(adapter:)` メソッド全体（L474–516）
  - `applyCandidateScorerScheduling` 呼び出し（L285）
  - `candidateScorer.cancel()` 呼び出し 4 箇所（L198、L204、L428、L433）
  - `handler.resetScorerPending()` 呼び出し 2 箇所（L192、L436）
- **`keynaco/Debug/DebugSocketServer.swift`**
  - `private let candidateScorer = LLMCandidateScorer()`（L30）
  - `applyCandidateScorerScheduling()` プライベートメソッド全体（L352–）
  - `applyLLMScheduling()` 内の `applyCandidateScorerScheduling()` 呼び出し（L234）
  - `candidateScorer.cancel()` 呼び出し（L144、L353）
  - `handler.resetScorerPending()` 呼び出し（L145）
  - `moveRow(from:)` スタブ struct（L574–575）

### keynacoTests/

- **`CandidateWindowMoveRowTests.swift`** — `moveRow` 削除に合わせてファイルごと削除

## ドキュメント更新（実装コミットで合わせて）

- **`CLAUDE.md`** — `InputController` の説明から `LLMCandidateScorer`（「通常変換候補の文脈スコアリング」）の記述を削除
- **`docs/domain/glossary.md`** — **「F1（文脈スコアリング）」節ごと削除**（Tests 行含む。`CandidateWindowMoveRowTests` / `LLMCandidateScorerTests` の両参照が消える）
- **`.claude/skills/keynaco-ime-sandbox/SKILL.md`** — L139 の `LLMCandidateScorer` をスケジュールする旨の記述を削除

## 作業手順

1. `Core/Sources/Core/LLMCandidateScorer.swift` を削除
2. `Core/Sources/CoreTests/LLMCandidateScorerTests.swift` を削除
3. `keynacoTests/CandidateWindowMoveRowTests.swift` を削除
4. `InputHandler.swift` のフィールド 4 つを削除
5. `InputHandler+Candidates.swift` のスコアラー関連コードを削除（§削除スコープに準拠）
6. `InputHandler+SuccessorMode.swift` / `InputHandler+SegmentMode.swift` の `resetScorerPending()` 呼び出しを削除
7. `CandidateWindow.swift` の `moveRow(from:)` メソッドとコメントを削除
8. `InputController.swift` のスコアラー関連コードを削除
9. `DebugSocketServer.swift` のスコアラー関連コードを削除
10. `CLAUDE.md` / `docs/domain/glossary.md` / `.claude/skills/keynaco-ime-sandbox/SKILL.md` を更新
11. ビルド確認（`xcodebuild build`）→ `cd Core && swift test` → `xcodebuild test`

## 確認事項

- `FoundationModels` import は `LLMMisconversionChecker`・`LLMSuccessorFetcher` でも使うため
  `InputController.swift` / `DebugSocketServer.swift` の import は**残す**
- `pendingScorerGlobalIndices` 等は `public` フィールドだが、外部利用者はいないため API 破壊として扱わない
- 削除スコープ内の行番号（L130 等）はドキュメント作成時点のもの。実装時はシンボル名で `rg` 検索して最終確認すること
