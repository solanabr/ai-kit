#!/usr/bin/env bash
# Build the installer assets a GitHub release carries (#278): install.sh with its
# RELEASE_REF line stamped to the release tag, and install.sh.sha256 over that stamped
# file, in the "<hex>  install.sh" form both `shasum -a 256 -c` and `sha256sum -c` read.
#
#   bash .github/scripts/release-installer.sh <vX.Y.Z> <out-dir> [<install.sh>]
#
# The stamp is what makes a verified download install the release it came from rather
# than whatever tag is newest when it runs. It is the only byte that differs from
# install.sh at the tag, so `diff <(git show vX.Y.Z:install.sh) install.sh` shows one line.
set -euo pipefail

TAG="${1:-}"
OUT="${2:-}"
SRC="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/install.sh}"

if [ -z "$TAG" ] || [ -z "$OUT" ]; then
  echo "usage: $0 <vX.Y.Z> <out-dir> [<install.sh>]" >&2
  exit 64
fi
# Only a release tag: it lands inside a double-quoted shell assignment, and install.sh
# passes it to `git clone --branch`.
if ! printf '%s' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "not a vX.Y.Z tag: $TAG" >&2
  exit 1
fi
[ -f "$SRC" ] || { echo "no installer at $SRC" >&2; exit 1; }

# Exactly one unstamped line, or the stamp would miss (an installer from before #278, or a
# renamed variable) and the asset would silently fall back to the latest tag.
n="$(grep -c '^RELEASE_REF=""$' "$SRC" || true)"
if [ "$n" != 1 ]; then
  echo "expected one RELEASE_REF=\"\" line in $SRC, found $n" >&2
  exit 1
fi

mkdir -p "$OUT"
awk -v tag="$TAG" '$0 == "RELEASE_REF=\"\"" { print "RELEASE_REF=\"" tag "\""; next } { print }' \
  "$SRC" > "$OUT/install.sh"
chmod 755 "$OUT/install.sh"
bash -n "$OUT/install.sh"
grep -qx "RELEASE_REF=\"$TAG\"" "$OUT/install.sh" || { echo "stamp did not land" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  sum() { sha256sum "$@"; }
else
  sum() { shasum -a 256 "$@"; }
fi
# Relative name inside the file: the user verifies next to the downloaded copy.
(cd "$OUT" && sum install.sh > install.sh.sha256 && sum -c install.sh.sha256 >/dev/null)
cat "$OUT/install.sh.sha256"
