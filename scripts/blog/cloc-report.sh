#!/usr/bin/env bash
# Usage: cloc-report.sh <repo-path>
# Output (stdout): JSON with TypeScript LOC for engine and web subtrees.
# Requires: cloc (brew install cloc), node.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <repo-path>" >&2
  exit 2
fi

repo="$1"

if [ ! -d "$repo/.git" ]; then
  echo "Error: not a git repo: $repo" >&2
  exit 1
fi

command -v cloc >/dev/null 2>&1 || {
  echo "Error: cloc is not installed. Install with: brew install cloc" >&2
  exit 127
}
command -v node >/dev/null 2>&1 || {
  echo "Error: node is not installed." >&2
  exit 127
}

cd "$repo"

tmp_dir="$(mktemp -d -t cloc-report.XXXXXX)"
tmp_engine="$tmp_dir/engine.json"
tmp_web="$tmp_dir/web.json"
trap 'rm -rf "$tmp_dir"' EXIT

cloc packages/engine/src --json > "$tmp_engine"
cloc packages/web/app packages/web/components packages/web/lib --json > "$tmp_web"

node -e '
const fs = require("fs");
const e = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const w = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const eTS = (e.TypeScript || {}).code || 0;
const wTS = (w.TypeScript || {}).code || 0;
console.log(JSON.stringify({ engine_ts: eTS, web_ts: wTS, total: eTS + wTS }, null, 2));
' "$tmp_engine" "$tmp_web"
