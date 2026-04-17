import sqlite3, glob, os

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOZC_DIR = os.path.join(BASE, "..", "mozc-src", "src", "data", "dictionary_oss")
OUT = os.path.join(BASE, "Resources", "mozc-dict.sqlite")

if os.path.exists(OUT):
    os.remove(OUT)

conn = sqlite3.connect(OUT)
conn.execute("""
    CREATE TABLE dictionary (
        reading   TEXT NOT NULL,
        candidate TEXT NOT NULL,
        priority  INTEGER NOT NULL,
        UNIQUE(reading, candidate)
    )
""")
conn.execute("CREATE INDEX idx_reading ON dictionary(reading)")

# ---- 活用形展開テーブル ----
# right_id で動詞クラスを判定する

ICHIDAN_IDS = {680, 681, 682, 683, 684, 685, 686, 713, 719}

# 五段: right_id → (te_suffix, ta_suffix, nai_stem_end)
GODAN_FIXED = {
    723: ("いて", "いた", "か"),   # 五段・カ行イ音便: く
    731: ("って", "った", "か"),   # 五段・カ行促音便: く (行く)
    739: ("って", "った", "か"),   # 五段・カ行促音便ユク: く (ゆく)
    763: ("って", "った", "ら"),   # 五段・ラ行: る
    764: ("って", "った", "ら"),
    765: ("って", "った", "ら"),
    766: ("って", "った", "ら"),
    791: ("って", "った", "ら"),   # 五段・ラ行特殊
    813: ("って", "った", "わ"),   # 五段・ワ行促音便: う
    814: ("って", "った", "わ"),
    815: ("って", "った", "わ"),
    816: ("って", "った", "わ"),
}

# 五段動詞 generic (ID 837): 語尾 → (te, ta, nai_stem_end)
GODAN_GENERIC_ID = 837
GODAN_END_TABLE = {
    "く": ("いて", "いた", "か"),
    "ぐ": ("いで", "いだ", "が"),
    "す": ("して", "した", "さ"),
    "つ": ("って", "った", "た"),
    "ぬ": ("んで", "んだ", "な"),
    "ぶ": ("んで", "んだ", "ば"),
    "む": ("んで", "んだ", "ま"),
    "る": ("って", "った", "ら"),
    "う": ("って", "った", "わ"),
}

SURU_IDS = {621, 633}  # サ変

DELTA = 500  # 派生形のコスト加算


def inflect(reading, surface, right_id_int, base_cost):
    cost = base_cost + DELTA
    results = []

    if right_id_int in ICHIDAN_IDS:
        if reading.endswith("る") and surface.endswith("る"):
            r, s = reading[:-1], surface[:-1]
            for rs, ss in [("て", "て"), ("た", "た"), ("ない", "ない")]:
                results.append((r + rs, s + ss, cost))

    elif right_id_int in GODAN_FIXED:
        te, ta, nai = GODAN_FIXED[right_id_int]
        r, s = reading[:-1], surface[:-1]
        results += [(r + te, s + te, cost), (r + ta, s + ta, cost),
                    (r + nai + "ない", s + nai + "ない", cost)]

    elif right_id_int == GODAN_GENERIC_ID:
        end = reading[-1] if reading else ""
        if end in GODAN_END_TABLE:
            te, ta, nai = GODAN_END_TABLE[end]
            r, s = reading[:-1], surface[:-1]
            results += [(r + te, s + te, cost), (r + ta, s + ta, cost),
                        (r + nai + "ない", s + nai + "ない", cost)]

    elif right_id_int in SURU_IDS:
        if reading.endswith("する") and surface.endswith("する"):
            r, s = reading[:-2], surface[:-2]
            results += [(r + "して", s + "して", cost),
                        (r + "した", s + "した", cost),
                        (r + "しない", s + "しない", cost)]

    return [(r, s, c) for r, s, c in results if r != s]


# ---- エントリ収集 ----
base_rows = []
derived_rows = []

for path in sorted(glob.glob(os.path.join(MOZC_DIR, "dictionary*.txt"))):
    with open(path, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 5:
                continue
            reading, right_id, cost_str, surface = cols[0], cols[2], cols[3], cols[4]
            if not all(0x3040 <= ord(c) <= 0x30FF or c == "ー" for c in reading):
                continue
            if reading == surface:
                continue
            cost_int = int(cost_str)
            if cost_int >= 8000:
                continue
            base_rows.append((reading, surface, cost_int))
            derived_rows.extend(inflect(reading, surface, int(right_id), cost_int))

conn.executemany("INSERT OR IGNORE INTO dictionary VALUES (?, ?, ?)", base_rows)
conn.executemany("INSERT OR IGNORE INTO dictionary VALUES (?, ?, ?)", derived_rows)
conn.commit()

total = conn.execute("SELECT COUNT(*) FROM dictionary").fetchone()[0]
conn.close()

size_mb = os.path.getsize(OUT) / 1024 / 1024
print(f"Base entries:    {len(base_rows):,}")
print(f"Derived entries: {len(derived_rows):,}")
print(f"DB total:        {total:,} (after dedup)")
print(f"Output: {OUT} ({size_mb:.1f} MB)")
