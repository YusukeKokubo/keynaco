---
status: in-progress
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

## 設計方針: 仕様シンプル化（resolver 完全削除を目指す）

仕様を「**候補は scoreBuilder のスコア順、初期行は row 0**」の一文に圧縮する。drift 2 件の各々について実機破綻の有無を確認し、許容範囲なら resolver 完全削除。許容できないなら最小限の補完を scoreBuilder 内（resolver ではなく）に組み込む。

### drift A (history > userDict) の判定

- 仕様変更案: ユーザー辞書 exact > 短文一致 exact 履歴
- 直感的にはユーザー辞書（明示登録）の方が上が自然
- 実機 divergence_log の `initialRowReason` で「userDictExact」「exactMatchHistory」が同時候補で衝突した頻度を確認

### drift B (reading > azooKey prefix) の判定

- 仕様変更案: AzooKey rank 0 が短い真部分文字列でも row 0 にする
- 実機で「reading 全体打ったのに rank 0 が短い接頭辞」が **実際に起こるか** を sandbox で確認
- Zenzai 経由の AzooKey は通常 reading 全体を rank 0 に置くと期待される → 起こらないなら resolver 分岐は dead code

### 不採用の案（記録）

- **案 A**: scoreBuilder に reading 全体ブースト追加 — scoreBuilder の責務が膨らみシンプル化に逆行
- **案 C**: resolver に 1 分岐だけ残す — drift B が dead code なら不要

## Phase

- [x] **Phase 1**: scoreBuilder の tie-break で吸収可能なケースを特定（`ResolverEquivalenceTests` 追加）
  - ✅ **吸収可**: exact 単独 / userDict 単独 / azooKey 単独 / azooKey not prefix of reading
  - ❌ **drift 検出**: history > userDict（scoreBuilder では history=10.001 < userDict=50 で逆転）
  - ❌ **drift 検出**: reading > azooKey prefix（scoreBuilder に reading 全体ブースト無し、短い azooKey 勝ち）
- [x] **Phase 2**: drift 2 件の実機破綻有無を確認
  - **drift B**: sandbox 8 ケースすべてで AzooKey rank 0 == reading（or 全く別の漢字）。真部分文字列が rank 0 になるケースは観測されず → **dead code 扱い**で resolver 削除へ
  - **drift A**: divergence_log に `initialRowReason` フィールド無し（後付け計測は時間コスト大）。シンプル化方針として「userDict > 低頻度履歴」を採用（ユーザー明示登録 > 偶然の低頻度履歴は直感的にも筋通る）
- [x] **Phase 3**: resolver 完全削除
  - `InitialRowPolicyResolver.swift` 削除
  - `InitialRowPolicyResolverTests.swift` 削除（`ResolverEquivalenceTests` に挙動を吸収）
  - `InputHandler+Candidates.swift` の resolver 呼び出しを `initialRow = 0` に置換
  - `CandidateBuildDiagnostics.initialRowPolicy` フィールド削除（debug 内向きのみ、divergence_log には載ってないので影響なし）
  - 仕様変更に伴う既存テスト 3 件更新（`testSnap_E2_UserDictWithHighHistory` / `testSnap_I1_AllSectionsCombined` / `testExplicit_alsoFocusesScoreOrderPrefixHistory`）
- [x] **Phase 4**: `lastInitialRowReason` の値整理
  - 整理後: `hiraganaPreferred` / `hiraganaBuiltin` / `scoreOrder` の 3 種（source 由来のラベルのみ）

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
