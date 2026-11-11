#!/usr/bin/env bash
set -euo pipefail

# The safe-ai-skill project policy (.safe-ai-skill/policy.yaml): shipped, installed
# once, added by /update when missing and refreshed while it is an unedited copy, never
# written through a link, and gitignored with the rest of the kit config.

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
install_kit() { SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$@" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh $*"; }
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
  assert_eq "True" "$(printf '%s' "$JSON" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(sorted(d) == ["secrets", "supply_chain"] and d["supply_chain"] == {"exec_install_scripts": "deny"} and sorted(d["secrets"]) == ["deny_read_globs"])')" \
    "It sets only supply_chain.exec_install_scripts, to deny, and secrets.deny_read_globs"
  # A project list replaces the default's. safe-ai-skill keeps a default the project
  # leaves out, and says so at every session start, so the two defaults come first.
  DENY="$(printf '%s' "$JSON" | python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin)["secrets"]["deny_read_globs"]))')"
  assert_eq "$(printf '%s\n' '**/*-keypair.json' '~/.superstack/config.json')" "$(printf '%s\n' "$DENY" | head -2)" \
    "secrets.deny_read_globs starts with safe-ai-skill's two defaults"
  for glob in '~/.bash_history' '~/.zsh_history' '~/.ssh/**' '**/*.kdbx' '**/*.ppk' '**/*.p12'; do
    assert_contains "$DENY" "$glob" "...and denies $glob, which secrets-guard denies and safe-ai-skill's defaults do not"
  done
  assert_eq "" "$(printf '%s\n' "$DENY" | grep -F '.asc' || true)" "No deny glob names .asc, which AsciiDoc files and detached signatures use too"
  # An allow list here would replace the default one, which lets the agent read every env
  # template (.env.example, .env.sample, .env.template, .env.dist, .env.schema).
  assert_eq "" "$(printf '%s\n' "$DENY" | grep -F '.env' || true)" "No deny glob names an env file: safe-ai-skill's env classes cover those"
fi
assert_file_not_contains "$REPO_ROOT/$POLICY" "allow_read_globs:" "It sets no secrets.allow_read_globs, so the default list of env templates applies"
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
assert_file_contains "$P4/$POLICY" "verify_skills_dirs: []" "update.sh keeps an edited policy"
assert_contains "$OUT" "[notice] $POLICY was edited, so it was kept" "...and says so"
assert_contains "$OUT" "lacks the kit's supply_chain.exec_install_scripts: deny or its secrets.deny_read_globs" "...naming the kit settings it lacks"
assert_eq "" "$(printf '%s\n' "$OUT" | grep -F '.env.schema' || true)" "...and no .env.schema notice: without an allow list, the default one applies"
printf 'supply_chain:\n  exec_install_scripts: deny\nsecrets:\n  allow_read_globs: ["**/.env.example"]\n  deny_read_globs: ["~/.ssh/**"]\n' > "$P4/$POLICY"
OUT="$(update_kit "$P4")"
assert_contains "$OUT" 'add "**/.env.schema" to it' "An edited allow list without .env.schema gets the .env.schema notice"
assert_eq "" "$(printf '%s\n' "$OUT" | grep -F "was edited, so it was kept" || true)" "...and no missing-settings notice: it keeps both"
printf 'supply_chain:\n  exec_install_scripts: deny\nsecrets:\n  deny_read_globs: ["~/.ssh/**"]\n' > "$P4/$POLICY"
OUT="$(update_kit "$P4")"
assert_eq "" "$(printf '%s\n' "$OUT" | grep -F "$POLICY" || true)" "An edited policy that keeps the kit's settings and has no allow list gets no notice"
# An unedited copy of a version the kit shipped earlier is still kit-owned, so /update
# refreshes it: how a later policy change reaches existing installs. Needs the old blob.
if OLD_POLICY="$(git -C "$REPO_ROOT" cat-file -p 636f1003bb0228e11136f8d78c284d8ce3181eec 2>/dev/null)"; then
  printf '%s\n' "$OLD_POLICY" > "$P4/$POLICY"
  DRY="$(update_kit "$P4" --dry-run)"
  assert_contains "$DRY" "[would update] $POLICY (unedited copy" "update.sh --dry-run reports refreshing an unedited old policy"
  OUT="$(update_kit "$P4")"
  assert_contains "$OUT" "[updated] $POLICY (unedited copy" "update.sh refreshes an unedited old policy"
  assert_eq "" "$(diff "$REPO_ROOT/$POLICY" "$P4/$POLICY" 2>&1 || true)" "...to the kit's current template"
  OUT="$(update_kit "$P4")"
  assert_eq "" "$(printf '%s\n' "$OUT" | grep -F "$POLICY" || true)" "...and a current copy is not mentioned again"
  # A symlinked policy points somewhere the project does not own, so even an unedited
  # old copy behind the link is never written through.
  OUTSIDE="$TEMP_DIR/shared-policy.yaml"
  printf '%s\n' "$OLD_POLICY" > "$OUTSIDE"
  rm -f "$P4/$POLICY" && ln -s "$OUTSIDE" "$P4/$POLICY"
  OUT="$(update_kit "$P4")"
  assert_eq "$(printf '%s\n' "$OLD_POLICY")" "$(cat "$OUTSIDE")" "update.sh never writes through a symlinked policy"
  assert_eq "link" "$([ -L "$P4/$POLICY" ] && echo link || echo replaced)" "...leaves the link itself in place"
  assert_contains "$OUT" "[notice] $POLICY or its directory is a link, so it was left alone" "...and says why it kept it"
