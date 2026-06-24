---
status: draft
created: 2026-06-24
---

# PLAN260624b: `InitialRowPolicyResolver` の `.explicit` 経路整理

## 背景

[PLAN260624](PLAN260624-unified-candidate-scoring.md) 統一スコアリングの Phase 3「dead code 削除」で「`InitialRowPolicyResolver` の大部分削除」を計画したが、`.explicit` トリガの 1 分岐だけ score builder で表現できず保留にした。

具体的には `Core/Sources/CoreTests/InitialRowPolicyResolverTests.swift` の以下 2 ケース:

```swift
testPrefersReadingWhenFirstInCandidateList:
  reading="うおうお", azooKeyCandidates=["うお", "魚屋"]
  → row 0 = "うおうお" を期待

testPrefersFullReadingOverAzooKeyShorterPrefix:
  reading="これでは", azooKeyCandidates=["これで", "これでは", "コレデ"]
  → row 0 = "これでは" を期待
```

意図は **「AzooKey が reading の真部分文字列を rank 0 で返したとき、reading 自体が候補リストにあるなら reading を優先する」**。`.whileTyping` では `afterFixed`（row 0）固定で済むが、`.explicit` ではこの reading-prefer ロジックが残ってしまう。

## 現状の resolver

```swift
static func resolve(_ input: InitialRowPolicyInput) -> InitialRowPolicy {
    if let first = input.exactMatchHighHistory.first {
        return .firstMatching(first)
    }
    if let first = input.userDictExact.first {
        return .firstMatching(first)
    }
    if input.candidateList.first == input.reading {
        return .firstMatching(input.reading)
    }
    if let first = input.azooKeyCandidates.first {
        if first != input.reading,
           input.reading.hasPrefix(first),
           first.count < input.reading.count,
           input.candidateList.contains(input.reading) {
            return .firstMatching(input.reading)   // ← この 1 分岐が肝
        }
        return .firstMatching(first)
    }
    return .afterFixed
}
```

- exact 履歴 / userDict / azooKey 単純先頭の 3 分岐は **scoreBuilder の tie-break で自然に row 0** になるはず（`historyExact > historyPrefix > userDict > azooKey` の優先度）
- 残る 1 分岐が reading-prefer-over-azooKey-prefix

## 設計の選択肢

### 案 A: scoreBuilder で「reading 全体ブースト」を表現

reading 全体が候補リストにあり、かつ AzooKey 候補が reading の真部分文字列のとき、reading 行に bonus score を加算する。

- 良い点: resolver 完全削除、ロジックが scoreBuilder 内に集約
- 悪い点: scoreBuilder の責務が増え、score 計算 → 関係性判定 → 再 score 加算の二段処理が要る

### 案 B: 該当テストの挙動を変える

`testPrefersFullReadingOverAzooKeyShorterPrefix` が想定する挙動を捨てる。AzooKey が `これで` を rank 0 で返すなら row 0 = `これで` でよいとする。

- 良い点: 実装が最小化（resolver 削除 + scoreBuilder 不変）
- 悪い点: ユーザー体感の変更。`これでは` 打ってる以上「これで」で確定したくないケースは多いはず。divergence_log でこのケースの頻度確認が要る

### 案 C: resolver の該当分岐だけ残す（推奨）

scoreBuilder で吸収可能な分岐 3 つを削除し、reading-prefer 分岐だけ resolver に残す。`lastInitialRowReason` の値も整理する。

- 良い点: 各案のリスクをバランス。機械的な整理で済む
- 悪い点: resolver が「特殊ロジック専用」として残り続ける

## 推奨案 C の Phase

- [ ] **Phase 1**: scoreBuilder の tie-break で吸収可能なケースを特定
  - `testExactMatchHistorySelectedFirst`
  - `testUserDictExactSelectedWhenNoHistory`
  - `testHistoryBeatsUserDictExact`
  - `testAzooKeyFirstSelectedWhenNoHistoryNoUserDict`
  - `testAzooKeyFirstUnchangedWhenNotPrefixOfReading`
  - これらが scoreBuilder の score 順 + tie-break で row 0 に来ることをユニットテストで確認
- [ ] **Phase 2**: resolver から該当分岐を削除し、`afterFixed` を返すよう簡素化
  - `exactMatchHighHistory` / `userDictExact` 引数を `InitialRowPolicyInput` から外す
  - `azooKeyCandidates.first` の単純分岐も削除
- [ ] **Phase 3**: reading-prefer-over-azooKey-prefix 分岐だけ残す
  - resolver は 1 メソッド・5 行程度になる想定
- [ ] **Phase 4**: `lastInitialRowReason` の値整理
  - 旧値: `exactMatchHistory` / `historyPrefix` / `userDictExact` / `azooKey` / `hiraganaPreferred` / `hiraganaBuiltin` / `afterFixed` / `scoreOrder`
  - 整理後: `scoreOrder` / `hiraganaPreferred` / `readingPreferOverAzooKeyPrefix` / `afterFixed` の 4 種程度

## 検証

| 層 | 内容 |
|----|------|
| ユニット | `InitialRowPolicyResolverTests` を残った 2 ケースに絞る。scoreBuilder 経由で吸収されるケースは `CandidateScoreBuilderTests` で確認 |
| 回帰 | `./scripts/test_core_all.sh` で全 488 件緑維持 |
| sandbox | `.explicit` で `これでは` / `うおうお` の挙動が変わらないこと、`じょう→情報共有` の Space 後 row 0 も維持 |
| 観測 | divergence_log の `initialRowReason` 分布が想定通り（`scoreOrder` の比率が上がる）か事後確認 |

## リスク

| リスク | 対策 |
|--------|------|
| scoreBuilder の tie-break 順が `testExactMatchHistorySelectedFirst` 等で本当に row 0 を返すか不明 | Phase 1 で scoreBuilder の単体テストを先に書いて確認してから resolver を触る |
| 履歴 score 0.5 境界ケース | `historyRecencyScoreCutoff` を変えない前提で、cutoff 付近のスコアが落ちるケースは scoreBuilder にも resolver にも届かないので影響なし |
| `lastInitialRowReason` 値削減で divergence_log の過去ログ解析互換性が崩れる | 整理後の値は新規ログのみ。過去ログ解析側（profiler 等）が旧値を扱える状態なら問題なし |

## スコープ外

- `CandidateBuildDiagnostics` の JSON キー名（`exactMatchHighHistory` / `highHistory`）変更 — 後方互換のため touch しない
- 変数名 `exactMatchHighHistory` / `highHistory` のリネーム — 内部命名の好みレベル、PR ノイズ大
- `.whileTyping` トリガの挙動 — 既に `afterFixed` で完結しとる

## 関連

- [PLAN260624-unified-candidate-scoring.md](PLAN260624-unified-candidate-scoring.md) — Phase 3 の保留分を本 PLAN で消化
- `Core/Sources/Core/InitialRowPolicyResolver.swift`
- `Core/Sources/Core/InputHandler+Candidates.swift`（resolver 呼び出し元）
- `Core/Sources/CoreTests/InitialRowPolicyResolverTests.swift`
