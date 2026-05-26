#!/usr/bin/env bash
# Usage: extract-code-snippet.sh <abs-src-path> <start-line> <end-line> <out-path>
#
# Pulls a line range out of a HarWork source file, sanitizes internal markers,
# wraps it in a fenced code block, and writes it to <out-path>.
#
# Sanitization rules:
#   1. Internal domains (harwork.io|com|cn)        -> example.com
#   2. /Users/<username>/                          -> /Users/USER/
#   3. Lines containing // TODO|FIXME|XXX|HACK     -> removed
#   4. (#1234) issue/PR refs                       -> removed
#
# Env vars:
#   HARWORK_ROOT  Absolute path to the HarWork repo root. Used only to compute
#                 the "from <relative-path>" comment. Defaults to the author's
#                 local checkout.
set -euo pipefail

if [ $# -ne 4 ]; then
  echo "Usage: $0 <abs-src-path> <start-line> <end-line> <out-path>" >&2
  exit 2
fi

src="$1"; start="$2"; end="$3"; out="$4"

if [ ! -f "$src" ]; then
  echo "Error: source file not found: $src" >&2
  exit 1
fi

HARWORK_ROOT="${HARWORK_ROOT:-/Users/weifengzhu/work/ai/HarWork}"

# Portable relative-path strip (BSD realpath has no --relative-to).
relpath="$src"
case "$src" in
  "$HARWORK_ROOT"/*) relpath="${src#"$HARWORK_ROOT"/}" ;;
esac

# Language hint for the fenced code block, picked from the file extension.
ext="${src##*.}"
case "$ext" in
  ts|tsx)     lang="ts" ;;
  js|jsx|mjs) lang="js" ;;
  py)         lang="python" ;;
  sh|bash)    lang="bash" ;;
  go)         lang="go" ;;
  rs)         lang="rust" ;;
  yml|yaml)   lang="yaml" ;;
  json)       lang="json" ;;
  md)         lang="markdown" ;;
  sql)        lang="sql" ;;
  *)          lang="" ;;
esac

mkdir -p "$(dirname "$out")"

{
  echo "<!-- from $relpath:L${start}-L${end} -->"
  echo '```'"$lang"
  sed -n "${start},${end}p" "$src" \
    | sed -E 's#harwork\.(io|com|cn)#example.com#g' \
    | sed -E 's#/Users/[A-Za-z0-9_-]+/#/Users/USER/#g' \
    | sed -E '/\/\/[[:space:]]*(TODO|FIXME|XXX|HACK)/d' \
    | sed -E 's|\(#[0-9]+\)||g'
  echo '```'
} > "$out"

echo "wrote $out ($(wc -l < "$out" | tr -d ' ') lines)"
