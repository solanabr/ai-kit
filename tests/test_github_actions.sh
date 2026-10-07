#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

LIST="$REPO_ROOT/.github/scripts/list-actions.sh"
TEMPLATE="$REPO_ROOT/.github/templates/claude-code.yml"

echo "[test_github_actions] Every uses: under .github/ is well-formed and pinned"
echo ""

# Templates are not parsed by GitHub (they are copied into user projects), so nothing
# else notices when an action they name disappears. CI resolves each ref against the
# API (list-actions.sh --resolve); this offline check catches malformed or floating refs.
USES="$(bash "$LIST")"
assert_contains "$USES" ".github/templates/claude-code.yml" "the template's actions are listed"
assert_contains "$USES" ".github/workflows/ci.yml" "workflow actions are listed"

BAD="$(printf '%s\n' "$USES" | awk 'NF {
  ref = $2
  if (ref ~ /^\.\// || ref ~ /^docker:\/\/[^ ]+$/) next
  if (ref !~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(\/[A-Za-z0-9_.\/-]+)?@[A-Za-z0-9_.\/-]+$/) { print $1 " malformed: " ref; next }
  ver = ref; sub(/^[^@]*@/, "", ver)
  if (ver ~ /^(main|master|latest|HEAD|dev|develop|trunk)$/) print $1 " floating ref: " ref
}')"
assert_eq "" "$BAD" "every uses: is owner/repo[/path]@ref with a tag or SHA, not a branch"

# The workflows this repo runs must pin to a full commit SHA, not a version tag. A tag is
# mutable: whoever controls the action's repo can repoint v4 at any commit, and
# sync-skill-pins.yml runs with contents: write and pushes. Same rule validate.sh applies
# to .mcp.json's npx pins. Templates are out of scope -- they are copied into a user's
# project, and the pinning call there is theirs.
mutable_tags() {
  bash "$LIST" | awk -v dir="$1" '
    index($1, dir) != 1 { next }
    { ref = $2; sub(/^[^@]*@/, "", ref)
      if (ref !~ /^[0-9a-f]{40}$/) print $1 " " $2 }'
}
assert_eq "" "$(mutable_tags '.github/workflows/')" "every action in .github/workflows/ is pinned to a full commit SHA"

# Negative control: the same rule over a tree that does carry a tag must report it, or the
# pass above only means the awk matched nothing.
CONTROL_DIR="$(mktemp -d)"
mkdir -p "$CONTROL_DIR/.github/workflows" "$CONTROL_DIR/.github/scripts"
cp "$LIST" "$CONTROL_DIR/.github/scripts/list-actions.sh"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n' \
  > "$CONTROL_DIR/.github/workflows/planted.yml"
CONTROL="$(cd "$CONTROL_DIR" && LIST="$CONTROL_DIR/.github/scripts/list-actions.sh" \
  bash -c "$(declare -f mutable_tags); mutable_tags '.github/workflows/'")"
rm -rf "$CONTROL_DIR"
assert_contains "$CONTROL" "actions/checkout@v4" "the SHA-pin check reports a planted mutable tag"

# No workflow checks out submodules recursively. install.sh fetches the packs with
# `submodule update --init --depth 1` and never recurses on purpose (install.sh:150-155):
# a pack's own submodules are pinned by that pack's author and reviewed by nobody here,
# and update.sh prunes the registry's `vendored` paths after its copy. A recursive
# checkout hands CI a tree no install can produce. That divergence hid the macOS failure
# in #216 for two sessions, and under SOLANA_AI_KIT_LOCAL_SRC it would put nested
# third-party trees into the smoke test's own fixture project.
RECURSIVE="$(grep -rln 'submodules:[[:space:]]*recursive' "$REPO_ROOT/.github/workflows/" 2>/dev/null || true)"
assert_eq "" "$RECURSIVE" "no workflow checks out submodules recursively (install.sh does not, so CI must not)"

RC_DIR="$(mktemp -d)"
mkdir -p "$RC_DIR/workflows"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@%s\n        with:\n          submodules: recursive\n' \
  "$(printf '0%.0s' $(seq 40))" > "$RC_DIR/workflows/planted.yml"
RC_CONTROL="$(grep -rln 'submodules:[[:space:]]*recursive' "$RC_DIR/workflows/" 2>/dev/null || true)"
rm -rf "$RC_DIR"
assert_contains "$RC_CONTROL" "planted.yml" "the recursive-checkout check reports a planted workflow"

# Every file parses as YAML (an unquoted "name: a: b" breaks a workflow silently).
# Ruby ships on macOS and the GitHub runners; skip where it is missing.
if command -v ruby >/dev/null 2>&1; then
  YAML_ERR="$(cd "$REPO_ROOT" && find .github -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 \
    | xargs -0 ruby -ryaml -e 'ARGV.each { |f| begin; YAML.load_file(f); rescue Exception => e; puts "#{f}: #{e.message}"; end }')"
  assert_eq "" "$YAML_ERR" "every YAML file under .github/ parses"
fi

# The dead action from issue #114 and a hardcoded toolchain must not come back
assert_file_not_contains "$TEMPLATE" "setup-solana" "template does not use the removed setup-solana action"
assert_file_not_contains "$TEMPLATE" "solana-version:" "template does not hardcode a Solana version"
assert_file_contains "$TEMPLATE" "release.anza.xyz" "template installs Agave from release.anza.xyz"
assert_file_contains "$TEMPLATE" "Anchor.toml" "template reads toolchain versions from Anchor.toml"
assert_file_contains "$TEMPLATE" "rust-toolchain" "template honours rust-toolchain.toml"
assert_file_contains "$REPO_ROOT/.github/workflows/ci.yml" "list-actions.sh --resolve" "CI resolves every action against the GitHub API"

# The template's version reader, run on a sample Anchor.toml
READER="$(awk '/toolchain_value\(\) \{/,/^          \}$/' "$TEMPLATE" | sed 's/^          //')"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
cat > "$TEMP_DIR/Anchor.toml" <<'EOF'
[toolchain]
anchor_version = "1.0.2"   # pinned
solana_version = '3.1.10'

[features]
solana_version = "9.9.9"
EOF
GOT="$(cd "$TEMP_DIR" && bash -c "$READER"$'\n''echo "$(toolchain_value solana_version) $(toolchain_value anchor_version)"')"
assert_eq "3.1.10 1.0.2" "$GOT" "template reads solana_version and anchor_version from [toolchain] only"

print_summary
