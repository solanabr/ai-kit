#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# Model routing policy (README.md "Agents"):
#   model: opus    — deep reasoning where Opus is the right fit
#   model: sonnet  — implementation-heavy, mechanical, docs or high-volume work
#   no model: line — inherit the session model (a Fable session gets Fable)
# Fable is never hardcoded. Commands and skills run in the main conversation, where
# `model:` overrides the rest of the turn, so `opus` there would downgrade a Fable session.
AGENT_MODELS="opus sonnet haiku inherit"
COMMAND_MODELS="sonnet haiku inherit"
FABLE_VALUE_RE='fable|^best$'
FABLE_HARDCODE_RE="claude-fable|model[\"']?[[:space:]]*[:=][[:space:]]*[\"']?fable([\"'[:space:],]|\$)|--model[[:space:]=]+[\"']?fable([\"'[:space:]]|\$)"
README="$REPO_ROOT/README.md"

echo "[test_model_routing] Checking model: routing and Fable hardcoding..."
echo ""

# Frontmatter `model:` value of a markdown file ("" when unset or there is no frontmatter).
fm_model() {
  awk 'NR==1 && $0!="---"{exit} NR==1{next} $0=="---"{exit} /^model:/{sub(/^model:[ \t]*/, ""); print; exit}' "$1" \
    | sed -e 's/[[:space:]]#.*$//' -e "s/[\"']//g" -e 's/[[:space:]]*$//'
}

check_model() {
  local file="$1" allowed="$2" rel model
  rel="${file#"$REPO_ROOT"/}"
  model="$(fm_model "$file")"
  TOTAL=$((TOTAL + 1))
  if [ -z "$model" ]; then
    echo "  PASS: $rel inherits the session model"
    PASS=$((PASS + 1))
  elif printf '%s' "$model" | grep -qiE "$FABLE_VALUE_RE"; then
    echo "  FAIL: $rel hardcodes a Fable model (model: $model)"
    FAIL=$((FAIL + 1))
  elif [[ " $allowed " == *" $model "* ]]; then
    echo "  PASS: $rel model: $model"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $rel model: '$model' is not one of: $allowed"
    FAIL=$((FAIL + 1))
  fi
}

