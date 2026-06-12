# IME 機能整理・削除候補調査

作成: 2026-05-23

## 背景

keynaco の IME 機能を棚卸しし、役割が不明瞭または削除することでシンプルになりそうな機能を特定した。
ダブルチェックを経て優先度を確定させた。

---

## アクション一覧

### 優先度：高

#### 1. ~~`SegmentizeLRUCache` 削除~~ ✅ 完了（2026-05-23, `476e7f5`）

- **対象**: `Core/Sources/Core/SegmentizeLRUCache.swift`、`InputHandler.swift:136`、`InputHandler+BracketMode.swift:102`
- **理由**: 書き込みは BracketMode の Enter 確定時のみ（`InputHandler+BracketMode.swift:102`）。読み出しシナリオが極めて限定的で、ほぼキャッシュミスのみ。削除してもデグレなし。

#### 2. ~~`tryManualBisection` の判断（sandbox 確認後）~~ → 削除しない（2026-05-23 確認済み）

- **対象**: `Core/Sources/Core/InputHandler+SegmentMode.swift:326-343`
- **2つの呼び出し箇所の性質が異なる**:
  - **line 61（促音誤分割修正）**: 「先頭セグメントが促音(っ)終わり」の誤分割を修正。削除すると「きって」「まって」等を含む入力でセグメントモードが壊れる。**守るべきロジック。**
  - **line 45（辞書候補なし時 1 セグメント分割）**: AzooKey が 1 セグメントしか返さず辞書候補もない場合の fallback 分割。
- **sandbox 確認結果**（`/keynaco-ime-sandbox`, build `476e7f5`）:
  | 入力 | ローマ字 | 結果 | 関与する呼び出し |
  |------|----------|------|------------------|
  | せっていがめん | `setteigamen` | セグメントモード ON → `['設定', '画面']`（先頭候補 `せってい`） | line 61（促音誤分割修正） |
  | きってはり | `kittehari` | セグメントモード ON → `['切手', '貼り']` | line 61 または line 45 |
  | みかんせいかくにん | `mikannseikakunin` | セグメントモード ON → `['未完成', '確認']` | line 45（未知複合語 fallback） |
  | まったく | `mattaku` | セグメントモード OFF（辞書候補 `全く` 等） | いずれも未使用（正常） |
  | たのしい | `tanoshii` | セグメントモード OFF（既知単語） | いずれも未使用（正常） |
- **結論**: 両呼び出しとも実際に機能しており、削除するとセグメントモードの精度が劣化する。関数分割による部分削除も不要。

---

### 優先度：中

#### 3. ~~`LLMMisconversionChecker` — 削除より発見性改善が先~~ ✅ 改善済み（2026-05-23, `a981716`）

- **対象**: `Core/Sources/Core/LLMMisconversionChecker.swift`、`AppDelegate.swift:85-101`
- **現状**: 機能は完全実装済み。確定後 0.5s デバウンスで誤変換をスキャンし、メニューバーアイコンが `⌨` → `⌨!`（オレンジ）に変化、Popover で通知する。
- **改善内容**（`AppDelegate.swift`）:
  - macOS バナー通知（タイトル「keynaco: 誤変換の可能性」+ 指摘本文先頭 200 文字）
  - フォアグラウンドでもバナー・サウンド表示（`UNUserNotificationCenterDelegate`）
  - 通知クリックで Popover を開く
  - ステータスバー `⌨?` → `⌨!` + オレンジ tint で視認性向上
  - クリア時に通知センターから除去
- **方針**: 削除は見送り。発見性改善で十分。

#### ~~4. `expandSuccessorPrefixes` + `splitSurfaceAtParticles` — 貢献度確認後判断~~ → 削除しない（2026-05-23 確認済み）

- **確認結果**: 「からの」という bigram のみ登録されている状態で「k」を打つと `['からの', 'から']` が出る。「から」は `splitSurfaceAtParticles` が「からの」から助詞「の」を除いて生成している。bigram の完全一致だけでは「から」は出ない。実際に機能しており、削除すると bigram に長い助詞句が蓄積されたユーザーの Successor 候補が劣化する。

---

### 優先度：低

#### 5. `generateDateTimeCandidates` — 保留

- **対象**: `Core/Sources/Core/InputHandler+DateTime.swift`
- **現状**: 「きょう」「いま」等の読みに対して ISO・スラッシュ・日本語形式など複数フォーマットの日時を生成。AzooKey では生成しにくいフォーマットも含む。
- **方針**: AzooKey が実際にどのフォーマットをカバーしているかを確認したうえで判断。重複ではなく「追加フォーマット提供」として有用な可能性が高い。

---

### 保留（削除しない）

| 対象 | 理由 |
|------|------|
| `segmentCandidateCache` | Shift+矢印でのセグメント境界連打時に毎回ヒットする。削除すると体感遅延が出る可能性がある |
| `handleBracketChar()` | `「` / `【` / `〔` 等の候補表示は日本語入力の差別化機能 |
| `handleZSequence()` | 定義量が小さく、上級ユーザーへの価値あり |
| `VirtualHistoryExtractor` | Electron 等では機能しないが、取れる環境では Successor の初期精度に直結 |

---

## 進め方

1. ~~`SegmentizeLRUCache` 削除~~ ✅
2. ~~`expandSuccessorPrefixes` 貢献度確認~~ → 削除しない ✅
3. ~~`/keynaco-ime-sandbox` で `tryManualBisection` 関連ケースを確認~~ → 削除しない ✅
4. ~~`LLMMisconversionChecker` 通知改善~~ ✅
5. 残タスク: `generateDateTimeCandidates` 保留判断

---

## 関連コミット

| コミット | 内容 |
|----------|------|
| `476e7f5` | `SegmentizeLRUCache` 削除（アクション 1） |
| `a981716` | `LLMMisconversionChecker` 通知・ステータスバー改善（アクション 3） |

アクション 2（`tryManualBisection`）・4（`expandSuccessorPrefixes`）は sandbox 確認の結果 **削除しない** と判断。コード変更なし。

後続: [`PLAN260523d-ime-simplification-phase1.md`](PLAN260523d-ime-simplification-phase1.md) で IME 入力パイプライン簡素化（Step 1–3 完了、Step 4 未着手）。
