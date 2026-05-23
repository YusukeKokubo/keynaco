# DB 簡素化計画：bigram / trigram / skip_bigram の廃止

## 目的

Apple Intelligence 必須前提で DB を見直す。noun_bigram が予測の主軸となり、
bigram（preset 含む）・trigram・skip_bigram は存在理由がなくなった。

## 最終テーブル構成

| 残す | 廃止 |
|------|------|
| `history`（pos 列含む） | `bigram`（is_preset 問わず） |
| `noun_bigram` | `trigram` |
| `user_dict` | `skip_bigram` |
| `boundary_pref` | |
| `hiragana_preferred` | |

## 廃止理由

### bigram（preset 含む）

- ユーザー学習 bigram（is_preset=0）は step 10 で記録停止済み、既存データも参照なし
- preset_bigram は「冷スタート対策」が唯一の存在理由だったが、Apple Intelligence 前提では
  noun_bigram が即日蓄積を始めるため不要
- Successor モードでは `isNounLike` ガードで格助詞 prev は使えず、AzooKey 辞書とも重複

### trigram

- noun_bigram で代替できる（Apple Intelligence 前提）
- ゼロベースで設計すれば不要

### skip_bigram

- step 9 で記録・参照とも削除済み。テーブルとメソッドだけが残存

## 実装ステップ

### Step 1: skip_bigram の完全削除

**削除対象:**
- `DatabaseManager+Ngram.swift`
  - `NgramSinglePrevTable.skip_bigram` ケース削除
  - `recordSkipBigram` 削除
  - `fetchSkipBigram` 削除
  - `fetchSkipBigramTop` 削除
  - `deleteSkipBigram` 削除
- `Core/Sources/CoreTests/SkipBigramTests.swift` 削除
- DB migration: `DROP TABLE IF EXISTS skip_bigram`

### Step 2: trigram の完全削除

**削除対象:**
- `Core/Sources/Core/InputHandler.swift`
  - `recordNgrams(trigram:)` 呼び出しを完全削除（`capPrev2` 等も不要になる）
  - `prev2Output`（trigram 用に使っていた場合）の整理
- `Core/Sources/Core/InputHandler+Candidates.swift`
  - `fetchTrigram` / `fetchTrigramTop` の呼び出し削除
  - `trigramRaw` / `trigramTop` 変数削除
- `Core/Sources/Core/InputHandler+SuccessorMode.swift`
  - `fetchTrigramTop` / `fetchTrigram` の呼び出し削除
  - `trigramTop` / `fromTrigram` 変数削除
- `DatabaseManager+Ngram.swift`
  - `recordNgrams` 関数削除
  - `recordTrigram` 削除
  - `fetchTrigram` 削除
  - `fetchTrigramTop` 削除
  - `fetchTrigramInList` 削除
  - `fetchAllTrigram` 削除
  - `deleteTrigram` 削除
- `keynaco/Settings/TrigramViewController.swift` 削除（または空にする）
- 設定 UI のタブ整理
- テスト内の trigram 関連アサート削除
- DB migration: `DROP TABLE IF EXISTS trigram`

### Step 3: bigram の完全削除

**削除対象（Core）:**
- `DatabaseManager+Ngram.swift`
  - `NgramSinglePrevTable` を `noun_bigram` のみに縮小（または enum 自体削除）
  - `recordBigram` 削除
  - `fetchBigram` 削除
  - `fetchPresetBigram` 削除
  - `fetchBigramTop` 削除
  - `fetchPresetBigramTop` 削除
  - `fetchBigramTopCount` 削除
  - `fetchBigramInList` 削除
  - `fetchAllBigram` 削除
  - `fetchAllBigramExcludingPresets` 削除
  - `deleteBigram` 削除
  - `replaceBigram` 削除
  - `debugSeedBigram` 削除
  - `testInsertBigram` 削除
- `DatabaseManager.swift`
  - `createTables` から bigram テーブル定義削除
  - `seedPresetBigramsIfNeeded` 削除
  - `forceSeedPresets` 削除
  - `ensureBigramIsPresetColumn` 削除
  - `presetSeededUserDefaultsKey` 削除
  - `BigramEntry` 型削除（または別ファイルにあれば確認）

**削除対象（InputHandler）:**
- `InputHandler+Candidates.swift`
  - `fetchPresetBigram` 呼び出し削除（`presetBigramRaw` / `fromPreset` 変数）
- `InputHandler+SuccessorMode.swift`
  - `fetchPresetBigramTop` / `fetchPresetBigram` 呼び出し削除
- `InputHandler+SegmentMode.swift`
  - `recordBigram` 呼び出し削除（step 10 で見落とされていた箇所）
  - `fetchBigram` 呼び出し削除

**削除対象（アプリ層）:**
- `InputController+LLM.swift`
  - `fetchPresetBigramTop` 呼び出し削除
- `LLMCleanser.swift`
  - `fetchAllBigramExcludingPresets` 呼び出し削除（bigram クリーンアップ処理）
- `keynaco/Settings/BigramViewController.swift` 削除（または空にする）
- `keynaco/Settings/CleanserSheetViewController.swift`
  - `deleteBigram` 呼び出し削除
- `keynaco/PresetBigram/preset_bigram.csv` 削除
- Xcode プロジェクトからリソース参照削除

**DB migration:**
- `DROP TABLE IF EXISTS bigram`

### Step 4: テスト・ドキュメント整理

- `CoreTests/DatabaseManagerTests.swift` の bigram/trigram テスト削除
- `CoreTests/InputHandlerCandidatesTests.swift` の bigram 依存テスト修正
- `docs/domain/architecture.md` の候補優先順位から bigram/trigram 言及を削除
- `docs/domain/glossary.md` の関連用語削除

## 注意事項

- **Step 2 の `prev2Output`**: trigram の prev2 として使っていた変数。noun_bigram は
  `lastConfirmedNounOutput` を使うので独立しており、削除しても noun_bigram に影響しない
- **`InputHandler+SegmentMode.swift` の `recordBigram`**: step 10 で見落とされていた。
  セグメント確定時に bigram を記録していた箇所。Step 3 で一緒に削除する
- **`LLMCleanser`**: bigram の品質チェックに使っていた。bigram 廃止後は
  history テーブルのみを対象にする（または LLMCleanser ごと見直す）
- **Settings UI**: BigramViewController / TrigramViewController は削除または空にする。
  タブ構成の変更が必要
- **既存 DB の migration**: DROP は破壊的だが、ユーザーは1人かつ今後蓄積されない
  dead weight なので削除で問題ない
