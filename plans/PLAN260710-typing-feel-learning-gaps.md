---
status: draft
created: 2026-07-10
related_plan: PLAN260704b-typing-feel-roadmap.md
---

# PLAN260710: 打鍵体感改善ロードマップ第 2 弾 — 履歴学習の穴と prefix 習慣

PLAN260704b（第 1 弾）の A/B 系施策が完了した後の再計測（2026-07-10、latency 2666 セッション・input 8242 確定/14 日・divergence 1862 件）で出てきた、**新しい種類の犯人**への施策一覧。第 1 弾はレイテンシ（速度）が主軸だったが、今回の pain の主因は速度ではなく「同じ読みで毎回同じ引っかかり方をする」学習系の構造問題。

**このファイルはロードマップ（親 plan）**。各施策に着手するときは `/keynaco-perf-cycle` で `objective_axis` を 1 つに絞った個別 plan を切り、このファイルの進捗表を更新する。

## 実装状況

| 施策 | 優先 | 状態 | 個別 plan |
|------|------|------|-----------|
| D1 助詞トリムの lcid 判定化 | 1 | draft | [PLAN260710a](PLAN260710a-particle-trim-lcid.md) |
| E1 prefix 習慣学習（whileTyping 限定） | 2 | 未着手 | — |
| D2 文節完成形（内容語+助詞）の row 0 到達 | 3 | 未着手 | — |
| F1 起動キャッシュウォームアップ | 4 | 未着手 | — |
| F2 打鍵中の長読み Zenzai テール抑制 | 観察 | 未着手 | — |

## grill 決定（2026-07-10）

優先順位は入れ替えない。順序の根拠は次の 4 本柱:

1. **構造バグ先行（土台）** — 誤トリムは学習の土台が壊れている
2. **変更コスト小** — D1 は判定差し替え、E1 は新学習面でリスクが大きい
3. **被害が計測値より広い** — pain 閾値外の摩擦＋ `trailingParticles` 15 種の同型語（後述）
4. **E1 が D1 に依存** — 誤トリム前に prefix 実績を作ると壊れた reading が新テーブルへ伝染する。D1 → 検証 window → E1 なら before/after の対称性も保てる

その他の決定は各施策節に反映済み。

## 背景：診断結果（2026-07-10 計測）

1 位確定率 89.2%・fetch_complete 中央値 219ms と、平均値はどちらも健全。pain ケース（BS≥2 / scroll>0 / 3 秒超）は全確定の 9.8%（806/8242）で、その常連を掘ると**履歴 DB に学習が届いとらん構造的な穴**が 2 つ見つかった。

### 発見 1: 助詞トリムの誤爆で頻出語が永遠に学習されん

`recordPrefixes` の `trimTrailingParticle`（`DatabaseManager+History.swift`）は末尾助詞を**文字列サフィックスだけ**で判定する。「特に」（副詞、「に」は語の一部）が「とく→特」にトリムされ、履歴 DB には `とく→特 count=31` だけが育ち、「とくに→特に」の行は存在しない。ユーザーは 31 回確定しとるのに「特に」が row 0 に来る日は永遠に来ん。

実測の被害（直近 14 日の pain）:

| reading | 確定 | pain 回数 | 症状 |
|---------|------|-----------|------|
| とくに | 特に | 12 | 毎回 scroll 1〜3 |
| いまは | 今は | 14 | 毎回 scroll 2〜3（履歴行 count=0） |

コード内コメントで「誤トリムは reading も同時に壊れるから実害が薄い」と許容されとったが、実害は薄くなかった（読みが `とく` に壊れる = 壊れた行が育つ、が正解だった）。

### 発見 2: prefix 習慣が最長読み統合に吸われて学習されん

`recordPrefixesOnQueue` は同一 output の読みを最長 1 行に統合する。このため「短い prefix でどの output を選んだか」という習慣は記録に残らず、prefix スコアは常に全体頻度で決まる。

| 打鍵 prefix | 選んだ候補 | pain 回数 | 阻んどる行 |
|-------------|-----------|-----------|-----------|
| とりひ | 取引先ユーザー | 31 | とりひきさき→取引先 (count=180) |
| れびゅ | レビューして | 23 | れびゅー→レビュー (count=105) |
| してき | 指摘対応 | 12 | してき→指摘 (count=56) |

