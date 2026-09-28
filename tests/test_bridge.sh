#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" NO_COLOR=1

# install <dir> [--agents] — output goes to $WORK/last.log
install_kit() {
  local d="$1"; shift
  mkdir -p "$d" && (cd "$d" && git init -q)
  bash "$REPO_ROOT/install.sh" "$@" "$d" >"$WORK/last.log" 2>&1
}
gate_rc() {  # gate_rc <install dir> <command string>
  printf '{"tool_input":{"command":"%s"}}' "$2" \
    | (cd "$1" && bash "$1/.claude/bin/hooks/pre-deploy.sh") >/dev/null 2>&1
  echo $?
}

echo "[default install: no bridge]"
PLAIN="$WORK/plain"
install_kit "$PLAIN"
assert_dir_exists "$PLAIN/.claude" "default install writes .claude/"
assert_file_exists "$PLAIN/CLAUDE.md" "default install writes CLAUDE.md"
assert_file_not_exists "$PLAIN/AGENTS.md" "default install writes no AGENTS.md"
assert_dir_not_exists "$PLAIN/.agents" "default install writes no .agents/"
assert_dir_not_exists "$PLAIN/.codex" "default install writes no .codex/"

echo "[--agents: one tree plus the bridge]"
B="$WORK/bridge"
install_kit "$B" --agents
assert_dir_exists "$B/.claude" "--agents installs the full .claude/ tree"
assert_file_exists "$B/CLAUDE.md" "--agents still writes CLAUDE.md for Claude Code"
assert_file_exists "$B/AGENTS.md" "--agents writes AGENTS.md"
assert_file_exists "$B/.agents/skills/solana-ai-kit/SKILL.md" "--agents writes the router skill"
assert_file_exists "$B/.codex/hooks.json" "--agents writes the Codex hook config"
assert_json_valid "$B/.codex/hooks.json" ".codex/hooks.json is valid JSON"
# The parallel tree is gone: these are the dirs no AGENTS.md harness reads.
for d in agents commands bin rules; do
  assert_dir_not_exists "$B/.agents/$d" ".agents/$d/ is not installed (no harness reads it)"
done
assert_file_not_exists "$B/.agents/settings.json" ".agents/settings.json is not installed"

echo "[skill budget: exactly one entry]"
# Codex divides a fixed metadata budget across every registered skill, so a second
# entry here is how descriptions start getting truncated to nothing.
assert_eq "1" "$(find "$B/.agents/skills" -name SKILL.md | wc -l | tr -d ' ')" \
  "exactly one SKILL.md under .agents/skills/"
ROUTER="$B/.agents/skills/solana-ai-kit/SKILL.md"
assert_file_contains "$ROUTER" "name: solana-ai-kit" "router declares a name (Codex requires it)"
assert_file_contains "$ROUTER" ".claude/skills/SKILL.md" "router points at the kit hub"
ROUTER_DESC="$(awk -F'description: ' '/^description: /{print $2; exit}' "$ROUTER")"
assert_cmd_success "[ ${#ROUTER_DESC} -gt 0 ] && [ ${#ROUTER_DESC} -le 1024 ]" \
  "router description is present and within Codex's 1024-char cap"

echo "[AGENTS.md content]"
assert_eq "" "$(grep -n '<!--\|-->' "$B/AGENTS.md" || true)" \
  "AGENTS.md carries no HTML comments (Codex does not strip them)"
assert_cmd_success "grep -q '<!--' '$B/CLAUDE.md'" \
  "CLAUDE.md keeps its comments (Claude Code strips them for free)"
# Same instructions, comments removed — nothing else may differ.
python3 - "$REPO_ROOT/CLAUDE-solana.md" "$B/AGENTS.md" <<'PY' && PASSED=1 || PASSED=0
import re, sys
src = re.sub(r"<!--.*?-->", "", open(sys.argv[1], encoding="utf-8").read(), flags=re.S)
want, prev = [], False
for line in src.split("\n"):
    if line.strip(): want.append(line); prev = False
    elif not prev: want.append(""); prev = True
got = open(sys.argv[2], encoding="utf-8").read().split("\n")
trim = lambda x: "\n".join(x).rstrip("\n")
sys.exit(0 if trim(want) == trim(got) else 1)
PY
assert_eq "1" "$PASSED" "AGENTS.md is CLAUDE-solana.md with only its comments removed"
AGENTS_BYTES="$(wc -c < "$B/AGENTS.md" | tr -d ' ')"
assert_cmd_success "[ $AGENTS_BYTES -lt 32768 ]" \
  "AGENTS.md ($AGENTS_BYTES B) fits Codex's 32KiB project_doc_max_bytes cap"

echo "[mainnet gate reaches the bridge]"
assert_file_exists "$B/.claude/bin/hooks/pre-deploy.sh" "shared gate script is installed"
assert_eq "2" "$(gate_rc "$B" 'solana program deploy p.so --url mainnet-beta')" \
  "gate blocks an unconfirmed mainnet deploy"
assert_eq "0" "$(gate_rc "$B" 'CONFIRM_MAINNET=1 solana program deploy p.so --url mainnet-beta')" \
  "gate allows CONFIRM_MAINNET=1 (a leading VAR= must not hide the command)"
assert_eq "2" "$(gate_rc "$B" 'anchor deploy --provider.cluster mainnet')" \
  "gate blocks an unconfirmed anchor mainnet deploy"
assert_eq "0" "$(gate_rc "$B" 'ls -la')" "gate ignores unrelated commands"
assert_file_contains "$B/.codex/hooks.json" "pre-deploy.sh" "Codex config calls the same gate script"

echo "[gitignore]"
BLOCK="$(sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$B/.gitignore")"
for e in ".claude/" "CLAUDE.md" "AGENTS.md" ".agents/" ".codex/"; do
  assert_contains "$BLOCK" "$e" "gitignore config block covers $e"
done
assert_eq "" "$(cd "$B" && git status --porcelain | grep -E '\.agents|\.codex|AGENTS\.md' || true)" \
  "nothing from the bridge is left untracked"

echo "[bridge added to an existing default install]"
DUAL="$WORK/dual"
install_kit "$DUAL"
install_kit "$DUAL" --agents
DBLOCK="$(sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$DUAL/.gitignore")"
for e in "AGENTS.md" ".agents/" ".codex/"; do
  assert_contains "$DBLOCK" "$e" "second --agents run tops up the existing block with $e"
done
assert_file_exists "$DUAL/.agents/skills/solana-ai-kit/SKILL.md" "bridge added on top of a default install"

echo "[idempotent]"
SNAP() { (cd "$1" && find . -path ./.git -prune -o -type f -exec cksum {} + | LC_ALL=C sort -k3); }
SNAP "$B" > "$WORK/before.txt"
install_kit "$B" --agents
SNAP "$B" > "$WORK/after.txt"
assert_cmd_success "diff -q '$WORK/before.txt' '$WORK/after.txt'" "re-running --agents changes nothing"
assert_file_not_exists "$B/AGENTS.md.bak" "an unmodified AGENTS.md is not backed up"

echo "[user edits preserved]"
printf '# mine\n' > "$DUAL/AGENTS.md"
install_kit "$DUAL" --agents
assert_file_exists "$DUAL/AGENTS.md.bak" "a user-edited AGENTS.md is backed up"

print_summary
