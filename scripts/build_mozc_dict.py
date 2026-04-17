import sqlite3, glob, os, sys

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

rows = []
for path in sorted(glob.glob(os.path.join(MOZC_DIR, "dictionary*.txt"))):
    with open(path, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 5:
                continue
            reading, cost, surface = cols[0], cols[3], cols[4]
            if not all(0x3040 <= ord(c) <= 0x30FF or c == "ー" for c in reading):
                continue
            if reading == surface:
                continue
            cost_int = int(cost)
            if cost_int >= 8000:
                continue
            rows.append((reading, surface, cost_int))

conn.executemany("INSERT OR IGNORE INTO dictionary VALUES (?, ?, ?)", rows)
conn.commit()
conn.close()

size_mb = os.path.getsize(OUT) / 1024 / 1024
print(f"Inserted {len(rows)} entries")
print(f"Output: {OUT} ({size_mb:.1f} MB)")
