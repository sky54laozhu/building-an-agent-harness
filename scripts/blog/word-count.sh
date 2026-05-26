#!/usr/bin/env bash
# Usage: word-count.sh <markdown-file>
# Output: zh_chars=NNNN en_words=NNNN
#
# Counts CJK ideographs and ASCII-word tokens in a markdown file.
# Uses python3 for the CJK range because BSD grep on macOS does not
# accept \x{...} in -E mode, and -P is not portable.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <markdown-file>" >&2
  exit 2
fi

file="$1"

if [ ! -f "$file" ]; then
  echo "Error: file not found: $file" >&2
  exit 1
fi

zh=$(python3 - "$file" <<'PY'
import re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    text = f.read()
print(len(re.findall(r'[一-龥]', text)))
PY
)

en=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^[A-Za-z]+/) c++} END {print c+0}' "$file")

echo "zh_chars=$zh en_words=$en"
