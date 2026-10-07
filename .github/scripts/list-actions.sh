#!/usr/bin/env bash
# Print every `uses:` reference in the workflow and template YAML under .github/, one per
# line as "<file>:<line> <ref>". With --resolve, check each remote action against the
# GitHub API (needs gh and GH_TOKEN) and exit 1 if any repo or ref does not exist.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

list() {
  find .github -type f \( -name '*.yml' -o -name '*.yaml' \) | sort | while read -r f; do
    awk -v f="$f" '
      /^[[:space:]]*(-[[:space:]]+)?uses:/ {
        v = $0
        sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/["\047]/, "", v)
        sub(/[[:space:]]+$/, "", v)
        print f ":" NR " " v
      }' "$f"
  done
}

if [ "${1:-}" != "--resolve" ]; then
  list
  exit 0
fi

fail=0
resolved=0
while read -r ref; do
  case "$ref" in ./*|docker://*) continue ;; esac
  repo="$(printf '%s' "$ref" | cut -d@ -f1 | cut -d/ -f1-2)"
  ver="${ref##*@}"
  resolved=$((resolved + 1))
  if gh api "repos/$repo/commits/$ver" --silent 2>/dev/null; then
    echo "ok       $ref"
  else
    echo "MISSING  $ref"
    fail=1
  fi
done < <(list | awk '{ print $2 }' | sort -u)
# `fail` starts at 0 and the loop body is the only thing that can raise it, so zero refs
# used to exit 0 — the ci.yml job "Every uses: under .github/ resolves" reporting green
# having resolved nothing. Anything that empties list() (a directory move, an extension
# change, a broken awk) is a silent loss of the whole check, so say so instead.
if [ "$resolved" -eq 0 ]; then
  echo "NONE     no remote action reference found under .github/ — nothing was resolved" >&2
  exit 1
fi
echo "resolved $resolved remote action reference(s)"
exit "$fail"
