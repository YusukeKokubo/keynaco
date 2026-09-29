---
status: in-progress
created: 2026-09-29
objective_axis: UX-pain
baseline_at: 2026-09-29T14:08:35
baseline_window: 7d
sample_threshold:
  sessions: 200
  confirmations: 1000
  loan_signal_confirmations: 60
deployed_at: 2026-09-29T16:16:08   # after 計測の起点（JST）。7d window は 2026-10-06T16:16 以降に取る
---

# PLAN260929: 外来語シグナルを含む未知語で、ひらがな生表記を row 0 に出さない

## 1. 目的軸

UX pain 削減。外来語らしい読みを打ったとき、row 0 にひらがなのままの表記が出て、Tab・↓・BS で直す手間を減らす。

## 2. ベースライン数値

計測は 2026-09-29 14:08（JST）、window は直近 7 日。生出力は `/tmp/perf-cycle-PLAN260929-baseline.txt` に残した。

ここでいう「外来語シグナル」は、読みに長音「ー」か、外来語にしか出ない拗音（ふぁ行・てぃ・でぃ・うぃ・うぇ・うぉ・ゔ・ちぇ・しぇ・じぇ・つぁ行など）を含むこと。pain は input_log で `bs_count ≥ 2`、`scroll_count > 0`、`composition_ms > 3000` のどれかに当たる確定を指す。

| 指標 | 全確定 | 外来語シグナル読み |
|---|---|---|
| 確定数 | 1817 | 80 |
| pain 件数（率） | 151（8.3%） | 15（18.8%） |
| scroll > 0 | 83 | 9 |
| BS ≥ 2 | 29 | 4 |
| composition_ms > 3000 | 73 | 11 |
| explicit 確定率 | 6.1% | 12.5% |
| composition_ms p50 / p95 | 1043 / 2732 | 1182 / 3785 |
| カタカナのみで確定 | 146 | 75 |
| ひらがなのみで確定 | 852 | 2（「わーっと」「ー」） |

参考として、latency_log は 464 セッション、1 位確定率は平均 91.5%。

## 3. 仮説

**観測**: 外来語シグナル読みは 94%（75/80）がカタカナで確定されとるのに、pain 率は他の読みの 2.4 倍ある。divergence_log の救済なし 38 件では、「わーくふぉるだ」「そにっくがーでん」のように AzooKey が rank 0 でひらがなの生表記を返し、カタカナが rank 1 にある型が繰り返し出とる。sandbox（ビルド 854）でも確かめた。「わーくふぉるだ」「そにっくがーでん」「らんでぃんぐぺーじ」「ほーむさーばー」「ぴーぷるまねじめんと」は、打鍵中も Space 後もひらがなが row 0 だった。一方で AzooKey が知っとる語（リアリティー・マネージャー・フード）は、はじめからカタカナが row 0 に来る。

**仮説**: 辞書にない外来語に対して AzooKey/Zenzai は、読みのひらがなをそのまま rank 0 に置く。keynaco はその順位をスコアにそのまま写しとるで、ひらがなが row 0 になる。

**予測**: 外来語シグナル読みの pain 率は 18.8% から 10% 以下、explicit 確定率は 12.5% から 6% 前後（全体並み）まで下がる。全体の pain 率は、分母に占める割合が小さいで 8.3% から 7.8〜8.0% 程度しか動かん見込み。

**副次効果の予想**: 「わーっと」「すげー」のように、ひらがなで確定したい長音入りの語は row 0 がカタカナに変わる。ベースラインではこの型は 80 件中 2 件だけだったで、悪化しても pain は +2 件程度に収まると見とる。レイテンシへの影響はない（スコアを入れ替えるだけ）。

## 4. 構造的か可変か

可変と判定する。AzooKey が返す候補集合（ひらがなもカタカナも両方入っとる）は動かさず、keynaco 側での並べ方を変えるだけで済むでだ。「未知語だと AzooKey がひらがなを rank 0 に置く」こと自体はエンジンの挙動で動かせんけど、今回はそこを狙わん。

## 5. 実装方針

`CandidateScoreBuilder.build` で、読みに外来語シグナルがあるとき、次の条件を全部満たしたら両者のスコアを入れ替える。

- `azooKey` 由来の候補にひらがな生表記（テキストが読みと一致）があり、それより下位に、読みを丸ごとカタカナにした候補がある
- その 2 つがどちらも履歴・ユーザー辞書由来でない（ユーザーが過去にひらがなで確定した語は触らん）

漢字候補や履歴候補の順位には手を入れん。候補を新しく作ることもせん。rejected.md P-4（カタカナ末尾固定）の「AzooKey の出力を素直に信頼する」は候補集合については守り、今回変えるのは並び方だけにする。retrospectives の「広い述語は該当候補を列挙してから判断」に従って、述語は「ひらがな生表記とカタカナ全表記の 1 組」に絞る。

