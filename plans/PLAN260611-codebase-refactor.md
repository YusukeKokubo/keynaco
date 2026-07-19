---
status: implemented
created: 2026-06-11
related_commit: 14a9a6a
---

# PLAN260611: コードベース全体リファクタリング計画

**クローズ（2026-07-19、PLAN260719 triage）**: Phase 0–5 + post-key 追補完了。残っとった Phase 6（plans/docs 棚卸し）は [PLAN260719](PLAN260719-headroom-roadmap.md) の triage が実質の後継として実施。

## 背景と目的

リリースまでに機能の追加と削除を繰り返してきた結果（rejected.md に 10 件超の削除記録）、コードの構造が当時の試行錯誤の痕を引きずっている。機能は維持したまま、ゼロベースの視点で構造を見直す。

事前調査（Core 層・アプリ層・テスト資産の 3 方向）の結論を先に書くと:

- **フルスクラッチの書き直しは不要**。削除済み機能の残骸はコード・テストともにゼロ（DatabaseManager の cleanup マイグレーションのみが意図的に残存）。アーキテクチャの骨格（IMK アダプター → 純粋 struct の InputHandler → DB/Converter）は健全で、問題は「責務の分散」「状態フラグの絡み合い」「重複ロジック」の 3 点に集約される。
- したがって **テスト資産（374 テスト）を安全網にした段階的リファクタ**を採る。フェーズごとに全テスト green + sandbox E2E を通してからコミットする。
- 致命的負債ゆえの機能削除は現時点で**該当なし**。observation.md も空で、削るべき宙ぶらりん機能は残っていない。

## リファクタ中に守る制約（retrospectives 由来 + 既存の不変条件）

1. behavior spec の正本はコードとテスト。リファクタでドキュメントを増やさない。`///` コメントは非自明な WHY と不変条件のみ。
2. `AzooKeyConverter` の `LockedConverter` 封じ込め（converter 参照をクロージャ外に持ち出さない）は構造ごと維持する。
3. `InputController` で `handler.*` を読むときの pre/post 規約（同一ターン中に読む値は書き換え前に退避）を崩さない。
4. 呼び出し元が消えたコードはその場で消す。「後で消す」は作らない。
5. フラグが複数ファイルにまたがり始めたら設計の警報として立ち止まる。
6. 候補表示の優先順位（ひらがな固定 → ユーザー辞書 → Zenzai → 履歴 → 数字/日時 → AzooKey）と Shift+Delete の保護範囲（`fixedEnd <= row < historyEnd`）は外部仕様として固定。

## フェーズ計画

依存が少なく安全なものから順に並べる。各フェーズは独立してコミット可能。

### Phase 0: 安全網の確認（着手前の儀式） ✅ 2026-06-11

- `./scripts/test_core_all.sh` + `xcodebuild test` + `./scripts/test_marked_text_sandbox.sh` を基準線として記録。全 green 確認済み。
- 候補リスト構築（Phase 3）はテストが `fixedEnd` / `historyEnd` / `zenzaiRow` という実装詳細フィールドに依存しているため、リファクタと同時にテストの書き直しが発生する。これは織り込み済みとし、**振る舞い（marked text / inserted / 候補の並び）を検証するスナップショットテストを先に補強**してから内部を触る。
- InputController 層（318 行）はユニットテスト不在。ここは sandbox E2E（`/keynaco-ime-sandbox`）を回帰手段とする。

### Phase 1: 低リスクの掃除（規模: 小） ✅ 2026-06-11

1. **public API の絞り込み** — 完了。`CandidateLayout` 等を internal 化、`CandidateContext` を `private(set)` 化。`POSClassification` は `AzooKeyPOSClassifier` の public 戻り値のため public 維持。
2. **`InputHandler.isAsciiMode`** — 完了。インスタンス化はせず `///` で不変条件を明文化、`Self.isAsciiMode` に統一。
3. **DB マイグレーションの一元化** — 完了。`PRAGMA user_version` ベースの `SchemaMigration` 配列（v1–v4）、全 init パス統一、テスト追加。
4. **`composingText.isEmpty` 判定の集約** — 完了。`CompositionState.isComposing` を追加し Core / Debug / テストで置換。