動線は毎回同じ: autoShow の row 0 に欲しい方が来ん → Space → explicit は exact 優先ルールで prefix 候補が下がる → scroll 1〜3 で追いかける（1.5〜2.5 秒/回）。**explicit の exact 優先は確認済みの方針なので触らない**。直すのは whileTyping の並びだけ。

### レイテンシ側の残り火

| 指標 | 値 | 第 1 弾（2026-07-04）比 |
|---|---|---|
| fetch p50 / p95（セッション avg） | 123.3ms / 199.5ms | 微増（97.8 / 183.8） |
| fetch_complete p50 / p95 | 234.1ms / 294.0ms | 微増（205.0 / 260.9） |
| キャッシュ exact / prefix / miss | 7.2% / 38.0% / 54.7% | miss 増（43.3%） |
| 2 文字読みミス | 率 91.6%・7833 件 | 増（87.1%・821 件） |
| wasted fetch | 35.2% | 悪化（直近 7 日 17.4% → 全期間並みに回帰） |
| lock_wait 最大 | 2290ms（`せんこうたいけん`） | 悪化（858ms） |
| fetch_complete_p95 ≥ 300ms セッション | 36.5% | 悪化（20.5%） |
| pain ケース率 | 9.8%（806/8242、14 日） | 改善（16.3%） |
| divergence 真の UX 損失 / 救済 | 516 / 1346（救済率 72%） | 救済率同水準 |

pain 率は下がった一方、fetch 系のテールはやや悪化しとる。ただし中央値は健全で、テールの主因は長読み（6〜8 文字）打鍵中の Zenzai 推論が破棄される連鎖（例: `せんこうたいけ` fetch 1184ms 破棄 → 直後の `せんこうたいけん` が lock_wait 2290ms）。今回の主軸は学習系（D/E）とし、レイテンシは F で様子を見る。

## 施策 D: 履歴学習の穴をふさぐ

### D1. 助詞トリムの lcid 判定化（本命）

**優先 1 の根拠（4 本柱）**:

1. **構造バグ先行** — 誤トリムは「確定しても永遠に直らない」タイプ。件数より先に土台を直す
2. **変更コスト小** — 判定差し替えが主。E1 の新テーブル＋加点より blast radius が小さい
3. **被害が計測値より広い** — pain 抽出は BS≥2 / scroll>0 / 3 秒超の閾値付きで、「scroll 1 回」「目で探しただけ」は数字に出ん。`trailingParticles` は 15 種の文字列サフィックスなので「特に」以外にも「主に」「次に」「一緒に」「ちゃんと」「いつも」等、末尾がたまたま助詞文字の語は全部同じ穴に落ちる。「とくに ≈12」は氷山の一角
4. **E1 が D1 に依存** — E1 の prefix 習慣記録は確定パイプライン（`recordPrefixes` 周辺）に乗る。誤トリムを直す前に作ると「とくに→特に」の選択実績が「とく→特」キーで新テーブルにも伝染し、D1 実装時に新テーブル掃除まで仕事が増える。順序を守れば E1 は最初からきれいな reading で記録できる。D1 → 検証 window 消化 → E1 なら、E1 のベースラインが D1 適用後の履歴で取れ、before/after の対称性も保てる

**設計決定（grill）**:

- 判定は **`CIDData.isJoshi` のみ**（助動詞レンジ `369...554` は入れない。「食べた」等を壊さんため。必要なら別 plan）
- トリム条件は **`data.count >= 2` かつ末尾セグメントが joshi**。単一セグメント語（「特に」が副詞 1 セグメントで引ける場合）は定義上トリム対象外になり、安全側に倒れる
- セグメント情報が取れんとき（履歴・ユーザー辞書・ひらがな・キャッシュミス等）は **トリムしない**（壊れた行が育つ害 > 統合漏れの害）。文字列サフィックス fallback は残さない。commit 経路で converter を同期ロックして lcid を取りに行かない
- **joshi 判定の入手経路は「fetch 時に flag を運ぶ」方式に固定**: `commitComposition`（`InputHandler.swift:252`）に届くのは `candidate.selectedText`（String）だけでセグメント情報は既に落ちとる。converter キャッシュから引き直す既存手段（`canonicalReading` / `commit`）はどちらも `LockedConverter` のロックを取るため、Zenzai 推論中の確定でブロックする＝同期ロック禁止の決定に違反。よって `displayCandidates`（`AzooKeyConverter.swift:62`）で `candidate.data` が手元にあるうちに「末尾セグメントが joshi か」を `AzooKeyCandidate` に載せ、ScoredCandidate → CandidateContext で確定まで運ぶ（追加ロックゼロ）
- 帰結として **trim が走るのは azooKey 候補確定のみ**。素の reading 確定・F6–F10（`InputHandler.swift:408`）・history / userDict ソース確定は flag 無し → trim=false 固定。真の助詞ケースでも完成形行が育ち始める＝実質 D2 案 1（二重記録）の部分先行（行数増の観察は D2 の POC 観点へ）
- 文字列版 `trimTrailingParticle` は **廃止**（fallback にも使わない）

