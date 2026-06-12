# Successor モード：確定直後依存をなくし入力起動に変更

## 背景・目的

現在の Successor モードは「語を確定した直後の1打目」でのみ起動する。
これを「組成なし・ASCII モードでない状態で通常キーを入力した瞬間」に起動するよう変更し、
`leftSideContext`（カーソル左文脈）を使って文脈に合った候補を出す。

メンタルモデルの変化:
- Before: 「名詞を確定した直後だけ候補が出る」（内部状態に依存）
- After:  「組成なし状態でキーを打ったら候補が出る（こともある）」（直感的）

## 変更方針

### トリガー条件の変更

| 条件 | Before | After |
|------|--------|-------|
| 組成が空である | 必要 | 同じ |
| ASCII モードでない | 必要 | 同じ |
| 直前確定が名詞系 | **必要** | **不要** |
| `isSuccessorMode == true` | 必要（事前にセット） | **不要**（毎回その場で判定） |

### `isSuccessorMode` フラグの廃止

現在は「確定時に `suggestSuccessors()` → `isSuccessorMode = true` → 次キーで `handleSuccessorModeKey`」という2段構えになっている。
新設計では「通常入力の先頭で候補クエリ → あれば Successor 候補を表示、なければ通常入力」という1段に統一する。
→ `isSuccessorMode` / `successorFirstChar` / `pendingSuccessorCandidates` フラグは **削除**。

### 文脈ノウンの取得元変更

```
Before: lastConfirmedNounOutput（確定時にセット）
After:  leftSideContext の末尾から名詞らしい語を抽出
        ↓
        失敗（空・取得不可）なら lastCommittedOutput にフォールバック
        ↓
        それも nil なら候補なし → 通常入力へ
```

#### 末尾名詞の抽出ロジック（`extractNounFromContext`）

`leftSideContext` の末尾から逆順に走査し、「漢字またはカタカナのみで構成される連続スパン」を返す。
例: `"今日は東京に"` → `"東京"`。
文字コードレベルの判定なので LLM 不要。`isNounLike` の判定条件と同じ範囲を使う。

### 候補クエリの変更

```swift
// 新しい trySuccessorCandidates(romajiChar:) の概略
func trySuccessorCandidates(romajiChar: String) -> [String]? {
    guard let kanas = romajiToInitialKana[romajiChar], !kanas.isEmpty else { return nil }
    let noun = extractNounFromContext(leftSideContext) ?? lastCommittedOutput
    var seen = Set<String>()
    var result: [String] = []
    for kana in kanas {
        if let noun {
            for s in db.fetchNounBigram(prev: noun, reading: kana)
                where seen.insert(s).inserted { result.append(s) }
        }
        for s in db.fetchHistoryPrefix(reading: kana)
            where seen.insert(s).inserted { result.append(s) }
    }
    return result.isEmpty ? nil : Array(result.prefix(LearningThresholds.successorMaxCandidates))
}
```

### 通常入力パスへの組み込み

`handleNormalInput` の先頭（組成が空のとき）で `trySuccessorCandidates` を呼ぶ。
候補があれば `.show(...)` を返し Successor 候補ウィンドウを表示。
候補がなければ従来通り通常入力を処理する。

候補表示後のキー処理は現在の `handleSuccessorModeKey` のロジックをほぼ流用するが、
「モードに入る」のではなく `candidate.isVisible` で分岐する形に変える。

### `suggestSuccessors` / `confirmSuccessor` の扱い

- `suggestSuccessors()` は確定後に呼ばれていたが、**削除**（確定後は何もしない）。
- `confirmSuccessor()` は残す（候補選択確定の処理として流用）。
- 確定後の `handleSuccessorModeKey` → `suggestSuccessors()` チェーン呼び出しも削除。

### `lastConfirmedNounOutput` の扱い

現在は LLM POS 分類後の noun_bigram 記録用として使われているため **残す**。
ただし Successor トリガーには使わなくなる。
`extractNounFromContext` で文脈から都度取得するので不整合は起きない。

## 影響範囲

| ファイル | 変更内容 |
|--------|---------|
| `InputHandler+SuccessorMode.swift` | `suggestSuccessors` 削除・`trySuccessorCandidates` 追加・`extractNounFromContext` 追加・`handleSuccessorModeKey` をスリム化 |
| `InputHandler.swift` | `isSuccessorMode` / `successorFirstChar` / `pendingSuccessorCandidates` フィールド削除 |
| `InputHandler+NormalInput.swift` | 組成空の通常入力先頭で `trySuccessorCandidates` を呼ぶよう変更 |
| `InputHandlerSuccessorTests.swift` | `isSuccessorMode` を前提とするセットアップを変更、新しいトリガー条件でのテストを追加 |
| `docs/domain/architecture.md` | Successor モードの説明を更新 |

## 実装ステップ

1. `extractNounFromContext` を `InputHandler+SuccessorMode.swift` に追加（テスト先行）
2. `trySuccessorCandidates` を実装（テスト先行）
3. `handleNormalInput` の組成空パスで `trySuccessorCandidates` を呼び出し
4. `suggestSuccessors` 呼び出し箇所をすべて削除し `isSuccessorMode` フラグを削除
5. `handleSuccessorModeKey` を `candidate.isVisible` ベースのロジックに移植
6. テスト修正・追加
7. `/keynaco-ime-sandbox` でE2E検証（確定後・文書途中入力・Electron 等）
8. `docs/domain/architecture.md` 更新

## リスク・注意点

- `leftSideContext` はアプリ非対応時に空になる。空でも `lastCommittedOutput` フォールバックがあるので最低限の動作は保証できる。
- 組成空でキーを打つたびに DB クエリが走るので、候補0件のパスが高速である必要がある。`fetchNounBigram` / `fetchHistoryPrefix` は軽量なので問題ないはず（要計測）。
- Bracket モード入力（`,`/`.` 等）と競合しないよう、`trySuccessorCandidates` は ASCII 英字キーのみを対象にする（既存の `romajiToInitialKana` のキーに限定）。
