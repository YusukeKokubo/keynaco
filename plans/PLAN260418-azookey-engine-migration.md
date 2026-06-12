# AzooKeyKanaKanjiConverter への変換エンジン移行

## 背景と目的

現在の変換エンジンは mozc 辞書 + 自前 DP による単純なルックアップ。  
精度面の限界として以下の問題がある：

- `segmentize()` は辞書マッチ長 + 履歴カウントのみでスコアリング → 自然な文節分割が困難
- 複合変換ロジック（100行超）が自前実装で品質が不安定
- 言語モデルがなく、同音異義語の優先順が文脈を考慮しない

[AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) は azooKey IME が実際に使用している変換エンジン。  
N-gram 言語モデル + 格子デコーダ + 学習機能を備えており、辞書ルックアップとは根本的に精度が異なる。

---

## ライブラリ概要

| 項目 | 内容 |
|------|------|
| ライセンス | MIT |
| 対応 macOS | 13.0+ |
| Swift バージョン | 6.1+ |
| 配布方法 | Swift Package Manager |
| 最新版 | v0.11.1（2025年8月） |
| 主な依存 | swift-algorithms, swift-collections |

### 主要 API

```swift
import KanaKanjiConverterModuleWithDefaultDictionary

let converter = KanaKanjiConverter()  // デフォルト辞書同梱版を使用

var composingText = ComposingText()
composingText.insertAtCursorPosition("かんじる", inputStyle: .direct)

let results = converter.requestCandidates(composingText, options: .init(
    N_best: 10,
    keyboardLanguage: .ja_JP,
    learningType: .inputAndOutput,
    memoryDirectoryURL: /* app support dir */
))
// results: [(text: String, correspondingCount: Int, ...), ...]
```

---

## 現行アーキテクチャとの対応

### 置き換えるもの

| 現行 | azooKey 移行後 |
|------|---------------|
| `DatabaseManager.fetchCandidates()` | `KanaKanjiConverter.requestCandidates()` |
| `DatabaseManager.segmentize()` (自前 DP) | azooKey 内蔵の格子デコーダ |
| `DatabaseManager.fetchDict()` | azooKey 内蔵辞書 |
| `DatabaseManager.historyCount()`（DP スコア用） | azooKey 内蔵学習スコア |
| `DictionaryImporter` | 不要になる |
| `mozc-dict.sqlite`（バンドルリソース） | azooKey 同梱辞書に置換 |
| 複合変換ロジック（`fetchCandidates` の後半 ~70 行） | azooKey が内部処理 |

### 残すもの

| コンポーネント | 理由 |
|---------------|------|
| `RomajiConverter` | 候補表示中の pending romaji 状態管理は現行のまま維持。ひらがな確定後に azooKey へ渡す |
| `history` SQLite テーブル + `DatabaseManager.record()` | 候補ウィンドウの「履歴セクション」表示を維持するため |
| `DatabaseManager.fetchHistoryExact()` | セグメントモードの履歴候補生成で引き続き使用 |
| `CandidateWindow` | UI は完全独立 |
| `CompositionState` | 基本構造は維持（composedHiragana + pendingRomaji） |

---

## 入力フローの変化

### 現行フロー
```
キー入力
  → RomajiConverter → composedHiragana
  → DatabaseManager.fetchCandidates(prefix: composedHiragana)
      → history テーブル（prefix match）
      → dictionary テーブル（exact match）
      → 複合変換（split + cross join）
  → CandidateWindow.show()
```

### 移行後フロー
```
キー入力
  → RomajiConverter → composedHiragana  ※変更なし
  → ComposingText.insertAtCursorPosition(composedHiragana, inputStyle: .direct)
  → KanaKanjiConverter.requestCandidates(composingText, options:)
      → azooKey 内蔵格子デコーダ + 言語モデル
  → 先頭に history テーブルの候補を挿入（現行 UI の履歴セクション維持）
  → CandidateWindow.show()  ※変更なし
```

### セグメントモードの変化

現行の `segmentize()` は自前 DP で文節分割。azooKey は以下の 2 通りで代替できる可能性がある（Step 0 で確認）：

**プランA（単文節 API がある場合）**: セグメントモードの文節ごとに単文節ルックアップを使い、`segmentize()` の DP を azooKey の文節分割で代替する。

