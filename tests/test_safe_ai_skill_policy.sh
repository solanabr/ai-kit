#!/usr/bin/env bash
set -euo pipefail

# The safe-ai-skill project policy (.safe-ai-skill/policy.yaml): shipped, installed
# once, never overwritten, added by /update when missing, and gitignored with the
# rest of the kit config.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

POLICY=".safe-ai-skill/policy.yaml"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_safe_ai_skill_policy] safe-ai-skill project policy"
echo ""

yaml_json() {  # yaml_json <file>: the YAML as JSON; status 2 when no YAML parser is installed
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$1"
  elif python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$1"
  else
    return 2
  fi
}
new_project() { mkdir -p "$TEMP_DIR/$1" && git -C "$TEMP_DIR/$1" init -q && echo "$TEMP_DIR/$1"; }
install_kit() { SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$@" >/dev/null 2>&1; }
update_kit() { (cd "$1" && shift && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh "$@" 2>&1); }
config_block() { sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$1/.gitignore"; }

echo "[template]"
assert_file_exists "$REPO_ROOT/$POLICY" "The kit ships $POLICY"
status=0
JSON="$(yaml_json "$REPO_ROOT/$POLICY")" || status=$?
if [ "$status" -eq 2 ]; then
  echo "  SKIP: no YAML parser (ruby or python3 with PyYAML) to parse $POLICY"
else
  assert_eq "0" "$status" "$POLICY parses as YAML"
  assert_eq "True" "$(printf '%s' "$JSON" | python3 -c 'import json, sys; print(json.load(sys.stdin) == {"supply_chain": {"verify_skills_dirs": [".claude/skills"]}})')" \
    "It sets only supply_chain.verify_skills_dirs, to [.claude/skills]"
fi
assert_file_not_contains "$REPO_ROOT/$POLICY" "verify_ext_submodules:" "verify_ext_submodules stays at its default (false would scan ext/ as one skill)"

echo "[install.sh]"
P1="$(new_project default)"
install_kit "$P1"
assert_file_exists "$P1/$POLICY" "install.sh writes $POLICY"
assert_eq "" "$(diff "$REPO_ROOT/$POLICY" "$P1/$POLICY" 2>&1 || true)" "...as a copy of the kit's template"
assert_contains "$(config_block "$P1")" ".safe-ai-skill/" "The gitignore config block lists .safe-ai-skill/"
printf 'supply_chain:\n  verify_skills_dirs: []\n' > "$P1/$POLICY"
install_kit "$P1"
assert_file_contains "$P1/$POLICY" "verify_skills_dirs: []" "Re-running install.sh keeps the project's own policy"
assert_eq "1" "$(config_block "$P1" | grep -cxF '.safe-ai-skill/')" "...and lists .safe-ai-skill/ once"

echo "[install.sh --agents]"
P2="$(new_project agents)"
install_kit --agents "$P2"
assert_file_not_exists "$P2/$POLICY" "--agents writes no policy (safe-ai-skill's hooks run in Claude Code only)"
assert_eq "" "$(config_block "$P2" | grep -xF '.safe-ai-skill/' || true)" "...and does not gitignore it"

echo "[gitignore backfill]"
P3="$(new_project backfill)"
printf '# >>> solana-ai-kit config — gitignored by default; run /commit-claude-config to version it >>>\n.gitmodules\n.claude/\nCLAUDE.md\n.mcp.json\n# <<< solana-ai-kit config <<<\n' > "$P3/.gitignore"
install_kit "$P3"
assert_contains "$(config_block "$P3")" ".safe-ai-skill/" "install.sh adds .safe-ai-skill/ to a config block written by an older install"

echo "[update.sh]"
P4="$(new_project update)"
install_kit "$P4"
rm -rf "$P4/.safe-ai-skill"
grep -vxF '.safe-ai-skill/' "$P4/.gitignore" > "$TEMP_DIR/gitignore" && cp "$TEMP_DIR/gitignore" "$P4/.gitignore"
DRY="$(update_kit "$P4" --dry-run)"
assert_contains "$DRY" "[would create] $POLICY" "update.sh --dry-run reports the missing policy"
assert_contains "$DRY" "[would update] .gitignore" "...and the gitignore entry it would add"
assert_file_not_exists "$P4/$POLICY" "...and writes nothing"
OUT="$(update_kit "$P4")"
assert_contains "$OUT" "[created] $POLICY" "update.sh adds the policy to an install that lacks it"
assert_eq "" "$(diff "$REPO_ROOT/$POLICY" "$P4/$POLICY" 2>&1 || true)" "...as a copy of the kit's template"
assert_contains "$(config_block "$P4")" ".safe-ai-skill/" "...and gitignores it with the kit config"
printf 'supply_chain:\n  verify_skills_dirs: []\n' > "$P4/$POLICY"
OUT="$(update_kit "$P4")"
assert_file_contains "$P4/$POLICY" "verify_skills_dirs: []" "update.sh keeps an existing policy"
assert_eq "" "$(printf '%s\n' "$OUT" | grep -F "$POLICY" || true)" "...and does not mention it"

print_summary