### Phase 2: InputHandler の状態モデル整理（規模: 中、本丸その 1） ✅ 2026-06-11

1. **状態フラグの遷移を明示化** — 完了。5 フラグの set/clear を `///` / MARK で列挙。候補窓は `CandidatePanelInteraction`（`hidden` / `passive` / `explicit`）を computed で導出。**フィールドの enum 置換は見送り**（`historyEnd` 等と連動し churn が大きい。Phase 5 では app 層 `CandidatePanelModel` で UI 二重管理のみ解消し、Core enum 化は見送り継続）。
2. **ディスパッチの抽出** — 完了。`KeyDispatch.swift`（pure `route`）+ `InputHandler+KeyDispatch.swift`（`handle()` コーディネーター）。`KeyDispatchTests` 10 ケース追加。
3. **extension 境界整理** — 完了。`InputHandler+CandidateInput.swift` 新設（候補表示中キー）、`+BracketMode` は括弧専用に縮小。`+NormalInput` の `buildCandidateList` 呼び出しは入力→リフレッシュ要求として維持。

回帰: Core 405 tests green、`xcodebuild test` green、`test_marked_text_sandbox.sh` 9/9、デバッグソケット E2E（候補 Space・明示選択・文字確定）確認済み。

### Phase 3: 候補リスト構築パイプラインの統合（規模: 中、本丸その 2） ✅ 2026-06-11

`InputHandler+Candidates.swift`（316 行、変更回数 68 回で最大のホットスポット）。

1. **重複排除の一本化** — 完了。`CandidateSectionBuilder`（単一 `seen` Set）に `collectCandidateSources` の pre-filter と `buildSections` の `insertedSet` を統合。`CandidateListSources` は raw データ + `historyOutputSet` のみ。
2. **initialRow 決定の表化** — 完了。`InitialRowPolicyResolver` + `InitialRowPolicyResolverTests`（6 分岐）。`InitialRowPolicy` に `Equatable` 追加。
3. **テスト** — スナップショット 28 件は無変更で green。`fixedEnd`/`historyEnd` 直接依存 4 ファイルを行動ベース（Shift+Delete・`zenzaiRow`・`historyEnd==0`）に置換。`CandidateSectionBuilderTests` 6 件追加。

回帰: Core 417 tests green、`xcodebuild test` green、`test_marked_text_sandbox.sh` 9/9、デバッグソケット E2E（Zenzai 候補順・hiraganaPreferred・Shift+Delete）確認済み。

### Phase 4: LeftContext の概念統一（規模: 小〜中） ✅ 2026-06-11

`leftSideContext` という名前が 3 つの異なる意味（セッションバッファ結合後 / AzooKey API 引数 / IMK before キャッシュ）で使われ、`LeftContextResolver.Input` のコンストラクタ 3 種が実質同じ仕事をしている。さらにアプリ層の `cachedSurroundingContext`（InputController.swift:22）と Core 側 `LeftContextSource.assembleProduction()` で組み立てが二重化。

- **完了**。`LeftContext`（sessionBuffer / imkBefore / combined）+ `LeftContextIMKCache`（旧 `documentSurroundingContextInvalidated` 吸収）を導入。`LeftContextResolver.combine` に単純化、`LeftContextSource.resolveProduction` / `applyPostKeyDown` / `resetCache` に統合。`InputController.cachedSurroundingContext` 削除。

### Phase 5: アプリ層の整理（規模: 中） ✅ 2026-06-11