**プランB（単文節 API がない場合）**: `requestCandidates()` に全体ひらがなを渡し、各候補の `correspondingCount` から文節境界を復元する。`resizeFocusedSegment` の境界変更時は部分読みを渡して候補を得る。

---

## 実装ステップ

### Step 0: 事前調査・環境確認

**【重要】以下の調査結果によって Step 3/4 の設計が確定する。必ず実施してから先に進む。**

1. **Xcode / コンパイラバージョン確認**（azooKey は Swift コンパイラ 6.1+ 必須）
   ```bash
   xcodebuild -version   # Xcode 16.3+ なら Swift 6.1 コンパイラ同梱
   swift --version
   ```
   - `SWIFT_VERSION: "6.0"` は言語モード（strict concurrency を有効化）であり、コンパイラ版とは別。  
     コンパイラが 6.1 未満の場合は Xcode のアップグレードが必要。

2. **`ComposingText` の挙動確認**  
   ひらがな文字列を `.direct` で挿入した場合の動作を小さな Swift スクリプトか Playground で確認する。

3. **`requestCandidates()` 返り値の確認**  
   `Candidate` 構造体のフィールド（特に `text`, `correspondingCount`）を確認する。  
   `N_best: 10` で長文（5 文節以上）の全文節候補を賄えるかも確認する。足りなければ 20〜30 に増やす。

4. **単文節ルックアップ API の有無を確認**（最重要）  
   `resizeFocusedSegment()` は「特定の読み 1 文節に対する候補リスト」が必要。  
   `requestCandidates()` は全体変換なので意味論的に異なる。  
   azooKey に `fetchDict` 相当の単文節ルックアップ（例: `requestCandidates` で部分テキストを渡す、または専用 API）があるか調べる。  
   - ある場合 → Step 4 で単文節 API を使って `resizeFocusedSegment` を置き換える
   - ない場合 → セグメントモードを azooKey の `correspondingCount` ベースで再設計する（後述）

5. **`correspondingCount` によるセグメント再構築の実現性確認**  
   `requestCandidates()` が返す候補の `correspondingCount` を使って「先頭候補から順に文節を積み上げる」方法でセグメント列を再現できるか確認する。  
   これが可能なら、`segmentize()` の代替として `correspondingCount` ベースの `segmentize` を実装できる。

6. **`updateLearningData` の正確な引数確認**  
   確定時に渡す型・メソッドシグネチャを調べて `AzooKeyConverter.commit()` の実装に備える。  
   Step 0 でシグネチャを確定させ、Step 2 のコードに反映してから先に進む（空実装のまま Step 3 に進まない）。

7. **`memoryDirectoryURL` の正しい取得方法を確認**  
   IME はバックグラウンドエージェントとして動作する。`applicationSupportDirectory` が取れることと、  
   ディレクトリが存在しない場合に `createDirectory` が必要かを確認する。
   ```swift
   FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
       .appendingPathComponent("ykey")
   ```
   上記が実際に書き込み可能かを小さなテストで確認する。

### Step 1: SWIFT_VERSION 引き上げ + SPM 依存追加

azooKey は Swift コンパイラ 6.1+ 必須（Step 0 で確認済みであること）。  
`project.yml` の `SWIFT_VERSION: "5.9"` を `"6.0"` に引き上げる（= 言語モードを Swift 6 strict concurrency に切り替え）。

`project.yml` の変更：

```yaml
settings:
  SWIFT_VERSION: "6.0"   # "5.9" から変更

packages:
  AzooKeyKanaKanjiConverter:
    url: https://github.com/azooKey/AzooKeyKanaKanjiConverter
    minorVersion: 0.11.0

targets:
  ykey:
    dependencies:
      - package: AzooKeyKanaKanjiConverter
        product: KanaKanjiConverterModuleWithDefaultDictionary
```

#### concurrency 移行の事前見積もり

既存コードに concurrency アノテーションはゼロ。Swift 6 モードにすると以下のエラーが確実に出る。  
ただし IME は全処理が IMK スレッド（実質シングルスレッド）上で動くため、`@unchecked Sendable` と `@MainActor` で対処できる範囲に収まる見込み。

