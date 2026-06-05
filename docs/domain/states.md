# keynaco 状態遷移

状態の定義と遷移条件のみ。各状態のキー動作詳細は `InputHandler+*.swift` と対応するテスト（`Tests/InputHandler*.swift`）が正本。

## 状態一覧

| 状態 | 条件 |
|------|------|
| **ASCII** | `isAsciiMode = true` |
| **待機** | `isAsciiMode = false`、組成空、特殊モードなし |
| **組成中** | `composedHiragana` または `pendingRomaji` が非空 |
| **候補選択中** | 組成中 + `isExplicitlySelected = true`（↑↓ 操作済み）|
| **括弧モード** | `CandidateSession.bracketCandidates != nil`（`InputHandler.candidateSession`。組成空で `[`/`(`/`!`/`?`/`/`/`.`/`,` 等の記号キーを入力） |

## 状態遷移図

```mermaid
stateDiagram-v2
    [*] --> 待機

    待機 --> ASCII : 英数キー (102)
    ASCII --> 待機 : かなキー (104)

    待機 --> 組成中 : かな系キー入力
    組成中 --> 組成中 : かな系キー入力（蓄積）
    組成中 --> 待機 : Enter（確定）
    組成中 --> 待機 : Escape（クリア）
    組成中 --> ASCII : 英数キー（確定してから遷移）

    組成中 --> 候補選択中 : ↑↓ キー
    候補選択中 --> 候補選択中 : ↑↓ キー（移動）
    候補選択中 --> 待機 : Enter（選択候補を確定）
    候補選択中 --> 候補選択中 : Space（次候補）
    候補選択中 --> 待機 : →（組成テキストをひらがなのまま確定）
    候補選択中 --> 待機 : Escape（クリア）

    待機 --> 括弧モード : 記号キー（`[`/`(`/`!`/`?`/`/`/`.`/`,` 等）
    括弧モード --> 括弧モード : ↑↓ / Space / Tab（候補移動）
    括弧モード --> 待機 : Enter（選択候補を確定）
    括弧モード --> 待機 : Escape / Backspace（キャンセル）
    括弧モード --> 組成中 : その他キー（選択候補を確定してから通常入力）

    組成中 --> 候補選択中 : Space（候補窓表示 / 次候補）
```

## キー処理パイプライン（候補・marked text）

`InputHandler` はキー → `CandidateAction` のみ返す。IMK への marked text 反映と候補ウィンドウ更新は `InputController` に集約する。

```mermaid
flowchart LR
    KD[keyDown] --> H[InputHandler.handle]
    H --> CA[CandidateAction]
    CA --> SA[candidateSession.apply]
    SA --> MT[syncMarkedText]
    SA --> CW[CandidateWindow]
    MT --> IMK[IMK client]
```

## 注意点

- **`isAsciiMode` は static**: アプリ切替後もモードを維持。テストの `setUp` でリセット必須
- **キー動作詳細**: 各状態の細かいキー動作（Backspace の挙動・候補選択中の `.` `,` での組成追加など）は `InputHandler+*.swift` および対応テストを参照。ここに書くと drift する
