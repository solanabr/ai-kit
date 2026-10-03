#!/usr/bin/env bash
set -euo pipefail

# install.sh from a git remote: the clone skips submodules, then fetches only the
# skill packs the install keeps (core, --with, extensions.txt). Offline: the kit
# and its packs are local repos, reached through SOLANA_AI_KIT_UPSTREAM.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_install_packs] install.sh fetches only the skill packs it keeps"
echo ""

# Submodule URLs below are local paths; git refuses those for submodules by default.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
G() { git -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main "$@"; }

new_pack() {  # new_pack <id>: a one-commit repo standing in for an upstream pack
  mkdir -p "$TEMP_DIR/packs/$1"
  G -C "$TEMP_DIR/packs" init -q "$1"
  printf -- '---\nname: %s\ndescription: Fixture pack.\n---\n' "$1" > "$TEMP_DIR/packs/$1/SKILL.md"
  G -C "$TEMP_DIR/packs/$1" add -A
  G -C "$TEMP_DIR/packs/$1" commit -qm "$1"
}

CORE="solana-dev auditor-skill colosseum"
for id in $CORE jupiter sendai; do new_pack "$id"; done

# The kit: its real .claude/ (no ext/ checkouts), with four packs as submodules.
KIT="$TEMP_DIR/kit"
mkdir -p "$KIT/.claude/skills"
for f in "$REPO_ROOT"/.claude/*; do [ "$(basename "$f")" = skills ] || cp -R "$f" "$KIT/.claude/"; done
for f in "$REPO_ROOT"/.claude/skills/*; do [ "$(basename "$f")" = ext ] || cp -R "$f" "$KIT/.claude/skills/"; done
cp "$REPO_ROOT/CLAUDE-solana.md" "$REPO_ROOT/.mcp.json" "$REPO_ROOT/.env.example" "$KIT/"
G -C "$TEMP_DIR" init -q kit
for id in $CORE jupiter sendai; do
  G -C "$KIT" submodule add -q "file://$TEMP_DIR/packs/$id" ".claude/skills/ext/$id" >/dev/null 2>&1
done
# sendai's source is gone: fetching it fails the install, so a pass proves it was not fetched.
G -C "$KIT" config -f .gitmodules submodule..claude/skills/ext/sendai.url "file://$TEMP_DIR/packs/missing"
G -C "$KIT" add -A
G -C "$KIT" commit -qm kit
# The fixture's gitlinks are its own one-commit packs, so the registry it inherited from
# the real repo pins commits that do not exist here. install.sh refuses a pack whose
# gitlink differs from the registry, so bring the two in line the way a maintainer (and
# the sync-skill-pins CI job on a Dependabot bump) does.
(cd "$KIT" && bash .claude/bin/skills.sh pins --write >/dev/null)
G -C "$KIT" commit -qam "sync pins"
export SOLANA_AI_KIT_UPSTREAM="file://$KIT"

ext_dirs() { find "$1" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
sorted() { printf '%s\n' "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }
new_project() { mkdir -p "$TEMP_DIR/$1" && git -C "$TEMP_DIR/$1" init -q && echo "$TEMP_DIR/$1"; }
install_ok() {  # install_ok <message> <install.sh args...>
  local message="$1" out status=0
  shift
  out="$(bash "$REPO_ROOT/install.sh" "$@" 2>&1)" || status=$?
  TOTAL=$((TOTAL + 1))
  if [ "$status" -eq 0 ]; then
    echo "  PASS: $message"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $message (exit $status)"
    printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

echo "[default install]"
P1="$(new_project default)"
install_ok "install.sh succeeds without fetching an extension it does not keep" "$P1"
assert_eq "$(sorted $CORE)" "$(ext_dirs "$P1/.claude/skills/ext")" "Only the core packs are installed"
assert_file_exists "$P1/.claude/skills/ext/solana-dev/SKILL.md" "A core pack arrives with its files"
assert_eq "" "$(find "$P1/.claude/skills/ext" -name .git)" "Vendored packs carry no submodule gitfile"

echo "[--agents]"
P2="$(new_project agents)"
install_ok "install.sh --agents fetches only the core packs" --agents "$P2"
assert_eq "$(sorted $CORE)" "$(ext_dirs "$P2/.agents/skills/ext")" "--agents installs only the core packs"

echo "[--with and extensions.txt]"
P3="$(new_project with)"
install_ok "install.sh --with jupiter fetches that extension too" --with jupiter "$P3"
assert_eq "$(sorted $CORE jupiter)" "$(ext_dirs "$P3/.claude/skills/ext")" "--with adds the named extension"
P4="$(new_project recorded)"
mkdir -p "$P4/.claude/skills" && printf 'jupiter\n' > "$P4/.claude/skills/extensions.txt"
install_ok "Re-install keeps a recorded extension" "$P4"
assert_eq "$(sorted $CORE jupiter)" "$(ext_dirs "$P4/.claude/skills/ext")" "An extension in extensions.txt is fetched again"
P5="$(new_project unreachable)"
TOTAL=$((TOTAL + 1))
if bash "$REPO_ROOT/install.sh" --with sendai "$P5" >/dev/null 2>&1; then
  echo "  FAIL: install.sh reported success although a pack it keeps could not be fetched"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: install.sh fails when a pack it keeps cannot be fetched"
  PASS=$((PASS + 1))
fi

# The registry pin is the only record of a pack's commit that reaches a project, so a kit
# whose gitlink says something else must stop the install rather than vendor it quietly.
echo "[pin mismatch]"
PINS_OUT="$(cd "$KIT" && bash .claude/bin/skills.sh pins 2>&1)"
assert_contains "$PINS_OUT" "match the registry" "skills.sh pins reports the synced fixture as matching"
python3 - "$KIT/.claude/skills/skill-registry.json" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
# One core pack now claims a commit the fixture does not have.
t = re.sub(r'("id": "solana-dev",.*?"commit": ")[0-9a-f]{40}', r"\g<1>" + "d" * 40, t, count=1, flags=re.S)
open(p, "w", encoding="utf-8").write(t)
PY
G -C "$KIT" commit -qam "drift one pin"
P7="$(new_project drifted)"
TOTAL=$((TOTAL + 1))
DRIFT_OUT="$(bash "$REPO_ROOT/install.sh" "$P7" 2>&1)" && DRIFT_RC=0 || DRIFT_RC=$?
if [ "$DRIFT_RC" -ne 0 ] && printf '%s' "$DRIFT_OUT" | grep -q "solana-dev: gitlink"; then
  echo "  PASS: install.sh refuses a pack whose gitlink differs from the registry pin"
  PASS=$((PASS + 1))
else
  echo "  FAIL: install.sh vendored a pack at a commit the registry does not record (exit $DRIFT_RC)"
  printf '%s\n' "$DRIFT_OUT" | tail -5 | sed 's/^/    /'
  FAIL=$((FAIL + 1))
fi
assert_dir_not_exists "$P7/.claude/skills/ext/solana-dev" "...and installs no pack"
(cd "$KIT" && bash .claude/bin/skills.sh pins --write >/dev/null)
G -C "$KIT" commit -qam "resync pins"

# A release without skills.sh has no tiers: every pack is fetched, as before.
echo "[release without skills.sh]"
G -C "$KIT" config -f .gitmodules submodule..claude/skills/ext/sendai.url "file://$TEMP_DIR/packs/sendai"
G -C "$KIT" rm -q .claude/bin/skills.sh
G -C "$KIT" commit -qam "old release"
G -C "$KIT" tag v9.9.9
P6="$(new_project old-release)"
install_ok "install.sh installs a tagged release without skills.sh" "$P6"
assert_eq "$(sorted $CORE jupiter sendai)" "$(ext_dirs "$P6/.claude/skills/ext")" "...with every pack it pins"

print_summary
