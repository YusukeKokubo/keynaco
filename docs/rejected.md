# 不採用機能

試作・検討したが採用しなかった機能の記録。同じアイデアを再検討する際の参考にする。

---

## P-7 AzooKey 辞書セクション内 lcid 安定ソート（2026-06-19 削除）

**概要**: AzooKey が返した候補配列を `LcidRank`（properNoun < noun < adjective < verb < unknown < particle < auxiliary）で安定ソートし直す実装。`InputHandler+Candidates.swift` の `sortAzooKeyCandidates` / `sortAzooKeyCandidatesByLcidRank` と、表示候補テキスト → 代表 lcid を返す `AzooKeyConverter.primaryLcidByText` が中核。導入時の意図は「Zenzai OFF や文脈なしでも、助詞より名詞、動詞より固有名詞を上に並べる」整序保険。

**何が壊れていたか — Zenzai の文脈推論を静的ソートが上書き**:

`soudatta` を `今日は` / `昨日は` / `彼は` などの左コンテキスト付きで打つと、Zenzai は「そうだった」を **API order 1 位**、「ソウダッタ」を **2 位**に推す（適切）。だが lcid ソートは AzooKey が「ソウダッタ」を `noun` 帯（lcid 1281…1305 のどれか）、「そうだった」を `verb` 帯（lcid 53…1280）として返してくるので、`noun(1) < verb(3)` で**ソウダッタを 1 位に押し上げる**。結果、文脈的にあり得ないカタカナ羅列が初期選択され、Enter 一発でカタカナが入る事故が発生していた。

```
入力: soudatta（left='今日は'）
Zenzai 順序:                          表示順（lcid ソート後）:
  1. そうだった                          1. ソウダッタ  ← 名詞 lcid で繰り上がり
  2. ソウダッタ                          2. そうだった  ← 動詞 lcid で繰り下がり
```

**設計判断としての誤り**:

- **Zenzai は LLM で文脈を見て確率分布をバイアスする仕組み**。lcid は AzooKey 辞書の連接 ID であり、文脈を一切見ない静的なメタデータ。後者で前者を上書きする道理がない
- 「Zenzai OFF のときの保険」として導入された側面はあるが、Zenzai OFF は今や一番シンプルなフォールバック設定でしかなく、そこの整序のために Zenzai ON 体験を犠牲にするのは本末転倒
- ソートが Zenzai を逆転させたかどうかは画面上から判別不能（candidate window に Zenzai rank 表示はあるが「逆転」イベントとして拾われない）。**サイレントに体感品質を落とす最悪のパターン**

**削除した範囲**:

- `InputHandler+Candidates.swift` の `sortAzooKeyCandidates` / `sortAzooKeyCandidatesByLcidRank` / `AzooKeyFetch` 中間構造
- `AzooKeyConverter.primaryLcidByText` と `primaryLcidMap` ヘルパー、`AzooKeyConverting.primaryLcidByText` プロトコルメソッド
- `InputHandlerAzooKeyLcidSortTests.swift`（保護していた挙動が消えるので化石化テストごと削除）
- `AzooKeyConverterTests.testPrimaryLcidByTextReadsFromCacheAfterRequest`
- `BaseAzooKeyStub` / `AzooKeyAsyncSchedulerTests` の `primaryLcidByText` スタブ実装

**残すもの**: `AzooKeyLcidMapper.classification(for:)`（POS 分類・backfill）、`AzooKeyConverter.primaryLcid(from:)`（`lcidForCommitted` 経由で履歴の lcid 記録に使用）。`LcidRank` / `rank(for:)` は prefix focus・lcid ソート削除に伴い 2026-06-24 廃止。

**再検討するなら**: Zenzai が完全にオフかつ文脈なしの状況でも、AzooKey 生候補で助詞が冒頭に並ぶような目立つ崩れが観測されたとき。ただしその場合も「すべての候補を品詞でソート」ではなく「助詞・助動詞を末尾に回す」だけのフィルタにすべき。Zenzai が有効な経路には絶対に噛ませない。

> 関連: `docs/retrospectives.md`「過去の fix コミット＋保護テストの組み合わせは『バグ仕様』として固着しうる」。`InputHandlerAzooKeyLcidSortTests` も「助詞より名詞を前へ」を化石化しとったが、Zenzai を逆転させる害のほうが大きかった

---

## P-6 `hiraganaInHistory`（履歴に同じひらがなが居るときに固定枠を抑止）（2026-06-19 削除）

**概要**: `isHiraganaPreferred(reading)` で固定ひらがな枠（`fixedSlot=.hiragana`）を出す経路で、組成中のひらがなが履歴（`exactMatchHighHistory` or `highHistory`）にも含まれているとき、`fixedSlot=.none` にフォールバックして固定枠を作らない実装。`CandidateBuildDiagnostics.hiraganaInHistory` フラグ・`InitialRowPolicyInput.hiraganaInHistory` フィールドが関与。

**何が冗長だったか**:

- **見た目の重複は `CandidateLayout.init` の `seen` で既に dedup されとる**: 固定枠と履歴セクションが同じ文字列を持っとっても、セクション順に flatten する際に `seen.insert.inserted` で 2 度目は弾かれる。`hiraganaInHistory` を見なくても候補リストに同じ行が並ぶことはない
- **`InitialRowPolicyInput.hiraganaInHistory` フィールドはデッドコード**: `InitialRowPolicyResolver.resolve` は `fixedSlot` しか参照しとらん。フィールドを `Input` に持たせとるだけで、policy 決定には一切寄与しとらんかった
- **唯一観測可能だった差は Shift+Delete の可否**: `fixedSlot=.none` だと hiragana 行が history 範囲（`fixedEnd <= row < historyEnd`）に入り Shift+Delete で履歴削除可能、`.hiragana` だと fixed 範囲に入って削除不可。ただし
  - builtin 機能語（`の`/`は`/`を` 等）は function-word check で候補窓自体 dismiss されるため、Shift+Delete は元から発火しない
  - ユーザー設定 `hiraganaPreferred` 語は「明示的にひらがな優先」と登録した語であり、履歴から消したいなら設定リストから外すのが筋。同じ文字列の Shift+Delete 動線を別途用意する必要性が薄い

**削除の理由**:

- 仕様としても dead field（`InitialRowPolicyResolver.resolve` が参照しとらん）
- 残すと「`hiraganaInHistory` で何かが切り替わっとる」と読み手に誤解させる
- ログ（`input_log.jsonl` / `latency_log.jsonl`）に flag の効果を測定できる計装がなく、効果検証も不可能だった

**残すもの**（当時）: `isHiraganaPreferred` 自体（`hiraganaPreferredSet` ＋ `HiraganaPreferredBuiltins`）、`fixedSlot=.hiragana` 経路、function-word による打鍵中 dismiss。現行（PLAN260624 以降）の dismiss は `isBuiltinFunctionalWord(scoredLayout.candidates[0])`（row 0 固定）。