| 型 | 問題 | 対処 |
|----|------|------|
| `DatabaseManager` | `final class` が `Sendable` 非準拠。`InputHandler`（struct）のフィールドなので Swift 6 が要求する | `@unchecked Sendable` を追加（常に IMK スレッドからのみアクセス） |
| `InputController` | `IMKInputController` サブクラス（ObjC クラス）の Sendable 推論エラー | `@MainActor` を付与するか、個別に `nonisolated` で対処 |
| `CandidateWindow` | `NSPanel` サブクラス。UI 操作が actor 境界を越えると警告 | `@MainActor` を付与 |
| `AppDelegate` | `NSApplicationDelegate` の同上 | `@MainActor` を付与 |

想定工数：**1〜2 時間**。`DatabaseManager` の `@unchecked Sendable` + UI クラスへの `@MainActor` 追加が主作業で、ロジックの変更は不要。

`xcodegen generate` 後にビルドし、上記以外のエラーが出た場合はその場で対処する。  
ビルド成功後、ビルド成果物のサイズを実測して 100MB 未満であることを確認する（azooKey 同梱辞書は ~50MB 級）。

### Step 2: AzooKeyConverter アダプター作成

`Sources/AzooKeyConverter.swift` を新規作成。  
`DatabaseManager` の既存インタフェースに近い形でラップし、差し替えを局所化する。

```swift
final class AzooKeyConverter {
    private let converter = KanaKanjiConverter()
    private let options: ConvertRequestOptions

    // memoryDirectoryURL: Step 0 item 7 で確認した書き込み可能なパスを渡す
    init(memoryDirectoryURL: URL) {
        options = ConvertRequestOptions(
            N_best: 10,
            keyboardLanguage: .ja_JP,
            learningType: .inputAndOutput,
            memoryDirectoryURL: memoryDirectoryURL
        )
    }

    // InputHandler から呼ぶ単一エントリポイント
    func requestCandidates(hiragana: String) -> [String] {
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        return converter.requestCandidates(text, options: options)
            .map(\.text)
    }

    // Step 0 item 6 で updateLearningData のシグネチャを確認してから実装する。
    // この関数を空のまま Step 3 に進まないこと（azooKey 学習が無効のまま残る）。
    func commit(/* Step 0 調査後に引数型を確定 */) {
        // converter.updateLearningData(...)
        // converter.commitUpdateLearningData()
    }
}
```

### Step 3: InputHandler の変換呼び出し置き換え

`doRefreshCandidates()` の変換部分を差し替える。

**変更前（InputHandler.swift:280-282）:**
```swift
let result = db.fetchCandidates(prefix: state.composedHiragana)
var candidates = result.candidates
let historyCount = result.historyCount
```

**変更後:**
```swift
let azooKeyCandidates = azooKeyConverter.requestCandidates(hiragana: state.composedHiragana)
let historyCandidates = db.fetchHistoryExact(reading: state.composedHiragana)
let historyCount = historyCandidates.count
// 履歴を先頭に、azooKey 候補を後に結合（重複除去）
var candidates = historyCandidates + azooKeyCandidates.filter { !historyCandidates.contains($0) }
```

**セグメントモードは一時的に `segmentize()` を残す（後続の Step 4 で対処）。**

`resizeFocusedSegment()`（InputHandler.swift:477, 484, 494, 500, 506 行）は境界調整のたびに  
`db.fetchDict(reading:)` を呼ぶ。`fetchDict` は「特定の読み 1 文節の候補」を返すが、  
`requestCandidates(hiragana:)` は「全体変換候補」を返すため意味論が異なる。  
Step 0 の調査結果に応じて以下いずれかを選ぶ：

- **単文節 API がある場合**: `resizeFocusedSegment` の `fetchDict` 呼び出しをその API に置き換える
- **単文節 API がない場合**: `requestCandidates` に部分読み（対象文節の reading のみ）を渡して候補を得る。  
  全体変換の文脈情報は失われるが、単一文節のリサイズ用途では実用上問題ない。

### Step 4: DatabaseManager のクリーンアップ

**前提: Step 3 で `resizeFocusedSegment()` の `fetchDict()` 呼び出しを置き換え済みであること。**

`segmentize()` の代替として、`correspondingCount` ベースの再実装を行う（Step 0 で実現性を確認済みであること）：

