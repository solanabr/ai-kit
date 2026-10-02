#!/usr/bin/env bash
# Summarise what a submodule pin bump pulls in, for a human reviewer.
# Usage: submodule-bump-review.sh <base-sha> <head-sha>   (run from the superproject root)
# For every gitlink that changed between the two commits it fetches the old and new pack
# commits and flags the risk classes in issue #99: hooks, scripts and executables, new
# network hosts, pipe-to-shell installers and install hooks, new credential names, and
# licence changes. Prints Markdown on stdout; exits 0 (the review is informational).
set -uo pipefail

BASE="${1:?base sha}"
HEAD="${2:?head sha}"
# Diff from the merge-base, not the base branch tip: a pin main moved after the PR branched
# would otherwise show up as a bump back to the PR's older pin, reviewed in reverse.
BASE="$(git merge-base "$BASE" "$HEAD" 2>/dev/null || echo "$BASE")"

HOST_RE='https?://[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
PIPE_RE='(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh([^A-Za-z]|$)|"(pre|post)?install"[[:space:]]*:'
CRED_RE='[A-Z][A-Z0-9_]*(API_KEY|SECRET|TOKEN|PRIVATE_KEY|PASSWORD|_PAT)([^A-Za-z0-9_]|$)'
# grep -o keeps the one-character boundary some patterns end with; drop it
trim() { sed -E 's/[^A-Za-z0-9_]$//'; }

# Values matched in added lines that never appear anywhere in the old tree.
new_values() { # <repo> <old> <new> <regex>
  local before after
  before="$(git -C "$1" grep -hoIE "$4" "$2" -- . 2>/dev/null | sed -E "s/^[0-9a-f]{40}://" | trim | sort -u)"
  after="$(git -C "$1" diff -U0 --no-color "$2" "$3" | grep -E '^\+[^+]' | grep -oE "$4" | trim | sort -u)"
  comm -13 <(printf '%s\n' "$before" | awk 'NF') <(printf '%s\n' "$after" | awk 'NF')
}

bullet_list() { awk 'NF { printf "  - `%s`\n", $0 }' | head -40; }

echo "## Submodule bump review"
echo ""
echo "Read each flagged item before merging. Submodule bumps are merged by a person, not auto-merged."
echo ""

bumps="$(git diff --raw --no-abbrev "$BASE" "$HEAD" | awk '$1 ~ /^:160000/ && $2 == "160000" { print $6, $3, $4 }')"
if [ -z "$bumps" ]; then
  echo "No submodule pins changed."
  exit 0
fi

flagged=0
while read -r path old new; do
  [ -n "$path" ] || continue
  url="$(git config -f .gitmodules --get "submodule.$path.url" || true)"
  echo "### \`$path\`"
  echo ""
  echo "${url:-unknown url}: \`${old:0:12}\` → \`${new:0:12}\`"
  echo ""
  if [ ! -e "$path/.git" ] && [ ! -d "$path/.git" ]; then
    git submodule update --init --depth 1 -- "$path" >/dev/null 2>&1 || true
  fi
  if ! git -C "$path" fetch -q --depth 1 origin "$old" "$new" 2>/dev/null; then
    echo "- :warning: could not fetch both commits; review the upstream compare view by hand."
    echo ""
    flagged=1
    continue
  fi
  raw="$(git -C "$path" diff --raw --no-abbrev "$old" "$new")"
  echo "$(git -C "$path" diff --shortstat "$old" "$new" | sed 's/^ *//')"
  echo ""

  hooks="$(printf '%s\n' "$raw" | awk -F'\t' '$1 !~ / D$/ && ($2 ~ /(^|\/)hooks(\/|\.json$)/ || $2 ~ /(^|\/)hooks\.json$/) { print $2 }')"
  scripts="$(printf '%s\n' "$raw" | awk -F'\t' '$1 !~ / D$/ && $2 ~ /(^|\/)(scripts|bin)\// { print $2 }')"
  execs="$(printf '%s\n' "$raw" | awk -F'\t' '{ split($1, m, " "); if (m[2] == "100755" && m[1] != ":100755") print $2 }')"
  licences="$(printf '%s\n' "$raw" | awk -F'\t' 'toupper($2) ~ /(^|\/)(LICEN[CS]E|COPYING)[^\/]*$/ { print $2 }')"
  hosts="$(new_values "$path" "$old" "$new" "$HOST_RE")"
  pipes="$(git -C "$path" diff -U0 --no-color "$old" "$new" | grep -E '^\+[^+]' | grep -oE "$PIPE_RE" | trim | sort -u)"
  creds="$(new_values "$path" "$old" "$new" "$CRED_RE")"

  any=0
  report() { # <label> <values>
    if [ -n "$2" ]; then
      any=1
      echo "- :warning: **$1** ($(printf '%s\n' "$2" | awk 'NF' | wc -l | tr -d ' '))"
      printf '%s\n' "$2" | bullet_list
    fi
  }
  report "Hooks added or changed" "$hooks"
  report "scripts/ or bin/ files added or changed" "$scripts"
  report "Files that became executable" "$execs"
  report "New network hosts" "$hosts"
  report "Pipe-to-shell installers or install hooks in added lines" "$pipes"
  report "New credential names" "$creds"
  report "Licence files changed" "$licences"
  if [ "$any" -eq 0 ]; then
    echo "- No risk classes flagged."
  else
    flagged=1
  fi
  echo ""
done <<< "$bumps"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "flagged=$flagged" >> "$GITHUB_OUTPUT"
fi
exit 0
