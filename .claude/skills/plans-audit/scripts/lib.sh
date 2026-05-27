#!/usr/bin/env bash
# plans-audit の共通ライブラリ。
# 各 audit ステップで重複していた frontmatter パースと status canonical 化を集約する。
#
# 使い方:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   field=$(extract_frontmatter_field "$plan_file" "status")
#   canonical=$(canonicalize_status "$markdown_status")

# YAML frontmatter（ファイル冒頭の `---` で囲まれたブロック）から指定キーの値を返す。
# キーが存在しなければ空文字を返す。
extract_frontmatter_field() {
  local file="$1"
  local field="$2"
  awk -v field="$field" '
    NR==1 && /^---$/ {in_fm=1; next}
    in_fm && /^---$/ {exit}
    in_fm && $0 ~ "^" field ":" {
      sub("^" field ":[[:space:]]*", "")
      print
      exit
    }
  ' "$file"
}

# 既存の markdown `**状態**:` 記法（legacy）から status 文字列を抽出。
# 該当行が無ければ空文字。
extract_markdown_status() {
  local file="$1"
  grep -E '^\*?\*?状態\*?\*?:' "$file" 2>/dev/null \
    | head -1 \
    | sed 's/^\*\*状態\*\*:[[:space:]]*//' \
    | sed 's/^状態:[[:space:]]*//'
}

# legacy 記法の status を canonical（draft / in-progress / implemented / abandoned / superseded）にマップ。
# マップできないものは "legacy: <元の文字列>" を返し、unknown とは区別する。
canonicalize_status() {
  local md_status="$1"
  case "$md_status" in
    オープン*|未着手*|検討中*) echo "draft (legacy)" ;;
    実装中*|進行中*|作業中*)   echo "in-progress (legacy)" ;;
    完了*|実装完了*|採用*|クローズ*|実装済み*) echo "implemented (legacy)" ;;
    失敗*|不採用*|破棄*|中断*) echo "abandoned (legacy)" ;;
    *)                          echo "legacy: $md_status" ;;
  esac
}

# plan ファイルから canonical status を取得する。
# 1. YAML frontmatter の status が最優先
# 2. なければ markdown の **状態**: を canonicalize
# 3. どちらもなければ "unknown"
get_plan_status() {
  local file="$1"
  local status
  status=$(extract_frontmatter_field "$file" "status")
  if [ -z "$status" ]; then
    local md_status
    md_status=$(extract_markdown_status "$file")
    if [ -n "$md_status" ]; then
      status=$(canonicalize_status "$md_status")
    fi
  fi
  [ -z "$status" ] && status="unknown"
  echo "$status"
}

# canonical status が「終端」状態（implemented / abandoned / superseded）かを判定。
# 0 を返せば終端、1 を返せば未終端。stale 検出のスキップ判定に使う。
is_terminal_status() {
  local status="$1"
  case "$status" in
    implemented|abandoned|superseded) return 0 ;;
    *"(legacy)"*)
      case "$status" in
        "implemented (legacy)"|"abandoned (legacy)") return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}