# Kit-owned skills only: .claude/skills/ext/ holds upstream submodules.
SKILL_FILES=()
for f in "$REPO_ROOT"/.claude/skills/*.md "$REPO_ROOT"/.claude/skills/*/SKILL.md "$REPO_ROOT"/plugin/skills/solana-ai-kit/SKILL.md; do
  case "$f" in */skills/ext/*) continue ;; esac
  [ -f "$f" ] && SKILL_FILES+=("$f")
done

echo "[Agents: model: is one of '$AGENT_MODELS' or omitted]"
for f in "$REPO_ROOT"/.claude/agents/*.md; do check_model "$f" "$AGENT_MODELS"; done
echo ""

echo "[Commands: model: is one of '$COMMAND_MODELS' or omitted]"
for f in "$REPO_ROOT"/.claude/commands/*.md; do check_model "$f" "$COMMAND_MODELS"; done
echo ""

echo "[Skills: model: is one of '$COMMAND_MODELS' or omitted]"
for f in "${SKILL_FILES[@]}"; do check_model "$f" "$COMMAND_MODELS"; done
echo ""

# A command gets `model:` only when it is mechanical AND runs at session start: mid-session
# it switches the model for the rest of the turn and drops the prompt cache. A command with
# `disable-model-invocation: true` is user-invoked by definition, so it is always mid-session
# and must inherit. Asserted as the rule, not per command, so a new one is covered too.
echo "[User-invoked commands inherit the session model]"
# Four commands predate the rule and still pin `model: sonnet`; they are recorded here as
# known debt rather than silently exempted, so anything NEW is caught. Removing a name from
# this list is the fix, never adding one.
MID_SESSION_KNOWN="cleanup.md commit-claude-config.md resync.md update.md"
MID_SESSION_SWITCH=""
MID_SESSION_DEBT=""
for f in "$REPO_ROOT"/.claude/commands/*.md; do
  front="$(awk 'NR==1 && $0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$f")"
  printf '%s' "$front" | grep -q '^disable-model-invocation:[[:space:]]*true' || continue
  model="$(fm_model "$f")"
  [ -z "$model" ] && continue
  if [[ " $MID_SESSION_KNOWN " == *" $(basename "$f") "* ]]; then
    MID_SESSION_DEBT="$MID_SESSION_DEBT $(basename "$f")"
  else
    MID_SESSION_SWITCH="$MID_SESSION_SWITCH
${f#"$REPO_ROOT"/} (model: $model)"
  fi
done
TOTAL=$((TOTAL + 1))
if [ -z "$MID_SESSION_SWITCH" ]; then
  echo "  PASS: no new disable-model-invocation command pins a model: (a mid-session switch drops the prompt cache)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: these user-invoked commands pin a model:, switching it mid-session:"
  printf '%s\n' "$MID_SESSION_SWITCH" | sed '/^$/d; s/^/    /'
  FAIL=$((FAIL + 1))
fi
[ -n "$MID_SESSION_DEBT" ] && echo "  NOTE: known debt, pre-dates the rule:$MID_SESSION_DEBT"
echo ""

echo "[No hardcoded Fable model]"
HITS="$(grep -n -i -E "$FABLE_HARDCODE_RE" "$REPO_ROOT"/.claude/agents/*.md "$REPO_ROOT"/.claude/commands/*.md "${SKILL_FILES[@]}" || true)"
TOTAL=$((TOTAL + 1))
if [ -z "$HITS" ]; then
  echo "  PASS: no agent, command or skill file hardcodes a Fable model"
  PASS=$((PASS + 1))
else
  echo "  FAIL: hardcoded Fable model in agent/command/skill files:"
  printf '%s\n' "$HITS" | sed "s|$REPO_ROOT/|    |"
  FAIL=$((FAIL + 1))
fi

# Settings (and the plugin hooks that mirror them): no Fable value under any *model* key or
# env var, no full Fable model ID and no `--model fable` anywhere.
for json_file in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/plugin/hooks/hooks.json"; do
  rel="${json_file#"$REPO_ROOT"/}"
  BAD="$(python3 - "$json_file" <<'PY' 2>&1 || echo "__ERROR__ could not parse"
import json, re, sys
hard = re.compile(r"claude-fable|--model[\s=]+[\"']?(fable|best)\b", re.I)
bad = []
def walk(node, path, model_key):
    if isinstance(node, dict):
        for key, value in node.items():
            walk(value, f"{path}.{key}", model_key or "model" in key.lower())
    elif isinstance(node, list):
        for i, value in enumerate(node):
            walk(value, f"{path}[{i}]", model_key)
    elif isinstance(node, str):
        if hard.search(node) or (model_key and ("fable" in node.lower() or node.strip().lower() == "best")):
            bad.append(f"{path} = {node[:80]!r}")
walk(json.load(open(sys.argv[1])), "$", False)
print("\n".join(bad))
PY
)"
  TOTAL=$((TOTAL + 1))
  if [ -z "$BAD" ]; then
    echo "  PASS: $rel hardcodes no Fable model"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $rel hardcodes a Fable model:"
    printf '%s\n' "$BAD" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
done
echo ""

echo "[README Agents table: Model column matches frontmatter]"
AGENTS_SECTION="$(awk '/^## Agents$/{f=1; next} /^## /{f=0} f' "$README")"
for f in "$REPO_ROOT"/.claude/agents/*.md; do
  name="$(basename "$f" .md)"
  case "$(fm_model "$f")" in
    ""|inherit) expected="Inherit" ;;
    opus) expected="Opus" ;;
    sonnet) expected="Sonnet" ;;
    haiku) expected="Haiku" ;;
    *) expected="(unsupported model)" ;;
  esac
  row="$(printf '%s\n' "$AGENTS_SECTION" | grep -F "| **$name** |" | head -1 || true)"
  actual="$(printf '%s\n' "$row" | awk -F'|' 'NF > 2 { v = $(NF-1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')"
  assert_eq "$expected" "$actual" "README lists $name as $expected"
done

print_summary
