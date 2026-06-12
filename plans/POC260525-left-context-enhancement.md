---
status: implemented
created: 2026-05-25
related_commit: 86c163a
---

# POC260525: leftSideContext 強化による Zenzai 変換品質の改善

検証完了 → [PLAN260525-session-text-buffer.md](PLAN260525-session-text-buffer.md) で実装（コミット `5edf2bc`〜`86c163a`）

## 背景・動機

POC260524 で「leftSideContext が Zenzai の変換品質に支配的な影響を与える」ことが確認された。

しかし現在 Zenzai に渡している leftSideContext は：

```swift
handler.committedHistory.suffix(5).joined()  // 最大5語・数十字
+ documentContextBeforeInput の末尾300字（取れた場合のみ）
```

- `committedHistory` は最大 5 語でローリングされる
- 文末記号（`。` `\n`）でリセットされる → 複数文の文脈が失われる
- `documentContextBeforeInput` は多くのアプリで `NSNotFound` か空になり頼れない

Zenzai が文脈を正しく使えるかは渡す文字列の長さと質に依存する。「どのくらいの長さを渡すと効果が出るか」「文末をまたいだ文脈を渡す価値があるか」を検証していない。

## やりたいこと

**leftSideContext の長さ・内容を変えたとき、Zenzai の変換品質（fixedEnd / top候補）がどう変わるかを系統的に測る。**

### 検証軸

| 軸 | パターン |
|----|---------|
| 長さ | 0字（なし） / 20字 / 50字 / 100字 / 200字 |
| 文末またぎ | 単一文内のみ / 複数文にまたがる |
| 関連性 | 変換対象と関係する文脈 / 無関係な文脈 |

### 検証する入力例

同音異義語や文脈依存性が高い単語を中心に選ぶ：

| 読み | 期待される文脈依存変換 |
|------|----------------------|
| `こうかん` | 技術文脈 → 交換 / 外交文脈 → 交換・交感 |
| `きかん` | 医療文脈 → 気管 / ビジネス文脈 → 機関・期間 |
| `かいぎ` | 会議（一般） / 海技（船員文脈） |
| `しょり` | 処理（技術）/ 処理（一般） |
| `かんり` | 管理 / 官吏（歴史文脈） |

## 探りたいこと

1. **有効な最小文字数**: 何字以上で fixedEnd=1（Zenzai プロモート）が安定して出るか
2. **文末またぎの効果**: `。` をまたいだ前文が文脈として機能するか
3. **無関係文脈の悪影響**: 話題と無関係な長い文脈がノイズになるか
4. **セッションバッファの設計値**: 上限を何字にすれば「長すぎず短すぎず」になるか

## 最小 PoC の実装イメージ

`/keynaco-ime-sandbox` スキルで `set_left_context` を使い、長さを変えた文脈を渡してスコアを比較する。実コードは変えない。

```python
# パターン A: なし
{"set_left_context": ""}

# パターン B: 短い（単一文・20字）
{"set_left_context": "システムの設定を変更した"}

# パターン C: 中程度（50字）
{"set_left_context": "Swiftでサーバーサイドの実装をしていてデータベースとの接続処理を書いている"}

# パターン D: 長い・文末またぎ（100字+）
{"set_left_context": "先週のリリースで負荷が上がった。原因を調査したところ、データベースへのクエリが原因だった。今週はクエリの最適化を進めている"}
```

各パターンで同じ読みを変換し、fixedEnd と top 候補の変化を記録する。

## 実装への示唆（仮説）

POC の結果に応じて、以下のいずれかの方向で実装する：

**効果あり（有効長 N 字が確認できた場合）**  
`committedHistory: [String]` を廃止し、確定テキストを生の文字列として末尾追記するセッションバッファ（上限 N 字）に置き換える。文末でもリセットしない。

```swift
// 現状
var committedHistory: [String] = []           // 最大5語
var leftSideContext: String { committedHistory.suffix(5).joined() }

// 提案（POC 結果次第）
var sessionTextBuffer: String = ""            // 上限N字のリングバッファ
mutating func appendConfirmed(_ text: String) {
    sessionTextBuffer += text
    if sessionTextBuffer.count > N {
        sessionTextBuffer = String(sessionTextBuffer.suffix(N))
    }
}
```

**効果なし（長さを増やしても fixedEnd が変化しない場合）**  
現状維持。content_bigram の代替アプローチを検討する。

---

## 検証結果（2026-05-25）

### 方法

`/keynaco-ime-sandbox` スキルで `set_left_context` を使い、5 語（こうかん・きかん・かいぎ・しょり・かんり）× 5 パターン（A〜E）の組み合わせで fixedEnd と top 候補を記録。

### 結果1: 有効な最小文字数 = 約 10〜15 字

文脈なし（A）は全語で fixedEnd=0。**14字程度の文脈があるだけで大半の語で fixedEnd=1** になることを確認。

| パターン | 文字数 | こうかん | きかん | かいぎ | しょり | かんり |
|---------|------|---------|-------|--------|-------|--------|
| A_なし  | 0字   | 0 | 0 | 0 | 0 | 0 |
| B      | 14字  | 1 | 1 | 1 | 1 | 1 |
| C      | 36〜48字 | 1 | 0* | 1 | 1 | 1 |
| D      | 53〜67字 | 1 | 1 | 1 | 1 | 1 |
| E_無関係 | 47字  | 1 | 1 | 1 | 1 | 1 |