テストは fast テストに追加する。外来語シグナルがあるときの入れ替え、長音だけの読み（すげー）でも入れ替わること、履歴にひらがながあれば入れ替えんこと、シグナルなしでは何もせんこと、の 4 本。

## 実装メモ

`CandidateScoreBuilder.promoteKatakanaOverRawHiragana` と `KanaUtils.hasLoanwordSignal` を追加し、fast テストを 6 本足した。デプロイ後の sandbox（ビルド 856）で、「わーくふぉるだ」「そにっくがーでん」「らんでぃんぐぺーじ」「ほーむさーばー」「ぴーぷるまねじめんと」は、打鍵中も Space 後も row 0 がカタカナになった。既知語（リアリティー・マネージャー・フード）と、シグナルのない読み（かっこいい・こんにちは）の並びは変わらんかった。予想どおりの副作用として、「わーっと」「すげー」は row 0 がカタカナになった。

## 6. 検証ゲート

- サンプル閾値: セッション数 ≥ 200、確定数 ≥ 1000、外来語シグナル読みの確定数 ≥ 60
- 計測 window: ベースラインと同じ 7d（デプロイから 7 日たってから計測する）
- 比較対象指標: 外来語シグナル読みの pain 率・explicit 確定率・ひらがな確定件数、全体の pain 率
- 計測方法: `analyze.py --since 7d` と `pain_analysis.py --since 7d`。外来語シグナル読みの集計には、下の同一スクリプトを使う

サンプルが足りんうちは `status: in-progress` のまま置いとく。`status: implemented` を付けるのはゲートを通ってからにする。

```python
# 外来語シグナル読みの集計（baseline / after 共通。引数は日数）
import json,time,re,sys
days=float(sys.argv[1]) if len(sys.argv)>1 else 7
since=(time.time()-days*86400)*1000
P="/Users/yusukekokubo/Library/Application Support/keynaco/"
rows=[json.loads(l) for l in open(P+"input_log.jsonl") if l.strip()]
rows=[r for r in rows if r["ts"]>=since]
LOAN=re.compile(r'ー|ふぁ|ふぃ|ふぇ|ふぉ|てぃ|でぃ|とぅ|どぅ|うぃ|うぇ|うぉ|ゔ|ちぇ|しぇ|じぇ|つぁ|つぃ|つぇ|つぉ|くぁ|ぐぁ|てゅ|でゅ|ふゅ')
def pain(r): return r.get("bs_count",0)>=2 or r.get("scroll_count",0)>0 or r["composition_ms"]>3000
def stats(name,g):
    n=len(g); ms=sorted(r["composition_ms"] for r in g)
    kata=sum(1 for r in g if r.get("committed") and re.fullmatch(r'[ァ-ヺー・]+',r["committed"]))
    hira=sum(1 for r in g if r.get("committed") and re.fullmatch(r'[ぁ-ゖー]+',r["committed"]))
    print(f"[{name}] n={n} pain={sum(map(pain,g))} ({sum(map(pain,g))/n:.1%}) "
          f"scroll>0={sum(r.get('scroll_count',0)>0 for r in g)} bs>=2={sum(r.get('bs_count',0)>=2 for r in g)} "
          f"ms>3000={sum(r['composition_ms']>3000 for r in g)} explicit={sum(r['was_explicit'] for r in g)} ({sum(r['was_explicit'] for r in g)/n:.1%}) "
          f"ms_p50={ms[n//2]} ms_p95={ms[int(n*.95)]} committed_kata={kata} committed_hira={hira}")
L=[r for r in rows if LOAN.search(r["reading"])]
stats("all",rows); stats("loan-signal",L)
print("loan-signal committed hiragana:",[(r["reading"],r.get("committed")) for r in L if r.get("committed") and re.fullmatch(r'[ぁ-ゖー]+',r["committed"])])
```

## 計測中に気づいた別件（このサイクルの範囲外）

- scroll > 0 の 83 件の過半は、「ありがとう」+Tab で「ありがとうございました」のように、履歴の補完語を 1 行下りて取った確定だった。打鍵が減った成功例だで、pain 指標から外すかどうかは別途判断する（指標の定義を今のサイクル中に変えると、before/after の対称性が崩れる）。
- 自動表示中の候補で Tab・↓ を押すと、一覧は whileTyping の並び（prefix 候補が exact より上）のまま explicit 扱いになる。Space の作り直しで入る exact 優先が効かん経路で、「いって」で「言ってる」が「行って」より上に残った例がある。