**削除した周辺**:

- `InputHandler+Candidates.swift` の `hiraganaInHistory` 計算と `resolveFixedSlot(hiraganaInHistory:)` パラメータ
- `InitialRowPolicyInput.hiraganaInHistory` フィールド
- `CandidateBuildDiagnostics.hiraganaInHistory` フィールド・dict キー
- `IMESandboxWindow` のデバッグ表示行 2 箇所
- `InitialRowPolicyResolverTests` の `hiraganaInHistory:` パラメータ

**挙動の差分**: 観察可能な差は `testSnap_C3_HiraganaPreferredHiraganaInHistory` の `fixedEnd` のみ（`0 → 1`）。候補リスト本体（`candidates: [の, 辞書A, 辞書B]`）と initialRow は変わらず。

**再検討するなら**: ユーザーから「`hiraganaPreferred` 登録した語を後から履歴削除したい」という声が複数件出たとき。ただしその場合は固定枠を出し分けるよりも、設定 UI で `hiraganaPreferred` リストから外す→自動で関連履歴も消す動線のほうが直感的。

> 関連: `docs/retrospectives.md`「過去の fix コミット＋保護テストの組み合わせは『バグ仕様』として固着しうる」。`testSnap_C3` も PLAN260519 で「履歴重複 → fixedEnd=0」を化石化しとったが、deadfield 削除に合わせて期待値を更新した

---

## R-1 `hiddenPendingN`（`nn` 後の非表示 pending n）（2026-06-16 削除）

**概要**: `"nn"` → `ん` のあと、2 つ目の `n` を非表示の pending として残し、続く母音・`y`・`n` と組み合わせてナ行・拗音を作る実装。`CompositionState.hiddenPendingN` フラグで `composingText`・確定・Backspace・Enter 時 trailing romaji 判定を横断管理していた（2026-05 頃導入。当時「標準 IME 準拠」と称した）。

**何が壊れていたか** — ローマ字テーブル通りの分解:

```
konnyaku →  k+o=こ  /  n+n=ん  /  y+a=や  /  k+u=く  →  こんやく  →  婚約
```

`hiddenPendingN` があると `nn` 後の非表示 `n` が `y` と結合し `ny`→`にゃ` となり、**同じ打鍵列が `こんにゃく` に化ける**。これはローマ字仕様の問題ではなく、keynaco 独自の状態機械が標準分解を上書きしていたバグ。

**削除の理由**:

- **ローマ字テーブルに戻すだけで要件を満たす**: `RomajiConverter` で `"nn"` を両方消費して `ん` に確定させ、`CompositionState` から hidden レイヤを除く。追加の「3 つ目の n」ルールや読みの特別扱いは不要
- **状態機械の複雑さ**: `hiddenNKeepFollowers`・`addRomaji` / `backspace` / `absorbPendingIntoComposed` / `finalizedText` / Enter 時 trailing romaji 判定が絡み、仕様説明コストが高い
- **ローマ字表記と打鍵列の混同を招いていた**: Web 上の Hepburn 表記（例: こんにゃくの英字 `konnyaku`）と IME の 1 文字ずつの分解を混同し、「`konnnyaku` で蒟蒻」等の誤った説明を生んでいた

**削除後**: `pendingRomaji` は常に表示・確定に含まれる。`nn` はテーブルどおり両 `n` を消費して `ん` になる。

**削除した周辺**: `CompositionState.hiddenPendingN` / `hiddenNKeepFollowers`、`InputHandler+CandidateInput` の hidden 分岐、`InputHandlerHiddenPendingNTests`（→ `InputHandlerNNTests` に置換）。

**再検討するなら**: Apple かな入力のように `nn` 後に hidden `n` を残し `kanna`→`かんな`・`konnichiwa`→`こんにちわ` を取る互換レイヤが本当に必要か。採用するなら **`konnyaku`→`こんやく`（婚約）が再び壊れない**ことを先にテストで固定する。

> 関連: commit `191edff`、`CHANGELOG.md`（旧 `hiddenPendingN` エントリ）、[PLAN260605-workarounds-audit](../plans/PLAN260605-workarounds-audit.md) E-1

---

## P-5 `addsDefaultFixedHiragana`（ひらがな先頭固定の暗黙フォールバック）（2026-06-19 削除）

**概要**: 打鍵中（`whileTyping`）に履歴・ユーザー辞書・数値/日時のいずれもなく AzooKey 候補だけが返ってきたとき、組成ひらがなを候補リストの先頭に強制挿入していた。`shouldAddDefaultFixedHiragana` が trigger・fixedSlot・履歴有無・各種候補の有無を AND で判定し、`addsDefaultFixedHiragana=true` のときだけ `CandidateSectionBuilder` が `fixedHiragana` セクションを追加する設計。`CandidateLayout.adjustedInitialRow` で「ひらがな先頭固定 + 変換候補1件」のとき初期フォーカスを変換候補に当てる補助ロジックも同居していた。

役割は実質2つに分裂していた:

- **役割 A**: `deferAzooKeyWhileTyping=true` で AzooKey 結果待ち中の placeholder（kana のみで候補窓を即時表示）
- **役割 B**: AzooKey が結果を返したがひらがな読みを含まなかったケース（`kanzi` → `[完治, カンジ, 寛治, ...]` にひらがな `かんじ` が無い）で、ひらがな確定の動線を先頭固定で保証

**削除の理由**:

