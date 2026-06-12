# 辞書を SKK-JISYO-L から mozc システム辞書へ切り替える

## 背景と目的

現在の辞書は SKK-JISYO-L（~5.9MB, 約17万行）。  
活用形は okuri-ari エントリ（`かんz /感/` 等）を展開することで生成しているが、
構造上カバーできないパターンが多発している（例: `かんじる → 感じる`、一段動詞終止形、形容詞の一部など）。

[google/mozc](https://github.com/google/mozc) のシステム辞書（OSS 版）に切り替えることで：

- 終止形・連体形など辞書に直接登録された活用形が大幅に増える
- 一般名詞・固有名詞のカバレッジが飛躍的に向上（~100 万エントリ）
- `cost` フィールドによる自然な頻度順ソートが使える
- okuri-ari の手動展開ロジックが不要になる

---

## mozc 辞書のフォーマット

### ファイル構成（OSS版）

`src/data/dictionary_oss/` 以下：

| ファイル | 内容 | サイズ目安 |
|---|---|---|
| `dictionary00.txt` ～ `dictionary09.txt` | 単語エントリ（10分割） | 各 ~8MB |
| `suffix.txt` | 活用語尾（て形・た形など機能語） | 小 |
| `id.def` | 品詞IDテーブル | 小 |
| `connection_single_column.txt` | 接続コスト表 | ~35MB |

### エントリフォーマット（TSV 5列）

```
reading<TAB>left_id<TAB>right_id<TAB>cost<TAB>surface
```

例：
```
かんじる	1320	1320	3821	感じる
ろんじる	1320	1320	4102	論じる
とうきょう	1851	1851	3024	東京
```

- `cost`：対数確率の負スケール。**低いほど高頻度**（= 高優先）。
- `left_id` / `right_id`：品詞・活用種別の ID（接続コスト計算用。今フェーズでは使わない）。

### priority フィールドの向き（確認済み）

`DatabaseManager.fetchDict` は `ORDER BY priority ASC`。  
→ `cost` をそのまま `priority` に入れれば**低コスト（高頻度）が先頭**になり設計と一致する。

---

## 活用形のカバレッジについて

mozc の辞書は活用形を **一部は明示エントリとして持ち、残りは `suffix.txt` の接尾辞ルールで動的生成** する設計。
終止形（`感じる`）は明示エントリに存在するが、て形（`感じて`）・た形（`感じた`）等はエントリに含まれないケースもある。

今フェーズでは：
1. mozc の明示エントリをそのままインポートする（終止形・一部活用形）
2. SKK の okuri-ari 展開は**廃止**（mozc で補われる分を優先）
3. て形・た形など mozc でカバーされない活用形は、**Step 5 実機確認後に判断**する
   - 充分ならそのまま
   - 足りなければ Phase 2 で `suffix.txt` を使った展開を追加する

---

## 取得・前処理（Step 0）

### ⚠️ 最優先・最大リスク

~100 万エントリを実行時に INSERT すると 30〜60 秒かかる可能性がある。  
初回起動時に IME が無応答になるのは致命的なため、**ビルド時に SQLite を事前生成してバンドルする** 方式を採用する。  
実行時インポートは ATTACH + 一括 INSERT のみとし、gzip 展開はしない。

### mozc リポジトリの取得

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/google/mozc.git mozc-src
cd mozc-src
git sparse-checkout set src/data/dictionary_oss
```

### 前処理スクリプト（Python）: `.sqlite` を出力

全10ファイルを結合し、ykey と同じスキーマの SQLite データベースを生成する。  
**gzip を使わない**（gzip の展開方式に実装リスクがあるため。後述）。

```python
# scripts/build_mozc_dict.py
import sqlite3, glob

conn = sqlite3.connect("Resources/mozc-dict.sqlite")
conn.execute("""
    CREATE TABLE dictionary (
        reading   TEXT NOT NULL,
        candidate TEXT NOT NULL,
        priority  INTEGER NOT NULL,
        UNIQUE(reading, candidate)
    )
""")
conn.execute("CREATE INDEX idx_reading ON dictionary(reading)")

rows = []
for path in sorted(glob.glob("mozc-src/src/data/dictionary_oss/dictionary*.txt")):
    with open(path, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 5:
                continue
            reading, cost, surface = cols[0], cols[3], cols[4]
            # ひらがな読みのみ採用
            if not all(0x3040 <= ord(c) <= 0x30FF or c == "ー" for c in reading):
                continue
            # reading == surface の純カナエントリは除外
            if reading == surface:
                continue
            rows.append((reading, surface, int(cost)))

conn.executemany(
    "INSERT OR IGNORE INTO dictionary VALUES (?, ?, ?)", rows
)
conn.commit()
conn.close()
print(f"Inserted {len(rows)} entries")
```

**出力**: `Resources/mozc-dict.sqlite`（推定 50〜80MB。App Bundle にバンドル）

> **ファイルサイズが大きすぎる場合**: `int(cost) < 10000` 等の閾値フィルタを追加して高頻度語に絞る。

---

## gzip を使わない理由

`import Compression` は zlib raw deflate のみ対応で、gzip ヘッダ（10 バイト）とフッタを別途スキップする必要がある。  
`libz`（`import zlib`）の `inflateInit2(&stream, 47)` を使えば対応できるが、実装コストがかかる。  
SQLite をそのままバンドルすれば展開処理が不要になり、リスクごと排除できる。

---

## DictionaryImporter の変更設計

### 削除するもの

| 現在の要素 | 削除理由 |
|---|---|
| `consonantToKana` テーブル | okuri-ari 展開ロジックごと削除 |
| `teFormSuffix` テーブル | 同上 |
| z行一段動詞展開（今回追加分） | mozc に直接エントリがある |
| `adjective-supplement.utf8` | mozc のカバレッジで不要になる見込み |
| `primaryConsonants` Phase 1 スキャン | 同上 |

### 新しいインポートロジック

```swift
static func importIfNeeded(db: OpaquePointer?) {
    // バージョンチェック（currentVersion を 8 に上げる）
    // ...

    // バンドル済み mozc-dict.sqlite を ATTACH して一括 INSERT
    guard let bundledPath = Bundle.main.path(forResource: "mozc-dict", ofType: "sqlite") else {
        NSLog("ykey: mozc-dict.sqlite が見つかりません")
        return
    }

    let attachSQL = "ATTACH DATABASE '\(bundledPath)' AS mozc"
    guard sqlite3_exec(db, attachSQL, nil, nil, nil) == SQLITE_OK else { return }
    defer { sqlite3_exec(db, "DETACH DATABASE mozc", nil, nil, nil) }

    // DELETE を BEGIN の内側に入れる。INSERT 中クラッシュしても辞書が空にならない。
    sqlite3_exec(db, "BEGIN", nil, nil, nil)
    sqlite3_exec(db, "DELETE FROM dictionary", nil, nil, nil)
    sqlite3_exec(db,
        "INSERT OR IGNORE INTO dictionary (reading, candidate, priority) SELECT reading, candidate, priority FROM mozc.dictionary",
        nil, nil, nil)
    sqlite3_exec(db, "COMMIT", nil, nil, nil)
}
```

ATTACH + `INSERT ... SELECT` は SQLite ネイティブのバルク転送で、1行ずつ INSERT より数倍高速。

---

## 移行戦略

| 辞書 | 扱い |
|---|---|
| `SKK-JISYO-L.utf8` | Resources から削除 |
| `adjective-supplement.utf8` | 削除（mozc でカバー確認後） |
| `mozc-dict.sqlite` | 新たにバンドル |

`DatabaseManager` の `insertDict` / `fetchDict` / `fetchCandidates` の API は変更なし。  
`DictionaryImporter` の内部実装を差し替えるだけ。

---

## 実装ステップ

### Step 0: 前処理スクリプトと mozc-dict.sqlite 生成 ⚠️ 最優先

1. git-lfs を先に設定する（50〜80MB のバイナリを直コミットするとリポジトリが肥大化するため）
   ```bash
   git lfs install
   git lfs track "*.sqlite"
   git add .gitattributes
   ```
2. `git clone`（sparse checkout）で mozc リポジトリを取得
3. `scripts/build_mozc_dict.py` を実装・実行
4. エントリ数・ファイルサイズを確認（大きすぎれば cost 閾値フィルタを追加）
5. `Resources/mozc-dict.sqlite` をコミット（git-lfs 経由）

### Step 1: DictionaryImporter 書き換え

1. okuri-ari 展開ロジック（`consonantToKana`・`teFormSuffix`・`primaryConsonants`）を削除
2. `mozc-dict.sqlite` を ATTACH して `INSERT ... SELECT` するロジックに差し替え
3. `currentVersion` を 8 に上げる

### Step 2: リソース整理

- `project.yml` の resources セクション: `SKK-JISYO-L.utf8`・`adjective-supplement.utf8` を削除、`mozc-dict.sqlite` を追加
- `GzipReader.swift` は不要なので作成しない

### Step 3: テスト整備

- okuri-ari 前提のテスト（`testOkuriAriInvalidFormExcluded` 等）を削除
- mozc ベースの新テストを追加（下記参照）
- **SKK 現行動作との比較テスト**（回帰検知用）を追加（下記参照）

### Step 4: デプロイ・実機確認

```bash
/deploy
```

確認項目：
- `かんじる → 感じる`（mozc 明示エントリ）が候補に出る
- `とうきょう → 東京` が正しい優先順で出る
- インポート時間が許容範囲（目安: 5秒以内）
- **`かんじて → 感じて`、`かんじた → 感じた` が出るか確認** → 出なければ Phase 2 として計画

---

## テスト方針

### mozc ベース新テスト

```swift
func testMozcBasicNoun() {
    XCTAssertTrue(dictDB.fetchCandidates(prefix: "とうきょう").candidates.contains("東京"))
}
func testMozcIchidanVerb() {
    XCTAssertTrue(dictDB.fetchCandidates(prefix: "かんじる").candidates.contains("感じる"))
}
func testMozcCostOrdering() {
    // 低コスト（高頻度）が先頭に来ること
    // ORDER BY priority ASC = 低コスト優先（確認済み）
    let result = dictDB.fetchCandidates(prefix: "かいぎ")
    let idxKaigi  = result.candidates.firstIndex(of: "会議")!
    let idxKaigi2 = result.candidates.firstIndex(of: "懐疑")!
    XCTAssertLessThan(idxKaigi, idxKaigi2, "会議（高頻度）が懐疑より先")
}
```

### SKK 現行との比較テスト（回帰検知用）

```swift
// SKK 時代に通っていたケースが mozc でも通ることを確認する
func testRegressionKanjiru() {
    // 現行: z行展開で生成。mozc: 明示エントリで生成。どちらも通るはず。
    XCTAssertTrue(dictDB.fetchCandidates(prefix: "かんじる").candidates.contains("感じる"))
}
func testRegressionKanjite() {
    // SKK: かんじて → 感じて を生成していた（z行+te形）
    // mozc: 明示エントリがない場合は Phase 2 で対応する
    // CI をブロックしないよう XCTExpectFailure でラップ。mozc で取れれば自動的に外れる。
    XCTExpectFailure("Phase 2 未実装: mozc に感じて の明示エントリがない場合は落ちる") {
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かんじて").candidates.contains("感じて"))
    }
}
func testRegressionKanjita() {
    XCTExpectFailure("Phase 2 未実装: mozc に感じた の明示エントリがない場合は落ちる") {
        XCTAssertTrue(dictDB.fetchCandidates(prefix: "かんじた").candidates.contains("感じた"))
    }
}
```

---

## 残課題・リスク

| 課題 | 内容 | 対応方針 |
|---|---|---|
| 活用形カバレッジ | て形・た形・ない形が mozc 明示エントリに含まれるか未確認 | Step 4 実機確認後に判断。不足なら Phase 2 で `suffix.txt` 展開を追加 |
| ファイルサイズ | `mozc-dict.sqlite` が 80MB 超の場合 App Bundle が肥大化 | `cost < 10000` 等の閾値フィルタで高頻度語に絞る。または git-lfs 管理 |
| インポート時間 | ATTACH + `INSERT ... SELECT` でも数秒かかる可能性 | 実測して許容範囲か確認。遅ければバックグラウンドスレッド化 |
| ライセンス | mozc 辞書は BSD-3 + NAIST/ICOT | About 画面等に帰属表示を追加する |
| segmentize への影響 | 辞書エントリ数の増加で DP スコアリングの挙動が変わる可能性 | 既存 segmentize テストが通ることを確認。回帰があれば調整 |

---

## Phase 2 以降（今フェーズでは実装しない）

- `suffix.txt` を使った活用形展開（て形・た形・条件形など）
- `connection_single_column.txt` を使った格子 + Viterbi デコーダ
- N-gram 言語モデルによる候補リランキング
