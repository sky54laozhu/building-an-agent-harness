#!/usr/bin/env bash
# Usage: git-stats.sh <repo-path>
# Used by the series-wrap article (Part 19) to ground claims in real git data.
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

cd "$repo"

echo "=== total commits ==="
git log --oneline | wc -l | tr -d ' '

echo
echo "=== first commit date ==="
git log --reverse --pretty=format:'%ad' --date=short | head -1
echo
echo "=== last commit date ==="
git log --pretty=format:'%ad' --date=short | head -1

echo
echo "=== commits per day ==="
git log --pretty=format:'%ad' --date=short | sort | uniq -c

echo
echo "=== top 20 changed files ==="
git log --pretty=format: --name-only | grep -v '^$' | sort | uniq -c | sort -rn | head -20