else
  echo "  SKIP: the old-policy refresh needs the kit's git history (shallow clone)"
fi
# Nor does it write through a link to create the file: a dangling link would put the
# kit's policy wherever it points, and a linked .safe-ai-skill/ would fill another
# directory.
rm -rf "$P4/.safe-ai-skill" && mkdir -p "$P4/.safe-ai-skill" "$TEMP_DIR/elsewhere"
ln -s "$TEMP_DIR/elsewhere/policy.yaml" "$P4/$POLICY"
OUT="$(update_kit "$P4")"
assert_file_not_exists "$TEMP_DIR/elsewhere/policy.yaml" "update.sh does not create the policy through a dangling link"
assert_contains "$OUT" "[notice] $POLICY or its directory is a link, so it was left alone" "...and says so"
rm -rf "$P4/.safe-ai-skill" && mkdir -p "$TEMP_DIR/shared-dir" && ln -s "$TEMP_DIR/shared-dir" "$P4/.safe-ai-skill"
DRY="$(update_kit "$P4" --dry-run)"
assert_eq "" "$(printf '%s\n' "$DRY" | grep -F "[would create] $POLICY" || true)" "update.sh --dry-run does not offer to create the policy inside a linked .safe-ai-skill/"
OUT="$(update_kit "$P4")"
assert_file_not_exists "$TEMP_DIR/shared-dir/policy.yaml" "update.sh does not create the policy inside a linked .safe-ai-skill/"
assert_contains "$OUT" "[notice] $POLICY or its directory is a link, so it was left alone" "...and says so"
rm -f "$P4/.safe-ai-skill"

# update.sh's list of earlier policy versions is pasted by hand. Every version the file
# has had in the kit's history must be on it, or an unedited copy of the missing one
# would be kept as if the user had edited it. Extra entries are harmless: a squash merge
# drops a PR branch's versions from main's history. Needs full history.
if [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
  CURRENT="$(tr -d '\r' < "$REPO_ROOT/$POLICY" | git hash-object --stdin)"
  LISTED=" $(grep -E '^ *SHIPPED_POLICY_BLOBS="' "$REPO_ROOT/.claude/bin/update.sh" | grep -oE '[0-9a-f]{40}' | tr '\n' ' ')"
  MISSING=""
  for c in $(git -C "$REPO_ROOT" rev-list HEAD -- "$POLICY"); do
    b="$(git -C "$REPO_ROOT" rev-parse -q --verify "$c:$POLICY" 2>/dev/null)" || continue
    [ "$b" = "$CURRENT" ] && continue
    case "$LISTED" in *" $b "*) ;; *) MISSING="$MISSING $b" ;; esac
  done
  assert_eq "" "$MISSING" "update.sh's SHIPPED_POLICY_BLOBS lists every earlier version of $POLICY"
else
  echo "  SKIP: the shipped-policy list check needs full git history (shallow clone)"
fi

print_summary
