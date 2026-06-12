#!/usr/bin/env bash
# One-off migration helper (2026-06-12): rename plans/*.md to include slug suffix.
# Convention: PLANYYMMDD[-letter]-<slug>.md — see plans-audit/references/plan-frontmatter.md
#
# Usage (if new legacy-named plans appear):
#   1. Append old|new basename pairs to MAP below
#   2. ./scripts/rename_plans_with_slugs.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MAP_FILE="${1:-}"

if [ -n "$MAP_FILE" ] && [ -f "$MAP_FILE" ]; then
  MAP=$(cat "$MAP_FILE")
else
  echo "No map file given and built-in map is empty (migration already applied)." >&2
  echo "Pass a 'old_basename|new_basename' map file to rename additional plans." >&2
  exit 1
fi

echo "=== git mv ==="
while IFS='|' read -r old new; do
  [ -z "$old" ] && continue
  src="plans/${old}.md"
  dst="plans/${new}.md"
  [ -f "$src" ] || { echo "skip (missing): $src"; continue; }
  [ -f "$dst" ] && { echo "skip (exists): $dst"; continue; }
  git mv "$src" "$dst"
  echo "  $old.md -> $new.md"
done <<< "$MAP"

echo "=== update references ==="
python3 - "$MAP_FILE" << 'PY'
import os, sys
map_path = sys.argv[1]
replacements = []
with open(map_path) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        old, new = line.split('|')
        replacements.append((f"{old}.md", f"{new}.md"))
replacements.sort(key=lambda x: len(x[0]), reverse=True)
SKIP = {'.git', 'LocalPackages', 'node_modules', '.build', '.swiftpm'}
EXTS = {'.md', '.swift', '.sh', '.txt'}
n = 0
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith('.')]
    for name in files:
        if os.path.splitext(name)[1] not in EXTS:
            continue
        path = os.path.join(root, name)
        try:
            with open(path, encoding='utf-8') as fh:
                c = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        orig = c
        for old, new in replacements:
            c = c.replace(old, new)
        if c != orig:
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(c)
            n += 1
            print(path)
print(f"updated {n} files")
PY

echo "done"