- **役割 A は意図のない挙動**: `deferAzooKeyWhileTyping` 導入時に「結果待ちの間は kana だけでも見せておく」と入れたが、明示的な設計判断ではなかった。`marked text`（組成ひらがな表示）は出ているのでユーザーは打鍵そのものは見えており、候補窓は AzooKey 結果が返ってから出せばよい
- **役割 B は AzooKey の順序を毎回上書きする副作用がある**: Zenzai は文脈と履歴を考慮した順序を返してくれる。先頭固定で読みを毎回上書きすると、その文脈推論を活かせない。`docs/concept.md` の「AzooKey の出力を素直に信頼する」ポジショニングと一貫しない
- **明示的な代替動線が既に揃っていた**: ひらがな確定は **F6 キー**（`testF6ConfirmsHiragana`）で意図を明示できる。特定の語をひらがな優先したい場合は **hiraganaPreferred リスト**（`fixedSlot=.hiragana` 経路、設定 UI から追加可能）で明示できる。暗黙フォールバックは必要ない
- **カタカナ末尾固定撤廃（[P-4](#p-4-カタカナ末尾固定セクション2026-06-19-削除)）と同じ原則の一貫適用**: ひらがな先頭 / カタカナ末尾の対称設計から、両方とも撤廃して「AzooKey の出力を素直に信頼する」原則に集約

**残すもの**: F6 によるひらがな確定動線、`hiraganaPreferred` 経路（`fixedSlot=.hiragana`）、`HiraganaPreferredBuiltins`（助詞・記号の builtin リスト）、設定 UI の「ひらがな優先」タブ。

**削除した周辺**:

- `shouldAddDefaultFixedHiragana` 関数（`InputHandler+Candidates.swift`）
- `CandidateSectionBuildInput.addsDefaultFixedHiragana` フィールド
- `InitialRowPolicyInput.addsDefaultFixedHiragana` フィールド
- `CandidateBuildDiagnostics.addsDefaultFixedHiragana` フィールド
- `CandidateLayout.adjustedInitialRow` 関数（`appliesDefaultFixedHiragana=true` 限定だったため全体が dead code 化）
- `CandidateSectionBuilder.build` の `|| input.addsDefaultFixedHiragana` 条件
- 関連テスト（`CandidateLayoutTests` の `testAdjustedInitialRow_*` 4 件、`testWhileTypingDefaultFixed`、`testDefer_immediateFixedHiraganaWhileAzooKeyPending` 等）

**早期 dismiss 条件への追加**: `whileTyping` で AzooKey 候補も履歴もユーザー辞書も数値/日時も無いとき dismiss する条件を新設したが、**`fixedSlot=.none` ガードを最初に入れ忘れて** `no`/`wo`/`toka` 等の hiraganaPreferred 経路まで巻き込んで dismiss する事故を起こした（ユニットテストでは全緑、実機 sandbox で発覚）。`fixedSlot == .none` を dismiss 条件に追加して修正。`docs/retrospectives.md`「フォールバックを撤廃するときは『同じ条件分岐に乗っとった明示意図ロジック』を実機で再点検する」参照。

**再検討するなら**: 「ひらがな確定の頻度が想定より高く、F6 を覚えてもらうコストが UX 後退として表面化した」場合。ただし暗黙フォールバックではなく、設定で明示的に opt-in できる「ひらがな常時先頭」モードのほうが筋がよい。

> 関連: commit `7986157`、[P-4 カタカナ末尾固定セクション](#p-4-カタカナ末尾固定セクション2026-06-19-削除)、`docs/retrospectives.md`「過去の fix コミット＋保護テストの組み合わせは『バグ仕様』として固着しうる」「フォールバックを撤廃するときは『同じ条件分岐に乗っとった明示意図ロジック』を実機で再点検する」

---

## P-4 カタカナ末尾固定セクション（2026-06-19 削除）

**概要**: 候補リストの末尾に「読みのひらがなをカタカナに変換した文字列」（`KanaUtils.hiraganaToKatakana(hiragana)`）を専用セクション `.katakana` として常時挿入していた。AzooKey が同じカタカナを返しても、`addsDefaultFixedHiragana=true` の条件下では azooKey セクションから除外して末尾セクションに「集約」していた。`CandidateSection.Kind.katakana`・`CandidateLayout.defaultSectionOrder`／`exactMatchFirstSectionOrder` の末尾エントリ・`CandidateSectionBuilder` のフィルター（`hasRealCandidates` の分岐）が関与。

**何が壊れていたか**: 「`しゃつ` → `シャツ` が候補に出ない」というバグ報告がきっかけ。AzooKey は実際に `[しゃつ, 謝通門, シャツ, 洋袗]` を返していたが、`addsDefaultFixedHiragana=true` の条件で azooKey セクションから `シャツ` を除外し、`seen` セットには残したまま末尾の katakana セクションでも `seen.insert(input.katakana).inserted` が false 返して追加されず、**シャツがどこにも出ない**状態だった。

過去の修正コミット `bf57684`（「未知語でカタカナ候補が候補ウィンドウに表示されないバグを修正」）は `hasRealCandidates=false`（未知語）のときだけ `seen.remove` する部分修正で、`hasRealCandidates=true`（既知語＋珍辞書語）のケースは依然消える状態を残したまま、`testKnownWordWithZenzaiDoesNotShowKatakanaInMainList` で「変換候補があるときカタカナ除外」を保護していた——固着したバグ仕様の典型。

**削除の理由**:

- **AzooKey が既知語のカタカナを既に返している**: 実機で 8 ケース測ったところ、`しゃつ`/`ぐろ`/`かんじ`/`にほんご`/`ぴざ`/`こひ` 等の既知語は AzooKey 自身が読みのカタカナ表記（`シャツ`/`グロ`/`カンジ`/...）を返してくれる。独立した強制生成は冗長で、除外フィルターと末尾固定の二段構造が複雑さを増していた
- **未知語/架空語フォールバックも捨てる判断**: 架空語（`ぐろとすく`）や AzooKey が返さない短い読み（`a` 一文字）では撤廃後にカタカナが出なくなるが、実用上ほぼ問題ない。`docs/concept.md`「AzooKey の出力を素直に信頼する」ポジショニングの一貫適用
- **「足し算の設計」へ**: 修正前は「ひらがな先頭固定 + カタカナ末尾固定」で対称設計を試みていたが、AzooKey が返したカタカナを除外して末尾に再集約する逆向き操作（`hasRealCandidates` の三項分岐）が認知負荷の主因だった

**残すもの**: AzooKey 経由のカタカナ候補（`シャツ`・`カンジ`・`ピザ` 等は AzooKey が返したものを azooKey セクションにそのまま並べる）、F7 によるカタカナ確定動線（`testF7ConfirmsKatakana`）、F8 による半角カタカナ確定。

**削除した周辺**:

- `CandidateSection.Kind.katakana` ケース
- `CandidateLayout.defaultSectionOrder` / `exactMatchFirstSectionOrder` 末尾の `.katakana` エントリ
- `CandidateSectionBuilder` の `azooKeyItems` フィルター（`hasRealCandidates` 分岐）
- `CandidateSectionBuildInput.katakana` フィールド
- `InputHandler+Candidates` での `KanaUtils.hiraganaToKatakana(hiragana)` 生成
- `CandidateBuildDiagnostics.sectionKindLabel` の `.katakana` ケース
- 関連テスト（`testKatakanaInCandidatesWhenSpacePressed`、`testSpaceWithUnknownReadingShowsHiraganaAndKatakana`、`testKnownWordWithZenzaiDoesNotShowKatakanaInMainList`、snapshot tests の末尾カタカナ期待値 14 箇所）

**再検討するなら**: 「AzooKey が読みのカタカナを返さない既知語が頻繁に出現し、ユーザーが F7 を覚えるコストが UX 後退として表面化した」場合。ただしフィルター付きの末尾固定ではなく、AzooKey 結果に katakana が含まれていない場合のみフォールバックする最小設計から POC する。

> 関連: commit `cb05019`、過去の部分修正コミット `bf57684`、[P-5 `addsDefaultFixedHiragana`](#p-5-addsdefaultfixedhiraganaひらがな先頭固定の暗黙フォールバック2026-06-19-削除)、`docs/retrospectives.md`「過去の fix コミット＋保護テストの組み合わせは『バグ仕様』として固着しうる」

---

## P-3 Zenzai top-1 プロモート（2026-06-13 削除）

**概要**: 左文脈ありかつ Zenzai 有効のとき、AzooKey が返す `mainResults[0]`（Zenzai 推論込みのスコアで最上位の候補）を `.zenzaiTop1` という独立セクションに切り出し、候補リストの先頭で固定表示していた。`CandidateSession.zenzaiRow` で行番号を保持し、Shift+Delete から保護、紫ラベルで視覚的に区別、初期選択行も Zenzai 行に固定。

**削除の理由**:

- **コードを薄く広く複雑にしていた**: production 5 ファイル（`CandidateLayout` / `CandidateSectionBuilder` / `InitialRowPolicyResolver` / `CandidateRowSection` / `InputHandler+Candidates`）に `zenzaiPromoted: String?` をバケツリレー。セクション順序が 4 パターン（左文脈 × 完全一致履歴の有無）に分岐していて、候補リスト構築の認知負荷の主因だった
- **Zenzai 自体は残せる**: Zenzai 推論結果は `AzooKey` の `requestCandidates` 内部でスコアに反映され、`mainResults` 全体の並びに効いている。プロモート枠を消しても Zenzai のスコアリングはそのまま AzooKey 辞書セクションに混ざる
- **UX 上の判断**: Zenzai が他の候補ソース（履歴・ユーザー辞書）に押し負けることを許容する設計に振った。履歴・ユーザー辞書は「ユーザー個人の正解」、Zenzai は「文脈から推論した一般的な正解」で、前者を優先する

**残すもの**: Zenzai 推論そのもの（`AzooKeyConverter.isZenzaiEnabled` / `zenzaiProfile` / 左文脈の `set_left_context`）、Zenzai 設定タブ、`zenz-v3.2-small-gguf` submodule、`sessionTextBuffer` 由来の左文脈構築。Zenzai は今や AzooKey 辞書セクションの一員。

**消えたもの**: `.zenzaiTop1` セクション、セクション順序 4 パターン → 2 パターン（`defaultSectionOrder` / `exactMatchFirstSectionOrder`）、`InitialRowPolicy.atZero`、`CandidateRowSection.zenzai`、`CandidateSession.zenzaiRow`、紫ラベル、preSortFirst を維持する分岐。

**再検討するなら**: 「Zenzai 推論結果を UI で明示的に優先したい」要件が再浮上したときに、セクション順序の複雑化を伴わない形（例: 紫ラベルだけを付ける、辞書セクション内のソート優先度に組み込む）を先に POC する。

---

## P-2 履歴 lcid タイブレーカー（Phase B/C、2026-06-13 削除）

**概要**: `fetchHistoryScoredMerged` でスコア同値帯（`epsilon=0.01`）のとき `LcidRank` で履歴候補を並べ替え。Phase C は `lcid` 欠落かつ 11 文字超を `longPhrase` rank に落とす。

**試みたこと**: SQL 相関サブクエリで `lcid`/`pos` 取得 + `sortHistoryScoredWithLcidTiebreaker` + `LcidRank.forHistory`。ユニットテスト・sandbox で動作確認済み（[PLAN260613](../plans/PLAN260613-pos-candidate-ranking.md)）。

**削除の理由**:

- **体感できる改善は Phase A のみ**: 辞書セクションの lcid ソートは sandbox で確認できるが、履歴タイブレークは出口が `maxHighHistoryCount=3` の前方一致枠争いに限られ体感しにくい
- **常時コスト**: タイブレーク発火の有無に関わらず、毎クエリで lcid/pos サブクエリ2本を実行（DB 単体は軽いが設計上の無駄）
- **`forHistory` / `from(lcid:)` の二系統**: 読めるが意図の説明が要る

**残すもの**: Phase D（`history.lcid` 列・backfill・設定 UI）。Phase A/B/C の lcid ソート・`LcidRank` は P-7 および 2026-06-24 の整理で廃止。

**再検討するなら**: 同スコア帯の行だけ lcid を遅延取得する、または履歴枠を広げて効果を体感できるか先に POC する。

---

## P-1 `.whileTyping` 短読み AzooKey スキップ（2026-06-12 不採用）

**概要**: `collectCandidateSources` の入口で「`.whileTyping` かつ `composedHiragana.count <= 2`」のとき AzooKey を呼ばず空配列を返す。「かん」段階（2 文字）の AzooKey 呼び出しを省いて「かんじ」（3 文字）まで待つ狙い。

**試みたこと**: `InputHandler+Candidates.swift` に 1 行追加。`swift test` で即座に 4 テスト失敗（`testTypingTwoVowelsAutoShowsDictionaryCandidates` / `testTypingShowsCandidatesWhenHistoryExists` / `testSnap_F6_ZenzaiFirstWithAutoShow` / `testSnap_F7_ZenzaiFirstAutoShowNoContext`）を確認してリバート。

**不採用の理由**:

- **2文字の単語が存在する**: `count <= 2` でスキップすると「あい」「かん」「いぬ」等の 2 文字完成語に対して AzooKey 候補がゼロになる。読みの長さだけでは「途中か完成か」を判定できない
- **`needsRefresh` ゲートで既にコスト削減済み**: `addRomaji` は `composedHiragana.count >= 2` のときのみ `true` を返す。1 文字読みへの AzooKey 呼び出しはコード側が既に防いでいる。`count <= 1` のスキップは完全に no-op
- **実効的な節約対象は2文字の1回だけ**: 「kanzi」の例で AzooKey 呼び出しは「かん」（2文字）と「かんじ」（3文字）の 2 回。スキップ可能なのは前者の1回だが、前述の理由でそれもできない

**背景（Instruments 計測、2026-06-12）**:

- AzooKey (`Kana2Kanji.kana2lattice`) は Main Thread CPU の 65%、Worker Thread の 72% を占有
- その内部の `SetAlgebra.init(arr...)` が全体の約 40% ——これは AzooKey 内部なので keynaco 側からは変更不能
- DB クエリ（`fetchHistoryScoredMerged` / `fetchUserDictCombined`）の時間は計測上ほぼゼロ

**再検討するなら**: 「入力途中かどうか」を判定できる情報（`pendingRomaji` が空かどうか等）を組み合わせて条件を精緻化するか、非同期デバウンス（[IDEA260612](../ideas/IDEA260612.md) 案A）を使って AzooKey 呼び出し自体を遅延させる。ただし非同期化は `CandidateAction` の同期返却設計を変える必要があり、設計コストが高い。

---

## O-1 1 モーラサジェスト（2026-06-05 削除）

**概要**: `autoShow` で読みが 1 モーラ（小書き仮名除く主仮名 1 文字）のとき、セッション内 `recentCommits`（50 件）と起動時 DB warmload `frequentCommits`（20 件）の前方一致だけを候補に出す経路。助詞読みではひらがな row 0 固定＋過去語を下に並べる調整あり（2026-05-29）。

**削除の理由**:

- **2 モーラ以上の通常経路で足りる**: `fetchHistoryScoredMerged`（`LIKE '読み%'`）・AzooKey 予測補完・機能語 UI 抑制が部分読みを担う。1 モーラ専用の in-memory リストは重複
- **観察で価値未確認**: 仕様どおり動くことは sandbox / ユニットテストで確認したが、打鍵削減・助詞入力のチラつき改善は体感未測定のまま
- **複雑さ**: `commitText` フック・起動 warmload・`assembleCandidateList` 早期 return が IME 本体に残り、保守コストに見合わない

**削除した周辺**: `RecentCommit` / `recentCommits` / `frequentCommits` / `appendRecentCommit` / `recentCommitsMatching` / `loadFrequentCommits`、`InputHandler+Candidates.swift` の 1 モーラゲート、`InputHandlerCandidatesTests.testSingleMora*`。`fetchTopFrequentEntries` は Settings「ひらがな優先」候補提案用に継続。

**再検討するなら**: 1 モーラだけ DB 履歴では弱い（スコア閾値・件数上限）と判断した場合。macOS 側の類似 API との比較は [IDEA260529](../ideas/IDEA260529.md) 参照。

> 関連: [observation.md](./observation.md)（経過観察リストから削除）、[POC260529b](../plans/POC260529b-require-japanese-prediction.md)

---

## D-3 イベントビューアー（2026-06-05 削除）

**概要**: メニューバー ⌨ から開くキーイベント・確定テキスト・候補リストのリアルタイム表示ウィンドウ。`InputController` / `IMKTextInputAdapter` から `#if DEBUG` 経由でログを受け取る。JSONL エクスポート対応。

**削除の理由**:

- **利用場面がない**: 開発初期のデバッグ用途で導入したが、IME サンドボックス（デバッグソケット）に置き換わり、日常的に開く機会がなくなった
- **機能重複**: キー入力の再現・内部状態の観察は `DebugSocketServer` + `/keynaco-ime-sandbox` スキルで十分。EventViewer は事後ログ閲覧に特化しており ROI が低い
- **本番コードへの侵入**: `addCommit` だけ `#if DEBUG` なしで残っていた経緯があり（[PLAN260501c](../plans/PLAN260501c-performance-improvements.md)）、デバッグ UI を維持するコストに見合わない

**削除した周辺**: `EventViewerWindow.swift`、`InputController` / `InputController+IMKAdapter` 内の呼び出し、AppDelegate メニュー項目。

**再検討するなら**: バグ報告用のセッション録画が必要になった場合。`DebugSocketServer` の JSONL 出力や `scripts/debug_ime.py` から派生させる方が、再現手順と一体化しやすい。

> 関連: [PLAN260504c](../plans/PLAN260504c-debug-snapshot-log.md)、[PLAN260501](../plans/PLAN260501-performance-resources.md)

---

## D-4 Guided Generation テストウィンドウ（2026-06-05 削除）

**概要**: DEBUG メニュー「Guided Generation テスト…」から開く、`@Generable` + `respond(generating:)` の動作確認ウィンドウ。IME Extension ではなく**本体アプリ**（InputMethod ホスト）で Foundation Models が使えることを検証するためのツール（2026-05-27 追加）。

**削除の理由**:

- **利用場面がない**: 日記生成 POC（[PLAN260527](../plans/PLAN260527-ai-diary-generation.md)）完了後、一度動作確認すれば十分なツールで、以降メニューから開く機会がなかった
- **本番機能ではない**: IME サンドボックス内では Guided Generation は IME サンドボックス制約でハングする（[H-1](#h-1-foundationmodels-generable-構造化出力による品詞分類2026-05-25)）。本体アプリでの動作確認は POC 記録に残っており、常設 UI の必要がない
- **日記タブも削除済み**: Guided Generation の唯一の本番利用先だった日記生成 UI（[J-1](#j-1-日記自動生成settings-タブ2026-06-05-削除)）を削除したため、テストウィンドウの存在意義も消えた

**削除した周辺**: `DebugGuidedGenerationTest.swift`、AppDelegate DEBUG メニュー項目。

**再検討するなら**: IME 本体で `@Generable` を本採用する機能が再浮上したとき。OS が IME Extension の XPC 制約を緩和する前は、Settings 等のサンドボックス外プロセスでの POC 用スクリプトで十分。

> 関連: [H-1](#h-1-foundationmodels-generable-構造化出力による品詞分類2026-05-25)、[PLAN260527](../plans/PLAN260527-ai-diary-generation.md)、[apple-intelligence.md](./apple-intelligence.md)

---

## S-1 NAS DB 同期（Settings タブ）（2026-06-05 削除）

**概要**: Settings の「同期」タブで NAS 上の `history.db` パスを指定し、rsync でローカル DB と手動／終了時自動で同期する機能。`SyncSettings` + `SyncViewController` + `AppDelegate.applicationWillTerminate` の書き出し。

**試みたこと**: SMB マウント先への rsync（`-av --checksum`）。インポート前に WAL チェックポイント・接続クローズ（`closeForImport`）して WAL/SHM 破損を防ぐ。終了時自動書き出しオプション。

**削除の理由**:

- **利用場面がない**: 単一マシン運用で NAS 同期を使う機会がなく、Settings タブが dead code になっていた
- **rsync 依存の運用コスト**: パス設定・マウント状態・競合解決はユーザーが手動で面倒を見る必要があり、IME 本体に UI を持つ ROI が低い
- **代替は十分**: マシン間共有が必要になった場合は `~/Library/Application Support/keynaco/history.db` を iCloud / 手動 rsync / バックアップツールで扱えばよく、専用タブは不要

**削除した周辺**: `SyncSettings.swift` / `SyncViewController.swift`、`DatabaseManager.checkpoint` / `closeForImport` / `reopen`。

**再検討するなら**: 複数 Mac で履歴・ユーザー辞書を常時同期する需要が実際に出てから。自動マージ（Last-Write-Wins ではなくフィールド単位）が必要なら POC から。

> 関連: [concept.md](./concept.md)（NAS 同期の言及 — UI 実装は本エントリで不採用）

---

## J-1 日記自動生成（Settings タブ）（2026-06-05 削除）

**概要**: `daily_log`（確定テキスト＋app_bundle_id）を素材に、Apple Intelligence（Foundation Models）で 1 日分の日記・日報を生成する Settings「日記」タブ。`DiaryViewController` + `DiaryGenerator` + `diary` テーブルへの保存。

**試みたこと**: 日付選択 → 当日の `daily_log` 一覧表示 →「日記を生成」→ 生成結果の編集・保存・コピー。Guided Generation の動作確認は [PLAN260527](../plans/PLAN260527-ai-diary-generation.md) で完了済み。

**削除の理由**:

- **利用場面がない**: 日報・振り返りを Settings から生成するワークフローを日常的に使わず、タブが dead code になっていた
- **IME のコア価値とずれる**: 入力支援（履歴・Zenzai・候補）が主役であり、生成物の閲覧・編集 UI を IME 設定に持つ必然性が薄い
- **データ基盤は別途保持**: `daily_log` への記録（`InputHandler.diaryBuffer` → `recordDailyLog`）は personalization 用コーパスとして継続。削除したのは生成 UI と `DiaryGenerator` のみ

**削除した周辺**: `DiaryViewController.swift` / `DiaryGenerator.swift`、`DatabaseManager.saveDiary` / `fetchDiary` / `fetchDiaryDates`。既存 DB の `diary` テーブルはスキーマ上残るが未使用。

**再検討するなら**: `daily_log` が数万字規模に育った後、日記生成ではなく personalization（[G-2](#g-2-tunerax-スクレイピング型-personalization-基盤の追加2026-05-29) 参照）の方が優先。日記 UI を復活させるなら独立アプリ or ショートカット連携の方が適切。

> 関連: [PLAN260527](../plans/PLAN260527-ai-diary-generation.md)、[apple-intelligence.md](./apple-intelligence.md)

---

## I-1 セグメントモード（文節選択 / AzooKey Desktop `.selecting` 相当）（2026-06-04 削除）

**概要**: Space で長文読みを文節単位に部分確定するモード。`SegmentState` + `AzooKeyCandidateMerge` + `firstClauseResults` マージ + Shift+←/→ 境界調整 + marked text 二重下線。azooKey-Desktop の `.selecting` を keynaco 向けに再実装したもの。

**削除の理由**:

- 境界ヒューリスティック（助詞リスト・「は」直前・です/ます剥がし等）の保守コストに対して体感がイマイチ。POC260603 で段階改善したが、エンジン部分候補 + keynaco 固有ルールの二重構造が残り続けた
- 多くの入力（2 文字以下・ひらがな優先・日時/ユーザー辞書）は既に通常候補窓へフォールバックしており、Space の主役が中途半端
- セグメント間 bigram 学習・LLMSegmentConverter・読み修正（C-1）は既に不採用/削除済みで、モード単体の価値が薄い
- `concept.md` の打鍵最小化は履歴・Zenzai 文脈・予測変換で取りに行く方針。文節モードは差別化の核にならなかった

**削除後の Space**: 組成中 Space → `buildCandidateList(autoShow: false)`（候補窓表示）。候補表示中 Space → 次候補（従来の ↑↓ 明示選択フローは維持）。

**同時に廃止した周辺**: セグメント確定時の結合フレーズ `recordPrefixes`（`observation.md` 経過観察からも削除）、`scripts/check_segment_history_boundary.py` / `segment_boundary_compare.py`、デバッグ JSON の `isSegmentMode` / `segmentTexts` フィールド。

**再検討するなら**: 使い込みで「長文を一気に打って Space 1 回で部分確定」が本当に必要か POC から。AzooKey Desktop 追従そのものを目的にしない。

> 関連: [POC260603](../plans/POC260603-segment-boundary-suffix.md)、[PLAN260603](../plans/PLAN260603-azookey-desktop-selecting.md)、[C-1 セグメントモード内の読み修正](#c-1-セグメントモード内の読み修正2026-04-30)

---

## G-2 Tuner（AX スクレイピング型 personalization 基盤）の追加（2026-05-29）

**概要**: Zenzai の `personalizationMode`（base/personal n-gram LM の補間）に渡す personal モデルを
生成・データ蓄積する手段として、azooKey の **Tuner**（github.com/azooKey/Tuner, MIT）を keynaco に
足すか検討した。Zenzai personalization 自体の効果検証は [POC260529](../plans/POC260529-personalization-ngram.md) で実施。

**調査した内容**: Tuner は SwiftPM ライブラリではなく**独立した macOS メニューバーアプリ**（`.xcodeproj`）。
2層に分かれる:
- **取得層**: アクセシビリティ API で**全アプリの画面テキストを常時スクレイピング**。`app-sandbox: false`、`NSAccessibilityUsageDescription` 必須。
- **学習パイプライン層**: MinHash＋前方一致で重複除去（`MinHashUtils` / `TextModel+Purification`）→ EfficientNGram で n-gram 逐次学習（`TextModel+NGram`）。App Group 経由で IME にモデルを渡す。

**不採用の理由**:

- **取得層がポジショニングと衝突**: keynaco は `app-sandbox: true`／concept.md「ローカル完結」「学習データはローカル SQLite に閉じる」。Tuner の取得層はサンドボックス解除＋Accessibility 権限＋閲覧内容の全収集を要求し、「入力を学習」から「画面で見た全テキストを収集」へ信頼契約が質的に変わる
- **取得層がそもそも不要**: keynaco は IME なので `daily_log`（打鍵＋app_bundle_id）が privacy を守ったまま育つドメインコーパスになる。azooKey が AX スクレイピングをする理由（入力だけだとデータが貯まるのが遅い）は本 POC のデータ量律速の解決策だが、keynaco にとっては最も避けるべき取り方
- **時期尚早**: personalization 自体が [POC260529](../plans/POC260529-personalization-ngram.md) でデータ量律速（2日で2470字）と判明し status=tested で保持中。Tuner を今組んでもデータが貯まるのを待つだけ

**判断**: Tuner アプリの追加（特に取得層）は不採用。**ただし personalization 機構そのものは棄却ではない**
（POC260529 で「データ待ちで保持」）。将来 personalization を本採用するなら、Tuner 一式ではなく
**dedup ロジックだけ MIT 流用**（MinHash／前方一致は実装の質が高い）し、`daily_log` からの増分学習に
組み込む。取得層は捨てる。

> 関連: [POC260529](../plans/POC260529-personalization-ngram.md)、[G-1 Zenzai 制御パラメーター](#g-1-zenzai-制御パラメーターtopic--style--preference-の-ui-公開2026-05-24)

---

## H-1 FoundationModels @Generable 構造化出力による品詞分類（2026-05-25）

**概要**: `LLMPOSClassifier` のプレーンテキストパース方式を廃止し、`@Generable` + Guided Generation（`respond(generating:)`）で品詞ラベルを構造化出力させる。スキーマ違反トークンを生成できなくなるためガベージ出力問題を根本解決できると想定した。Tool Calling（`struct POSTagTool: Tool`）も代替アプローチとして検証した。

**試みたこと**:

- `@Generable struct POSResultV2`（`pos: String` + `.anyOf(...)` 制約）で `respond(generating:)` を呼ぶ
- フィールド1つのみの最小 `@Generable struct SmokeTestResult` で smoke test
- `struct POSTagTool: Tool`（`Arguments = POSToolParameters`、返り値 `String`）+ `respond(to:)` の Tool Calling アプローチ

**結果**: 3アプローチすべてで `respond` が返らない永続的ハング（45秒タイムアウト確認）。エラーも例外も投げない。

**不採用の理由（根本原因）**:

- IME Extension（Input Method Extension）には通常アプリより厳しいサンドボックスプロファイルが適用される
- Guided Generation のスキーマ検証・Tool 呼び出しは `generatived` / `com.apple.modelcatalog.catalog` への XPC 通信を経由する
- IME サンドボックスが XPC 通信を拒否（Error 159: Sandbox restriction）
- クライアントプロセスに完了シグナルも例外も届かないままデッドロック
- コードの問題ではなく **macOS 26 Beta のシステムバグ**。workaround なし

**判断**: OS アップデートで修正されるまで利用不可。`respond(to:)` プレーンテキスト方式（現行 `LLMPOSClassifier`）は動作するため、プロンプト改善で精度向上を図る方針に切り替え（→ [PLAN260525b](../plans/PLAN260525b-candidate-filter-prompt.md)）。将来 Apple が IME Extension のサンドボックスポリシーを緩和した場合に再評価する。

> 関連: [POC260525b](../plans/POC260525b-generable-pos-classification.md)

---

## G-1 Zenzai 制御パラメーター（topic / style / preference）の UI 公開（2026-05-24）

**概要**: zenz-v3 の制御トークン `topic`・`style`・`preference` を設定 UI に追加し、ユーザーが文書の話題・文体・好みを手動設定できるようにした。また `DatabaseManager.recentProperNouns(limit:)` で history.db の固有名詞を自動推論して `topic` に補完する PoC も実施した。

**試みたこと**: `ZenzaiViewController` に topic/style/preference の入力フィールドを追加。`ZenzaiSettings.makeConverter()` でこれらを制御トークンとして AzooKey API に渡す実装。topic 自動推論は `pos IN ('proper_noun/place', 'proper_noun/person', 'proper_noun/org')` かつ `pos_retry=0` のエントリを上位 5 件取得してカンマ区切りで渡す方式（詳細は `plans/POC260524-zenzai-topic-inference.md`）。

**不採用の理由**:

- **leftSideContext が支配的**: 同音異義語の disambiguation は `leftSideContext` だけで十分に機能する（`すいふと` + 技術文脈 → SWIFT プロモート、`じゃば` + 蛇文脈 → 蛇場/蛇ば など）。topic の追加効果を単独で確認できなかった
- **zenz-v3.1-small では topic が無効**: `topic="Swift,GitHub,Xcode,Apple"` および `topic="IT,プログラミング,技術"` を設定しても、全テストケースで topic 空と差異なし。fixedEnd も変化しなかった（POC260524-zenzai-topic-inference.md シミュレーション実測）
- **topic 自動推論はノイズが多い**: `LLMPOSClassifier` の誤分類率が高く、直近固有名詞の上位が common noun（`入力`・`固有名詞`）や助詞付き語彙（`情報が`）で占められる。有害なバイアスになる可能性がある

**判断**: UI から topic/style/preference を削除し `profile` のみ残す。自動推論コード（`recentProperNouns`）は現状維持するが ROI を投じない。将来の zenz-v3 上位モデルで再評価する。

> 関連: [POC260524](../plans/POC260524-zenzai-topic-inference.md)

---

## F-1 Successor モード（後続語サジェスト）（2026-05-25）

**概要**: 組成なし・ASCII モードでない状態で ASCII 英字 1 文字を入力した瞬間、直前確定語（または `leftSideContext` 末尾の名詞）を prev として content-bigram + 変換履歴を照会し、後続語候補を表示するモード。確定後さらにローマ字を打つことで仮名プレフィックスで候補を絞り込む。

**試みたこと**: `InputHandler+SuccessorMode.swift`（`trySuccessorCandidates` / `handleSuccessorCandidateKey` 等）として実装。`successorEligible` フラグで確定直後の 1 打目を捕捉し、`leftSideContext` 末尾の名詞抽出（`extractNounFromContext`）でセッションをまたいだ文脈も活用。候補は `content_bigram` → `history` の順で優先。

**不採用の理由**:

- **UX とタイピングが合わない**: 組成前に英字を打ってモードに入るという設計が、日本語入力のリズムと相性が悪い。ユーザーが意識しないと恩恵を受けられない
- **学習データの問題**: `content_bigram` は `count >= 2`（同一ペアを 2 回以上確定）かつ Apple Intelligence 必須のため、使い始めはほぼ空振りになる
- **名詞抽出の精度が低い**: `extractNounFromContext` は Unicode 範囲チェックのみで、助詞が直後にある場合に誤抽出することがある
- **ローマ字 2 打目で体験が断絶**: 2 打目で仮名が確定した瞬間に通常組成へフォールバックするため、恩恵を受けられるのが実質 1 打目のみになる

**方針転換**: content-bigram のデータは保持したまま、Successor モードは削除。bigram を通常変換の候補ランキングに統合する方向で再設計する予定だったが、実 DB を確認したところデータが蓄積されていないことが判明し、テーブルごと廃止した（[F-2](#f-2-content_bigram-noun-bigram-テーブルの廃止2026-05-25) 参照）。

---

## F-2 content_bigram（noun-bigram）テーブルの廃止（2026-05-25）

**概要**: `content_bigram` テーブルは (prev_word, input_reading, output) のトリプルを記録し、`count >= 2` のペアを通常変換の候補ランキングに反映する設計だった。F-1 Successor モードのデータ基盤として導入。`NounBigramViewController` でデバッグ UI から蓄積状況を確認できるようにした。

**試みたこと**: `POSCommitSequencer` が Apple Intelligence の POS 分類結果を使い、content word（名詞・固有名詞）の確定時に bigram を記録。`fetchContentBigram` でクエリして変換候補の優先順位に加える実装。

**不採用の理由**:

- **データが蓄積されない**: 実 DB を確認したところ 49 件全件で count=1。同一 (prev, reading, output) トリプルを 2 回以上確定することは日常的な日本語入力では極めてまれであり、`count >= 2` の閾値を満たすレコードが実質ゼロ
- **設計前提が崩れた**: F-1 Successor モード削除後、bigram の用途は「候補ランキング補正」のみになったが、データが空のため効果もゼロ
- **sessionTextBuffer で代替**: leftSideContext を強化する `sessionTextBuffer`（PLAN260525）により、文脈依存の同音異義語 disambiguation は Zenzai に委ねられる。bigram による独自ランキングの必要性がなくなった

**判断**: `content_bigram` テーブル・`POSCommitSequencer`・`NounBigramViewController` をすべて削除（commit `5edf2bc`）。POS 分類自体（`LLMPOSClassifier`）はひらがな優先機能で引き続き使用するため維持。

> 関連: [F-1 Successor モード](#f-1-successor-モード後続語サジェスト2026-05-25)、[PLAN260525](../plans/PLAN260525-session-text-buffer.md)

---

## E-2 AzooKey needTypoCorrection による typo 許容変換（2026-05-06）

**概要**: `ConvertRequestOptions.needTypoCorrection = true` を設定することで、AzooKey のラティス探索に `TypoCorrectionGenerator` を追加し、読み入力の typo を補正した変換候補を出す。

**調査した内容**:
- `ConvertRequestOptions` に `needTypoCorrection: Bool?` が存在し、macOS では `nil` のとき `false` にフォールバックする（iOS は `true`）
- `TypoCorrectionGenerator` が扱う誤り訂正は「清音↔濁音の混同」のみ（シ→ジ、テ→デ、ハ→バ/パ 等）。キーボード上の隣接キー誤打（`kanzi` → `kanji` 等）はスコープ外
- 補正候補にはペナルティ −3.5〜−7.0 が付加される。`N_best=10` の制約下では、正規の読みの候補が豊富にある単語（「かんし」→34件）では補正候補がラティスから押し出されて出現しない
- サンドボックスで複数パターンを実測したが、typo 補正候補が上位に出るケースは確認できなかった

**不採用の理由**: AzooKey の `needTypoCorrection` は iOS フリック入力の「濁点ボタン押し忘れ」向けであり、ローマ字経由のひらがな direct 入力では恩恵が薄い。補正対象が狭く、ペナルティ設計上 N_best=10 では候補に現れないため実質効果ゼロ。`needTypoCorrection` を `true` にしても体感変化なし。ロールバック済み。

---

## 数字キー（1–9）による候補直接確定

**概要**: 候補ウィンドウ表示中に 1–9 を押すと対応する候補を確定する。

**不採用の理由**: 候補ウィンドウが履歴ヒットで自動表示される仕様のため、数字の連続入力（"123" など）で 3 文字目が候補選択として誤作動する。ASCII 組成中は無効にする回避策も試みたが、体験が悪いと判断して廃止。

---

## E-1 Backspace 再変換（2026-04-29）

**概要**: 確定直後に Backspace を押すと、確定テキストを読み（ひらがな）に戻してセグメント変換モードへ移行する。

**試みたこと**: IMK の `setMarkedText(_:selectionRange:replacementRange:)` で確定済みテキストをマークドテキストに置換する方式で実装し、動作することを確認した（`PLAN260429c-backspace-reconvert.md` 参照）。

**不採用の理由**: 確定直後の Successor 候補表示（格助詞・bi-gram 予測）と競合する。候補を消そうとして押した Backspace が意図せず再変換を起動してしまい、操作感が悪い。確定後の自動候補表示を重視するこの IME の設計方針と根本的に相性が悪い。

> 関連: [PLAN260429c](../plans/PLAN260429c-backspace-reconvert.md)

---

## A-3 句読点（。）での組成自動確定（2026-04-29）

**概要**: 組成中に `.`（→`。`）を入力したとき、組成を自動確定してから `。` を挿入する。Space+Enter の2打を省略する狙い。

**検討した設計**:
- AzooKey 先頭候補で自動変換 → ひらがな確定したい場合に意図しない漢字変換が起きる
- `commitComposition(candidate:)` 流用（選択候補があればそれ、なければひらがな） → 漢字にしたい場合は ↓+`.` が必要でキー数は変わらない

**不採用の理由**: `。` という1打に「変換したい」「ひらがなのまま」という2つの意図を区別する情報がない。どの設計でも一方のパターンが損をする。現状の Enter（ひらがな確定）/ Space+Enter（漢字確定）の使い分けが明示的で壊れにくく、代替する価値がない。

---

## D-1 pendingRomaji 先読みの2文字対応（2026-05-01）

**概要**: `buildPendingCandidateList` の先読みは `pendingRomaji.count == 1` のときのみ動作する。`sh` / `ch` / `ts` 等の2文字子音が pending の段階でも先読みを動かし、候補をより絞り込めるようにする。

**検討した変更**:
- `hasPendingPreview` の条件を `pending.count <= 2` に緩和
- `romajiToInitialKana` に `"sh": ["し", "しゃ", "しゅ", "しょ"]` 等の2文字キーを追加

**不採用の理由**: `romajiToInitialKana` には既に `"s": ["さ", "し", "す", "せ", "そ"]` が含まれており、`s` 1打の時点で「し」行を含む先読みが動作している。`sh` を追加しても先読みの有無は変わらず、候補の絞り込み精度が多少上がるだけで実用的な価値がない。`si` でも `shi` でも「し」に変換できるため、「`sh` pending の先読みが動かない」こと自体がユーザーの困りごとにならない。

---

## D-2 文頭フレーズ候補（SENTENCE_START bigram）（2026-05-01）

**概要**: `sentenceTerminators`（。！？\n）確定後は `committedHistory.removeAll()` で `lastCommittedOutput = nil` になり bigram が動かない。`"__START__"` という特殊な prev を bigram テーブルに記録することで、文頭でもよく使うフレーズを候補に出す。

**不採用の理由**: `recordPrefixes` が機能しているため、過去に確定した長いフレーズはその前方一致パターンが `history` テーブルに記録されている。文頭で「よ」と打てば `fetchHistoryPrefix` が「よろしくお願いします」を既に拾ってくる。bigram を追加しても「候補が出るかどうか」は変わらず、文脈依存のランキング調整にしかならない。現状の history prefix 検索で実質カバー済み。

---

## C-1 セグメントモード内の読み修正（2026-04-30）

**概要**: セグメントモード中にフォーカス文節の読みを Backspace で削って打ち直せるようにする。例: `いし → 意思` に変換されたが `いす → 椅子` に修正したい場合、セグメントモードを抜けずに読みを編集する。

**検討した設計**:
- **案1（Backspace でサブモード遷移）**: Backspace 押下でフォーカス文節の reading を `composedHiragana` に移し「読み編集サブモード」へ。文字キーも読みに追加される。Tab/Enter/←/→ で確定して通常セグメント選択に戻る。`SegmentState` に `isReadingEdit` フラグを追加する必要あり。
- **案2（F6 でトリガー）**: セグメントモード中の F6 で読み編集モードへ。Backspace の挙動を変えない。キーバインドが非自明。
- **案3（Backspace で reading を1文字削って次文節に渡す）**: Shift+← と実質同じ効果のため独立した価値がない。

**不採用の理由**: A-3（句読点自動確定）と同じ構造の問題——「1キーで複数の意図を区別できない」——を内包する。案1は Backspace の既存挙動（セグメント解除）を変更するため驚きが大きい。案2はキーが非自明。いずれの案も現状の「Escape → 組成に戻って打ち直し」と比べて複雑さに見合う改善が得られない。