```swift
// azooKey の requestCandidates 結果から文節列を再構築する
func segmentize(hiragana: String) -> [(reading: String, candidates: [String])] {
    var composingText = ComposingText()
    composingText.insertAtCursorPosition(hiragana, inputStyle: .direct)
    let results = converter.requestCandidates(composingText, options: options)

    // correspondingCount を使って先頭から文節を順に積む
    var segments: [(reading: String, candidates: [String])] = []
    var offset = 0
    while offset < hiragana.count {
        let candidatesAtOffset = results.filter { /* offset が一致するもの */ }
        // ... Step 0 調査結果で具体化する
    }
    return segments
}
```

※ `correspondingCount` の使い方は Step 0 で確認した結果に基づいて具体化する。  
　Step 0 で `correspondingCount` ベースの再構築が困難と判明した場合は、`segmentize()` を残してフォールバックとする。

削除するメソッド：
- `fetchCandidates(prefix:)` ← 複合変換ロジックごと削除
- `segmentize(_:)` ← 上記 azooKey ベース実装に置き換え後
- `fetchDict(reading:)` ← `resizeFocusedSegment` 置き換え完了後
- `historyCount(reading:)` ← DP スコア用途がなくなった後

`history` テーブルと `record()` / `fetchHistoryExact()` は維持。

### Step 5: DictionaryImporter と mozc-dict.sqlite 削除

- `DictionaryImporter.swift` を削除
- `mozc-dict.sqlite` を Resources から削除
- `project.yml` の resources セクション更新
- `DatabaseManager.init()` から `DictionaryImporter.importIfNeeded()` 呼び出しを削除
- `dictionary` テーブルの CREATE / INDEX 定義も削除

### Step 6: テスト整備

- `DictionaryImporter` 関連テストを削除
- azooKey ベースの変換テストを追加
- 既存の候補生成テスト（`testFetchCandidates` 等）を新しい API に合わせて修正

### Step 7: デプロイ・実機確認

```
/deploy
```

確認項目：
- `かんじる → 感じる` が上位に出る
- `とうきょうとっきょきょかきょく` など長文でも自然な候補が出る
- 変換確定後に学習が効いて次回同じ語が上位になる
- 履歴セクションが候補ウィンドウで正しく表示される
- セグメントモードで文節移動が動作する

---

## リスクと対策

| リスク | 内容 | 対応方針 |
|--------|------|---------|
| SWIFT_VERSION 引き上げ | `project.yml` の `"5.9"` → `"6.0"` で strict concurrency チェックが有効になる | Step 1 でビルドし、`Sendable` / actor isolation エラーをその場で修正する |
| ComposingText パラダイム差異 | 現行の `composedHiragana` 文字列との impedance mismatch | Step 2 のアダプターで吸収。`.direct` 入力スタイルで文字列を直接渡す |
| `resizeFocusedSegment` の fetchDict 依存 | 477, 484, 494, 500, 506 行が境界調整のたびに `db.fetchDict()` を呼ぶ。`fetchDict`（単文節候補）と `requestCandidates`（全体変換）は意味論が異なる | Step 0 で単文節ルックアップ API の有無を確認。ない場合は部分読みを渡して代替する |
| N_best の不足 | `N_best: 10` では長文のセグメントモードで候補が足りない可能性 | Step 0 で長文テストを行い、不足なら 20〜30 に増やす |
| バンドルサイズ増加 | azooKey 同梱辞書は ~50MB 級 | Step 1 後に実測。100MB 超なら `KanaKanjiConverterModule`（辞書別途管理）を検討 |
| 学習データの互換性 | azooKey の学習データ形式が独自 | `memoryDirectoryURL` を App Support 配下に設定すれば OK。既存 history は引き続き SQLite で管理 |
| Zenzai（ニューラル変換）| llama.cpp 依存が重い | 初期実装では Zenzai 無効（デフォルト）で進める。動作確認後に検討 |

---

## 残課題（Phase 2 以降）

- Zenzai ニューラル変換の有効化（GPU/CPU 選択）
- azooKey の学習データを history UI に反映（現状は SQLite 履歴と二重管理）
- ユーザー辞書のインポート（`importDynamicUserDictionary`）
- 英語予測モード（`requireEnglishPrediction`）の活用
