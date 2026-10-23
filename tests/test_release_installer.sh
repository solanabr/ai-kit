#!/usr/bin/env bash
set -euo pipefail

# Release assets (#278): .github/scripts/release-installer.sh stamps install.sh's
# RELEASE_REF to the tag and writes install.sh.sha256 over the stamped copy, and
# release-installer.yml attaches both to the release. Checked here: the pair verifies
# with both checksum tools, the stamped installer clones the tag it was stamped with
# (not the newest one), the repo copy still resolves the newest tag, and the workflow
# uploads both files under a narrow token.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

BUILD="$REPO_ROOT/.github/scripts/release-installer.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/release-installer.yml"
TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_release_installer] Release installer assets and their checksum"
echo ""

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
unset SOLANA_AI_KIT_BRANCH SOLANA_CLAUDE_BRANCH SOLANA_AI_KIT_UPSTREAM SOLANA_CLAUDE_UPSTREAM \
  SOLANA_AI_KIT_LOCAL_SRC SOLANA_CLAUDE_LOCAL_SRC 2>/dev/null || true

echo "[the repo copy]"
assert_eq 1 "$(grep -c '^RELEASE_REF=""$' "$REPO_ROOT/install.sh")" \
  "install.sh carries exactly one empty RELEASE_REF line for the stamp"
assert_file_contains "$REPO_ROOT/install.sh" 'BRANCH="${SOLANA_AI_KIT_BRANCH:-${SOLANA_CLAUDE_BRANCH:-$RELEASE_REF}}"' \
  "the env override wins over RELEASE_REF"

echo "[stamp and checksum]"
OUT="$TEMP_DIR/assets"
bash "$BUILD" v2.5.0 "$OUT" >/dev/null
assert_file_exists "$OUT/install.sh" "install.sh is built"
assert_file_exists "$OUT/install.sh.sha256" "install.sh.sha256 is built"
assert_file_contains "$OUT/install.sh" 'RELEASE_REF="v2.5.0"' "the asset is stamped with the tag"
assert_eq 0 "$(grep -c '^RELEASE_REF=""$' "$OUT/install.sh" || true)" "no unstamped RELEASE_REF line is left"
# One line differs from the source, so a reader can diff the asset against the tag.
assert_eq 1 "$(diff "$REPO_ROOT/install.sh" "$OUT/install.sh" | grep -c '^>' || true)" \
  "the asset differs from install.sh by exactly one line"
assert_eq "install.sh" "$(awk '{print $2}' "$OUT/install.sh.sha256")" \
  "the checksum file names install.sh, relative, as both -c tools expect"
assert_eq 64 "$(awk '{print length($1)}' "$OUT/install.sh.sha256")" "the checksum is a SHA-256 hex digest"
if command -v shasum >/dev/null 2>&1; then
  assert_cmd_success "cd '$OUT' && shasum -a 256 -c install.sh.sha256" "shasum -a 256 -c accepts it"
fi
if command -v sha256sum >/dev/null 2>&1; then
  assert_cmd_success "cd '$OUT' && sha256sum -c install.sh.sha256" "sha256sum -c accepts it"
fi
# Negative control: a one-byte change must fail the same check, or the passes above only
# show the tool ran.
cp -R "$OUT" "$TEMP_DIR/tampered"
printf '\n' >> "$TEMP_DIR/tampered/install.sh"
if command -v shasum >/dev/null 2>&1; then
  assert_cmd_fails "cd '$TEMP_DIR/tampered' && shasum -a 256 -c install.sh.sha256" "a tampered installer fails the check"
else
  assert_cmd_fails "cd '$TEMP_DIR/tampered' && sha256sum -c install.sh.sha256" "a tampered installer fails the check"
fi