1. **CandidateWindow の状態の単一正本化** — 完了。`CandidatePanelModel` + `CandidatePanelLayout` を導入し、`CandidateWindow.apply(_:layout:)` に統一。`refreshFrom` / `present` / `show` / 未使用の `selectNext` 等を削除。行メタデータは Core `CandidateRowSection` / `CandidateRowMetadata` に集約。
2. **Debug 層と本体の二重実装の縮小** — 完了（一部）。`InputHandler.snapshot` を `candidateSession` 直読みにし、Debug / InputController の手動オーバーレイを削除。`makeCandidateEntries` を `CandidateRowSection` ベースに。sandbox の別 `InputHandler`・backspace mock・`IMESandboxWindow` ログは維持。
3. **handle() 内の DEBUG 分岐の抽出** — 完了。`InputController+Debug.swift` に `runKeyDownPublishingSnapshot` を移動。
4. Settings/ のテーブル定義 3 様式の統一は効果が薄いため**やらない**（変更頻度が低い）。

**Phase 2 見送り項目の着地点**: `CandidateSession` フィールドの `CandidatePanelInteraction` enum 置換は**未実施**。app 層 `CandidatePanelModel` で UI 二重管理を解消した時点で十分と判断（下記「振り返り」参照）。

回帰: Core fast+slow green、`xcodebuild test` green、`test_marked_text_sandbox.sh` 9/9、デバッグソケット E2E（候補 Space・Shift+Delete・Zenzai `candidateEntries.section`）確認済み。

### Phase 5 追補: post-key 経路の Core 寄せ ✅ 2026-06-11

Phase 5 完了後の follow-up。Debug と本番のキー処理直後ロジックの drift リスクを下げる。

1. **共通関数** — `InputHandler.applyPostKeyDownCandidateAndIMK`（旧 `applyPostKeyDownEffects`）を Core に追加。候補 `applyCandidateAction` + 本番時 IMK キャッシュ更新。
2. **API 整理** — sandbox / 本番のオーバーロード 2 本に分割（`alwaysApplyCandidateAction` + `imkCache?` を廃止）。InputController の `applyPostKeyDownEffects` はオーケストレーター名のまま（ウィンドウ・POS・surrounding fetch）。
3. **意図的に統合しないもの** — sandbox backspace mock、POS 分類（本番 `Task` + `posForOutput` ガード vs Debug 同期 + 専用 converter）、キー**前**の leftContext 解決（`resolveProduction` vs `syncLeftSideContext`）。

回帰: `InputHandlerPostKeyDownTests` 4 ケース追加、Core / keynaco ビルド green。

### Phase 6: 周辺資産の棚卸し（規模: 小）

1. **plans/ の整理**: PLAN/POC が 80 ファイル超滞留している。`/plans-audit` でライフサイクルを付け、implemented/abandoned を明示。アーカイブ方式は audit の結果を見て決める。
2. リファクタ完了後に `/docs-audit` で CLAUDE.md・docs と実装の drift を確認（特に Phase 2–4 で内部の名前が変わるため）。

## 各フェーズの完了条件

共通: `./scripts/test_core_all.sh` green、`xcodebuild test` green、`./scripts/test_marked_text_sandbox.sh` green。状態依存の変更（Phase 2, 3, 5）はさらに `/keynaco-ime-sandbox` での E2E 確認と、`/deploy` 後の実機 smoke を行う。

## やらないこと

- フルスクラッチ書き直し（調査の結論として不要。テスト資産が無駄になりリスクだけ増える）
- 機能の削除（致命的負債に該当するものが現存しない）
- Settings UI の共通化（費用対効果が低い）
- `@unchecked Sendable` の全面排除（DatabaseManager の dbQueue 直列化と LockedConverter は実装として堅牢。理由の文書化のみ行う）

## 順序の根拠

Phase 1 は他に依存せず即効性がある。Phase 2（状態整理）を Phase 3（候補パイプライン）より先にするのは、候補リスト構築が candidateSession の状態フラグに依存しており、土台の語彙が固まってから触る方が手戻りが少ないため。Phase 4 は 2/3 と独立しているが、`documentSurroundingContextInvalidated` の扱いが Phase 2 の検討結果に依存するため後置。Phase 5 は Core の語彙確定後でないと二度手間になる。

## 振り返り（2026-06-11 実施後）

### 事前調査の検証結果