### 結果2: 長い文脈（50字以上）の追加効果は限定的

14字 vs 67字 で fixedEnd の差はほぼなし。top-1 候補に微細な変化（例: こうかんで無関係文脈時 「交換」→「交歓」）はあるが、劇的な改善はない。

### 結果3: `きかん` で文脈末尾語による変換崩れを発見

`きかん` は文脈の末尾が**動詞終止形・連用形（〜した / 〜している）**で終わると fixedEnd=0・top1='き' になる特異な挙動がある。

| 文脈末尾 | fixedEnd | top1 |
|---------|---------|------|
| 〜している      | **0** | 'き' |
| 〜した          | **0** | 'き' |
| 〜している途中で | 1 | '帰還' |
| 〜したところ    | 1 | '期間' |
| 〜の           | 1 | '帰還' |
| 〜した。        | 1 | '期間' |

他の語（こうかん・しょり・かんり）では同様の崩れは発生しない。`きかん` 固有の問題と判断。

典型的な使用パターン（15字前後）で検証した結果、`きかん` 以外の語は動詞終止形末尾でも fixedEnd=1 を維持した。

### 発見のまとめ

| 問い | 結果 |
|------|------|
| 有効な最小文字数は？ | **10〜15字** で大半の語が fixedEnd=1 |
| 長い文脈（50字以上）は追加効果があるか？ | **ほぼなし**。14字と 67字で差がない |
| 文末（。）またぎ文脈は機能するか？ | **機能する**（`D_tech`: 67字で 。をまたいでも fixedEnd=1） |
| 無関係文脈は悪影響があるか？ | **軽微**。fixedEnd は 1 になるが top-1 が変わることがある |
| 文脈末尾語の影響は？ | `きかん` 固有で `〜した/している` 末尾だと崩れる。他語は問題なし |

### 結論・実装方針

**セッションバッファ（文末リセットなし・上限 50 字）への移行が妥当。**

理由：
- 現状の `committedHistory.suffix(5)` は文末（`。` `\n`）でリセットされるため、新しい文の最初の語は leftSideContext が空になる → fixedEnd=0
- 50字のバッファを持てば文末をまたいでも文脈が引き継がれ、安定して fixedEnd=1 になる
- 100字以上に増やしても追加効果が薄いため 50字で十分

**`committedHistory` の廃止は不要。**  
`committedHistory` は `lastCommittedOutput`（直前確定語）の参照にも使われており、セッションバッファとは別の役割がある。両立させる形で実装する。

```swift
// 提案実装
var sessionTextBuffer: String = ""   // 上限 50字、文末でもリセットしない

mutating func appendToSessionBuffer(_ text: String) {
    guard !InputHandler.sentenceTerminators.contains(text) else { return }  // 文末は追記しない（バッファ末尾が 。で終わるのは OK）
    guard !InputHandler.readingPunctuations.contains(text) else { return }
    sessionTextBuffer += text
    if sessionTextBuffer.count > 50 {
        sessionTextBuffer = String(sessionTextBuffer.suffix(50))
    }
}

// leftSideContext への利用（InputController+LLM.swift）
var azooKeyLeftContext: String? {
    sessionTextBuffer.isEmpty ? nil : sessionTextBuffer
}
```

### 結果4: sessionTextBuffer 導入による改善効果の直接検証

「現状（文末後 leftSideContext=""）」vs「提案（文末後も文脈を 50字保持）」を 10 シナリオで比較。

| シナリオ | 文脈（字数） | 現状 fixedEnd | 提案 fixedEnd | 変化 |
|---------|------------|-------------|-------------|------|
| ビジネス文末後・管理 | 22字 | 0 | 1 | ★ 改善 |
| 技術文末後・処理 | 31字 | 0 | 1 | ★ 改善 |
| 会議系文末後・会議 | 23字 | 0 | 1 | ★ 改善 |
| 技術文末後・機関 | 16字 | 0 | 0 | 同じ（きかん固有の崩れ）|
| ビジネス文末後・交換 | 20字 | 0 | 1 | ★ 改善 |
| 文中・会議 | 18字 | 0 | 1 | ★ 改善 |
| 文中・処理 | 22字 | 0 | 1 | ★ 改善 |
| 改行後・管理 | 23字 | 0 | 1 | ★ 改善 |
| 改行後・交換 | 21字 | 0 | 1 | ★ 改善 |
| 改行後・処理 | 30字 | 0 | 1 | ★ 改善 |

**10 シナリオ中 9 件改善・悪化 0 件。**

改善しなかった 1 件（`きかん`・文脈末尾「〜した」）は前述の AzooKey 固有の挙動であり sessionTextBuffer の問題ではない。

現状は文末・改行のたびに `committedHistory` がリセットされて全シナリオで fixedEnd=0 になっている。これが sessionTextBuffer で解消される。

### 最終結論

**sessionTextBuffer（上限 50 字・文末リセットなし）の導入で Zenzai のプロモート率が大幅に改善する。**

- 現状: 文末・改行直後は必ず fixedEnd=0（Zenzai 不発）
- 提案: 文末・改行後も直前の文脈が残り fixedEnd=1（Zenzai プロモート）

**本 POC はクローズ。実装は [PLAN260525-session-text-buffer.md](PLAN260525-session-text-buffer.md) に従い 2026-05-25 にマージ済み。**
