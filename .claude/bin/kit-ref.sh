#!/usr/bin/env bash
set -uo pipefail

# Print the kit ref /update should fetch: the latest release tag, the same one
# install.sh installs (#125). update.sh's own default is main, and that default sits in
# its byte-frozen first 93 lines, so the tag reaches it from outside, through the
# SOLANA_AI_KIT_BRANCH it already honours:
#
#   SOLANA_AI_KIT_BRANCH="$(bash .claude/bin/kit-ref.sh)" bash .claude/bin/update.sh
#
# An explicit SOLANA_AI_KIT_BRANCH (legacy SOLANA_CLAUDE_BRANCH) is printed unchanged.
# Otherwise: the highest vX.Y.Z tag on SOLANA_AI_KIT_UPSTREAM (legacy
# SOLANA_CLAUDE_UPSTREAM; default the kit repo) newer than TAG_FLOOR, else main.
# install.sh resolves its ref with the same rule, inline, since a curl | bash install has
# no kit on disk to call; tests/test_kit_ref.sh holds the two to the same answer.
#
# TAG_FLOOR: every release up to v2.4.0 ships an /update that fetches main. Landing an
# install on one of those would make its next /update fetch main again, and the one
# after that the tag, for as long as no newer tag exists. Above the floor, every tag
# carries this script. Never raise it: it marks where tag tracking began.
TAG_FLOOR="2.4.0"

if [ -n "${SOLANA_AI_KIT_BRANCH:-${SOLANA_CLAUDE_BRANCH:-}}" ]; then
  printf '%s\n' "${SOLANA_AI_KIT_BRANCH:-${SOLANA_CLAUDE_BRANCH:-}}"
  exit 0
fi

REPO_URL="${SOLANA_AI_KIT_UPSTREAM:-${SOLANA_CLAUDE_UPSTREAM:-https://github.com/solanabr/ai-kit.git}}"
TAG="$(git ls-remote --tags --refs "$REPO_URL" 'refs/tags/v*' 2>/dev/null \
  | awk -v floor="$TAG_FLOOR" '
      function newer(a, b,   x, y, i) {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) if (x[i] + 0 != y[i] + 0) return x[i] + 0 > y[i] + 0
        return 0
      }
      { t = $2; sub(/^refs\/tags\//, "", t) }
      t ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ && newer(substr(t, 2), floor) {
        if (best == "" || newer(substr(t, 2), substr(best, 2))) best = t
      }
      END { if (best != "") print best }')" || TAG=""
printf '%s\n' "${TAG:-main}"