- **フルスクラッチ不要** — 実施後も裏付けられた。骨格（IMK → `InputHandler` → DB/Converter）は維持したまま、責務分散・重複・フラグ絡みだけを段階的に解消できた。
- **段階的リファクタ** — フェーズごとにコミット分割 + テスト green を守れた。着手時 374 テスト → Phase 3 終了時 417 → Phase 5 追補後は post-key テスト等を追加。
- **機能削除なし** — 該当なしの判断は正しかった。削るより整理する方がリスク対効果で優位。

### フェーズ別の効き方

| フェーズ | 評価 |
|----------|------|
| 0–1 | 心理的安全と掃除。地味だが以降の土台 |
| 2 | `KeyDispatch` 抽出で `handle()` の見通しが改善。enum フィールド置換の見送りは正解（churn 回避） |
| 3 | 最大ホットスポット。スナップショット 28 件維持しつつ `CandidateSectionBuilder` 統合が最大の構造改善 |
| 4 | `leftSideContext` 3 意味の混乱が収束。Phase 5 / post-key の前提になった |
| 5 | **体感で最も効いた**。`CandidateWindow` の二重状態解消（`CandidatePanelModel`） |
| 5 追補 | 小規模だが drift 防止として有効。オーバーロード分割で API 意図が型に乗った |

### うまくいった判断

1. **テストを正本にした** — docs を増やさず、スナップショット + sandbox E2E で守った。Phase 3 の `fixedEnd` 直接依存 → 行動ベース化は Phase 5 以降にも効いた。
2. **「やらないこと」を守った** — Settings 共通化・フルスクラッチ・`@unchecked Sendable` 全面排除。スコープ膨張なし。
3. **sandbox の部分統合** — 別 `InputHandler` は維持し、共有可能な層（snapshot・行セクション・post-key）だけ Core 寄せ。現実的な落とし所。
4. **フェーズ順序** — 2→3→4→5 の依存関係どおり、二度手間はほぼ出なかった。

### 見送り・残存（意図的含む）

| 項目 | 状態 | 判断 |
|------|------|------|
| `CandidateSession` の `isVisible`/`isExplicitlySelected` → `panelInteraction` 正本化 | 未実施 | app 層 view model 化で十分。`historyEnd` 連動の enum 化は別タイミング |
| `InputController` ユニットテスト | 不在のまま | sandbox E2E で Phase 0–5 はカバーできたが、アプリ層は依然として薄い安全網 |
| POS 分類（`schedulePOSClassification`） | 本番/Debug 二重 | 次に drift しやすい箇所。触るとき `POSOnCommit.classifyAndStore` 程度の Core 抽出で十分 |
| Phase 6（plans/docs 棚卸し） | 未着手 | コア構造リファクタは一区切り。残タスクはここ |

### メタルール（今後のリファクタにも使う）

1. **ホットスポットは Phase 3 型で攻める** — 変更回数の多いファイルは builder/resolver 抽出 + スナップショット維持が有効。
2. **UI 二重状態は app view model で解く** — Core の `CandidateSession` をいきなり enum 化するより、`CandidatePanelModel` のような導出層の方が churn が少ない。
3. **Debug は「完全統合」より「共有 API 経由」** — 独立性（別 handler・mock・ログ）を残し、snapshot / post-key / 行メタデータだけ Core に寄せる。
4. **同名関数の衝突は早めに解く** — Core は具体的な名前（`applyPostKeyDownCandidateAndIMK`）、app はオーケストレーター名（`applyPostKeyDownEffects`）。grep コストが下がる。
5. **boolean ポリシーはオーバーロードで表す** — `alwaysApplyCandidateAction` のようなフラグより、sandbox/本番のシグネチャ分離の方が読みやすい（追補で学んだこと）。

### やり直すなら（参考）

- Phase 5 前に `InputController` 向けの薄い統合 smoke（marked + 候補 window）を xcodebuild test に足すと、app 層変更時の安心感が増える可能性。コスト対効果は要検討。
- Phase 2 の「Phase 5 まで enum 置換待ち」は、実際には view model 化で十分だった。計画上の期待と着地点にズレがあったが、結果として正しい落とし所。