echo "[refusals]"
assert_cmd_fails_with "bash '$BUILD' v2.5 '$TEMP_DIR/x'" "not a vX.Y.Z tag" "a non-release tag is refused"
assert_cmd_fails_with "bash '$BUILD' 'v2.5.0\";x' '$TEMP_DIR/x'" "not a vX.Y.Z tag" "a tag with shell characters is refused"
grep -v '^RELEASE_REF=' "$REPO_ROOT/install.sh" > "$TEMP_DIR/old-install.sh"
assert_cmd_fails_with "bash '$BUILD' v2.5.0 '$TEMP_DIR/x' '$TEMP_DIR/old-install.sh'" "expected one RELEASE_REF" \
  "an installer with no RELEASE_REF line (a pre-#278 tag) is refused, not shipped unpinned"

echo "[the ref each copy clones]"
UP="$TEMP_DIR/up"
mkdir -p "$UP"
echo fixture > "$UP/README.md"
(cd "$UP" && git init -q -b main && git add README.md && git commit -q --no-gpg-sign -m fixture \
  && git tag --no-sign v2.5.0 && git tag --no-sign v2.9.0)
# The fixture holds no kit, so the install stops after the clone; only the ref is read.
cloned() {
  local script="$1"; shift
  env "$@" bash "$script" "$TEMP_DIR/target-$RANDOM" 2>&1 \
    | sed -n 's/^▸ Cloning .* (\(.*\))\.\.\.$/\1/p' | head -1 || true
}
assert_eq v2.5.0 "$(cloned "$OUT/install.sh" SOLANA_AI_KIT_UPSTREAM="$UP")" \
  "the stamped installer clones its own tag, not the newest"
assert_eq v2.9.0 "$(cloned "$REPO_ROOT/install.sh" SOLANA_AI_KIT_UPSTREAM="$UP")" \
  "the repo installer still clones the newest tag"
assert_eq main "$(cloned "$OUT/install.sh" SOLANA_AI_KIT_UPSTREAM="$UP" SOLANA_AI_KIT_BRANCH=main)" \
  "SOLANA_AI_KIT_BRANCH overrides the stamp"

echo "[workflow]"
assert_file_contains "$WORKFLOW" 'tags: ["v[0-9]+.[0-9]+.[0-9]+"]' "runs on a pushed vX.Y.Z tag"
assert_file_contains "$WORKFLOW" "workflow_dispatch:" "can be run by hand to backfill a tag"
assert_file_contains "$WORKFLOW" 'release-installer.sh "$TAG" "$RUNNER_TEMP/assets" tag/install.sh' \
  "builds the assets with the default branch's script from the tag's install.sh"
assert_file_contains "$WORKFLOW" "path: tag" "the tag is checked out into a subdirectory, not the root"
assert_file_contains "$WORKFLOW" "github.event.repository.default_branch" "the root checkout is the default branch on a tag push"
assert_eq 2 "$(grep -c 'persist-credentials: false' "$WORKFLOW")" "neither checkout keeps a token on disk"
# The write token only on the steps that call gh, never job-wide where the build script
# would see it.
JOB_ENV="$(awk '/^    env:/ { on = 1; next } on && /^    [a-z]/ { exit } on' "$WORKFLOW")"
assert_contains "$JOB_ENV" "TAG:" "the job-level env block is read (control)"
assert_eq "" "$(printf '%s\n' "$JOB_ENV" | grep 'GH_TOKEN' || true)" "GH_TOKEN is not in the job-level env"
assert_eq 2 "$(grep -cE '^          GH_TOKEN: [$][{][{] github.token [}][}]$' "$WORKFLOW")" \
  "GH_TOKEN is set on the two gh steps alone"
assert_file_contains "$WORKFLOW" '"$RUNNER_TEMP/assets/install.sh" "$RUNNER_TEMP/assets/install.sh.sha256"' \
  "uploads both assets"
assert_file_contains "$WORKFLOW" "sha256sum -c install.sh.sha256" "verifies the published pair after upload"
# contents: write on the job alone; the workflow default stays read.
assert_eq "contents: read" "$(awk '/^permissions:/ { getline; sub(/^[[:space:]]+/, ""); print; exit }' "$WORKFLOW")" \
  "the workflow default token is read-only"
assert_eq 1 "$(grep -cE '^[[:space:]]+contents: write$' "$WORKFLOW")" "contents: write is granted once, to the job"

print_summary