- [x] **POC ゲート**: 実辞書で `特に` / `主に` / `一緒に` / `今は` / `東京まで` のセグメント構成を確認（`ParticleTrimSegmentPOCTests`、2026-07-10 通過）。特に型は単一セグメント、東京までは多セグメント末尾 joshi。「今は」も単一見出しのため trim せず完成形が育つ
- [ ] `AzooKeyCandidate` に末尾セグメント joshi flag を追加し、`displayCandidates` で設定、CandidateContext 経由で `commitComposition` まで運ぶ
- [ ] `recordPrefixes` を「trim してよいか」を呼び出し側から受け取る形にし、`data.count >= 2` かつ末尾 joshi のときだけトリム。flag 無しはトリムしない
- [ ] `trimTrailingParticle` の文字列サフィックス判定を廃止
- [ ] 回帰テスト: 「特に」「主に」「さらに」等の副詞・「東京まで」等の真の助詞ケースを両方固定
- [ ] テストの置き場: slow=POC 固定、fast=スタブに joshi flag を足して供給

**期待効果**: 「とくに」型（副詞末尾がたまたま助詞文字）の pain が確定 2〜3 回後に row 0 直行へ変わる。`とく→特` は `LIKE 'とくに%'` にヒットせんので、完成形行が生えれば cleanup なしでも exact 到達は可能。
**検証指標**: 対象 reading の pain 件数・scroll_count、履歴 DB の完成形行の成長。objective_axis: UX-pain。
**既存 DB 掃除**: 壊れた行（`とく→特` 等）は D1 出荷の必須ゲートではない。`scripts/cleanup_history_db.py` 系で **dry-run → SELECT 確認 → 手動 apply** を別途 triage（自動書き換えしない）。中途打鍵「とく」で「特」が出る違和感の掃除用。

### D2. 文節完成形（内容語+助詞）の row 0 到達

「いまは→今は」は「は」が本物の助詞なので D1 では解決せん（トリム自体は意味論的に正しい）。それでもユーザーは 14 回 pain しとる。

**設計決定（grill）**: 本線候補は **二重記録**（`いま→今` と `いまは→今は`）を仮置き。着手は **D1 検証 window 後の個別 plan + 必要なら POC**。合成（explicit 時）は誤爆面が大きい。何もしないは 14 回 pain しても直ってないので観察継続なら優先を「観察」に落とす。

**D1 の副作用が部分先行になる点に注意**: D1 は「trim は azooKey 候補確定のみ」に絞るため、素の reading 確定や history ソース確定では真の助詞ケースでも完成形行が育ち始める。D2 の POC では、この自然増の行数・正のフィードバックの有無を先に観察してから二重記録の要否を判断する（D1 だけで「いまは」pain が減るなら D2 は縮小できる）。

選択肢（個別 plan で最終確定）:

1. トリム行と完成形行の**二重記録**（仮置き本線）
2. explicit 構築時に「内容語の高頻度履歴 + 末尾助詞」から**完成形候補を合成**して上位に出す
3. 何もしない（AzooKey の学習（`learningType: .inputAndOutput`）が拾うのを待つ）

- [ ] D1 検証後に個別 plan 化（二重記録の行数・正のフィードバック懸念を POC）
- [ ] 採用案の実装

**検証指標**: 「いまは」「〜との」等、助詞末尾 reading の pain 件数。objective_axis: UX-pain。

## 施策 E: prefix 習慣学習

### E1. 打鍵 prefix 単位の選択実績を whileTyping の並びに効かせる

**設計決定（grill）**:

- **本線は whileTyping 加点（本体）**。とりひ型の本命動線は「Space せず autoShow を見て Enter」
- **軽量代案（Space 後カーソル追尾）は本採用しない**。並びは exact 優先のまま初期選択だけ prefix に置くと、「Space＝今の入力の変換」という explicit 方針を初期選択で骨抜きにする。方針例外の短 POC も原則やらない（やるなら「方針例外実験」と明示し本採用判断を分離）
- 着手は **D1 検証 window 消化後**。記録キーは D1 適用後のきれいな reading を前提にする
- 正のフィードバック抑制（truncation commit ガード同類）は本体設計に必須

- [ ] 確定時に「実際に打鍵した reading（統合前）→ output」の選択実績を軽量に記録する（最長読み統合とは別枠。テーブル 1 個 or history 別カラム）
- [ ] `CandidateScoreBuilder` の **whileTyping 経路のみ**でこの実績をスコアに加点（explicit の exact 優先・prefix demote は不変）
- [ ] 正のフィードバック抑制を設計に含める（autoShow 誘導誤確定を実績に数えない条件）
- [ ] 回帰: `とりひ` 3 回選択 → 4 回目の autoShow row 0 が `取引先ユーザー` になるシナリオテスト

**期待効果**: とりひ/れびゅ/してき型の「Space→scroll」動線（計 66+ pain/14 日）が「autoShow を見て Enter」に変わる。使い込むほど自動で賢くなる方向性（手動登録なし）にも一致。
**検証指標**: 対象 reading の scroll_count・composition_ms・explicit 率。objective_axis: UX-pain。

## 施策 F: レイテンシ（観察・小粒）

### F1. 起動キャッシュウォームアップ

D/E 学習軸のあとに着手。2 文字読みミス 7833 件の一因はプロセス再起動（deploy 含む）ごとのキャッシュ全損。`fetchTopFrequentEntries` で頻出読みの先頭 1〜3 文字を起動アイドル時にプリフェッチして温める。

- [ ] ウォームアップ対象の選定ロジック（頻出 N 件 × prefix 長 1〜3）
- [ ] rich=true でプリフェッチ（peek のキャッシュキーが rich レーンのため。POC260704c で rich が軽いことも確認済み）
- [ ] 起動直後の LockedConverter 競合を避けるスケジューリング（初回打鍵とぶつけない）

**検証指標**: セッション頭の 2 文字ミス率・fetch_complete p50。objective_axis: latency。

### F2. 打鍵中の長読み Zenzai テール（観察枠）

`せんこうたいけ` 型の「破棄される長読み推論がロックを塞ぐ」連鎖は A2（inferenceLimit=2）後も残っとる。着手条件: pain 分析で lock_wait 起因の体感事故が再発したら。候補: 読み長 ≥6 の打鍵中（pause 未検知）は inferenceLimit=1、または fetch 開始前の generation 再チェック強化。**P-1（短読みスキップ）の轍**（読み長だけで途中/完成を判定しない）に注意。

## やらないこと（今回の計測・過去の判断で否定済み）

- **whileTyping rich=false 切替**: POC260704c で rich=true の方が速い（p50 -11%）と実測済み。現状維持
- **短読み AzooKey スキップ**: rejected P-1。2 文字完成語が死ぬ
- **explicit の並び替え**（prefix 候補を exact より上へ）: 確認済み方針に反する。E1 は whileTyping 限定
- **explicit リビルド時の prefix カーソル追尾（E1 軽量代案）**: 初期選択が exact 優先方針を骨抜きにする。本採用しない
- **D1 で助動詞レンジまでトリム**: 活用語尾を壊す。joshi のみ
- **セグメント無し時の文字列サフィックス fallback**: 誤爆穴が残る。トリムしない
- **commit 時の同期 lcid 取得**: 第 1 弾で追い出した同期 converter ロックの再発
- **Zenzai 精度そのものへの介入**: divergence の 72% は履歴/辞書が救済済み。真の損失 516 件の最頻パターン（`れびゅ` Z1=レビュ 23 件等）は打鍵途中 prefix の宿命で、D/E が吸収する見込み
- **typo 許容変換**（`ありとうございました` 素通り）: rejected E-2

## ロードマップ完了条件

- D1 出荷＋検証 window で「とくに」型の完成形行が育ち、対象 reading の pain/scroll が明確に減る
- E1 出荷＋検証でとりひ型の explicit 率・scroll が減り、whileTyping row 0 直行が増える
- D2 は個別 plan で採用/見送りを確定（仮置きは二重記録）
- F1 は D/E 後の余裕次第。F2 は着手条件未達なら観察のまま閉じる
