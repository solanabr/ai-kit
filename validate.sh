#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit Validator
# Run from repo root to check config integrity.

PASS=0
FAIL=0
SKIP=0

# A path lives under an ext/ submodule; if that submodule dir is empty it isn't
# initialized (fresh clone without --recurse-submodules, or before install.sh) —
# a setup state, NOT broken config. Return 0 when the path is inside an
# uninitialized submodule so callers can SKIP instead of FAIL.
in_uninitialized_submodule() {
  local path="$1"
  # Links from agents/, commands/ and skill folders climb out first
  # (../skills/ext/..., ../ext/...): drop each "dir/.." pair.
  path="$(printf '%s' "$path" | sed -E -e ':a' -e 's#(^|/)[^/.][^/]*/\.\./#\1#' -e 'ta')"
  case "$path" in
    .claude/skills/ext/*)
      local sub
      sub="$(printf '%s' "$path" | sed -E 's#(\.claude/skills/ext/[^/]+).*#\1#')"
      [ -d "$sub" ] && [ -z "$(ls -A "$sub" 2>/dev/null)" ]
      ;;
    *) return 1 ;;
  esac
}

check() {
  local description="$1"
  local result="$2"
  if [ "$result" -eq 0 ]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    FAIL=$((FAIL + 1))
  fi
}

echo "Validating Solana AI Kit..."
echo ""

# --- Agent frontmatter ---
echo "[Agents]"
for f in .claude/agents/*.md; do
  name="$(basename "$f")"
  has_name=1; has_desc=1; model_ok=1

  # Check for frontmatter block
  if head -1 "$f" | grep -q "^---"; then
    frontmatter="$(awk '/^---$/{c++;next} c==1{print; if(NR>22)exit}' "$f")"
    echo "$frontmatter" | grep -q "^name:" && has_name=0
    echo "$frontmatter" | grep -q "^description:" && has_desc=0
    # model: is optional (omitted = inherit the session model); never hardcode fable
    echo "$frontmatter" | grep -q "^model:" || model_ok=0
    echo "$frontmatter" | grep -qE "^model:[[:space:]]*(opus|sonnet|haiku|inherit)[[:space:]]*$" && model_ok=0
  fi

  check "$name has name:" $has_name
  check "$name has description:" $has_desc
  check "$name model: omitted or opus|sonnet|haiku|inherit" $model_ok
done
echo ""

# --- Command frontmatter ---
echo "[Commands]"
for f in .claude/commands/*.md; do
  name="$(basename "$f")"
  has_desc=1

  if head -1 "$f" | grep -q "^---"; then
    frontmatter="$(awk '/^---$/{c++;next} c==1{print; if(NR>22)exit}' "$f")"
    echo "$frontmatter" | grep -q "^description:" && has_desc=0
  fi

  check "$name has description:" $has_desc
done
echo ""

# --- Description budget ---
# Agent and command descriptions are listed to the model in every session, so keep
# them to routing essentials. Bodies load only when used.
echo "[Descriptions]"
long_desc=0
# Counted, and asserted below. The producer is a python block with its own globs, so if
# those ever match nothing — a moved directory, a crash, validate.sh run from the wrong
# cwd — the loop body never runs, `long_desc` stays 0 and the budget is reported as
# verified over zero files. Demonstrated: with .claude/agents and .claude/commands empty,
# [Agents] and [Commands] go red on the literal glob while this block printed PASS.
desc_checked=0
while IFS=$'\t' read -r len limit file; do
  desc_checked=$((desc_checked + 1))
  if [ "$len" -gt "$limit" ]; then
    echo "  FAIL: $file description is $len chars (limit $limit)"
    FAIL=$((FAIL + 1))
    long_desc=$((long_desc + 1))
  fi
done < <(python3 - <<'PY'
import glob, re
for pattern, limit in ((".claude/agents/*.md", 250), (".claude/commands/*.md", 100)):
    for path in sorted(glob.glob(pattern)):
        text = open(path, encoding="utf-8").read()
        front = text.split("\n---", 1)[0] if text.startswith("---") else ""
        m = re.search(r"^description:\s*(.*)$", front, re.M)
        desc = m.group(1).strip().strip("\"'") if m else ""
        print(f"{len(desc)}\t{limit}\t{path}")
PY
)
if [ "$desc_checked" -eq 0 ]; then
  echo "  FAIL: no agent or command description was read, so neither budget was checked"
  FAIL=$((FAIL + 1))
elif [ "$long_desc" -eq 0 ]; then
  check "Agent descriptions <= 250 chars, command descriptions <= 100 chars ($desc_checked checked)" 0
fi
echo ""

# --- Skill references ---
echo "[Skills]"
if [ -f .claude/skills/SKILL.md ]; then
  check "SKILL.md exists" 0

  # Extract markdown links and check targets.
  # hub_links is counted and asserted below: the extraction is a grep for inline
  # `](target)`, so a hub rewritten with reference-style links (or any other change that
  # empties that grep) would leave broken=0 and report every link as resolving over an
  # empty set. Demonstrated by rewriting the hub's 284 links to reference style with one
  # broken route left in: this block printed "PASS: All SKILL.md links resolve".
  broken=0
  hub_links=0
  while IFS= read -r link; do
    # Remove leading/trailing whitespace
    link="$(echo "$link" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [ -z "$link" ] && continue
    hub_links=$((hub_links + 1))

    target=".claude/skills/$link"
    if [ ! -e "$target" ] && [ ! -d "$target" ]; then
      if in_uninitialized_submodule "$target"; then
        SKIP=$((SKIP + 1))
      else
        echo "  FAIL: Broken link -> $link"
        FAIL=$((FAIL + 1))
        broken=$((broken + 1))
      fi
    fi
  done < <(grep -oE '\]\([^)]+\)' .claude/skills/SKILL.md | sed 's/\](//' | sed 's/)//' | grep -v '^http')

  if [ "$hub_links" -eq 0 ]; then
    echo "  FAIL: no relative link found in .claude/skills/SKILL.md, so none was checked"
    FAIL=$((FAIL + 1))
  elif [ "$broken" -eq 0 ]; then
    check "All SKILL.md links resolve ($hub_links checked)" 0
  fi
else
  check "SKILL.md exists" 1
fi
echo ""

# --- Relative links in every shipped .md under .claude/ (ext/ pack content excluded) ---
# Dependabot bumps the ext/ pins; a path an upstream pack moved must fail here, in CI,
# not in a user's session. Links between kit files are checked the same way.
# Anchors (#...) are stripped; the hub is checked above.
echo "[Links]"
broken=0
# Same accounting as the hub block above: both the file list and the per-file link
# extraction can come back empty, and the pass is reported outside both loops.
kit_md=0
kit_links=0
while IFS= read -r f; do
  kit_md=$((kit_md + 1))
  while IFS= read -r link; do
    link="${link%%#*}"
    [ -z "$link" ] && continue
    kit_links=$((kit_links + 1))
    if [ ! -e "$(dirname "$f")/$link" ]; then
      if in_uninitialized_submodule "$(dirname "$f")/$link"; then
        SKIP=$((SKIP + 1))
      else
        echo "  FAIL: $f -> $link"
        FAIL=$((FAIL + 1))
        broken=$((broken + 1))
      fi
    fi
  done < <(grep -oE '\]\([^)[:space:]]+\)' "$f" | sed 's/^](//; s/)$//' | grep -vE '^(https?|mailto):' || true)
done < <(find .claude -maxdepth 1 -name '*.md'; find .claude/agents .claude/commands -name '*.md'; find .claude/skills -path .claude/skills/ext -prune -o -name '*.md' ! -path .claude/skills/SKILL.md -print)
if [ "$kit_md" -eq 0 ] || [ "$kit_links" -eq 0 ]; then
  echo "  FAIL: $kit_md markdown files and $kit_links relative links found under .claude/, so none was checked"
  FAIL=$((FAIL + 1))
elif [ "$broken" -eq 0 ]; then
  check "Every relative link in .claude/ markdown (agents, commands, skills) resolves ($kit_links in $kit_md files)" 0
fi
echo ""

# --- Submodules ---
echo "[Submodules]"
for dir in .claude/skills/ext/*/; do
  name="$(basename "$dir")"
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "  SKIP: ext/$name not initialized (run: git submodule update --init)"
    SKIP=$((SKIP + 1))
  else
    check "ext/$name is initialized (non-empty)" 0
  fi
done

# Each pinned pack records its commit in skill-registry.json. That record is the only
# pin a user project carries — install.sh vendors ext/ packs and strips their gitfiles —
# so it has to match the gitlink a clone actually checks out. Without this check the two
# drift apart silently and the registry promises a commit nobody ships. Dependabot moves
# the gitlinks; .github/workflows/sync-skill-pins.yml rewrites the registry on its PR, so
# a failure here means that sync did not run (fix: skills.sh pins --write).
if [ -e .git ]; then
  pins_ok=0
  pins_out="$(bash .claude/bin/skills.sh pins 2>&1)" || pins_ok=1
  [ "$pins_ok" -eq 0 ] || printf '%s\n' "$pins_out" | sed 's/^/    /'
  check "Every submodule pack's registry commit matches its gitlink (skills.sh pins)" "$pins_ok"
else
  echo "  SKIP: not a git checkout, so registry pins cannot be compared to gitlinks"
  SKIP=$((SKIP + 1))
fi

# An upstream pack (anthropic-skills) has no gitlink: its commit is the fetch target
# skills.sh asserts against FETCH_HEAD. Either way the entry must carry a full SHA.
unpinned=0
python3 - <<'PY' || unpinned=1
import json, re, sys
bad = []
for e in json.load(open(".claude/skills/skill-registry.json", encoding="utf-8"))["entries"]:
    if "tier" not in e:
        continue
    if not re.fullmatch(r"[0-9a-f]{40}", e.get("commit", "")):
        bad.append(f"  FAIL: {e['id']} has no 40-character commit in skill-registry.json")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
check "Every core/extension registry entry records a 40-character commit" "$unpinned"

# Two packs carry submodules of their own, pinned by their authors rather than by this
# kit: auditor-skill -> trailofbits (CC-BY-SA-4.0) and solana-game -> a second solana-dev
# at a different commit. The installers deliberately do not recurse into them, so neither
# reaches a user project; "vendored" records the pins anyway so a bump of a pack moves a
# third-party pin here, in review, instead of invisibly. Update it with the new SHA after
# reading what changed. Skipped when the pack is not checked out.
nested_drift=0
python3 - <<'PY' || nested_drift=1
import json, os, subprocess, sys
bad = []
for e in json.load(open(".claude/skills/skill-registry.json", encoding="utf-8"))["entries"]:
    for sub, want in (e.get("vendored") or {}).items():
        pack = e["path"]
        if not os.path.isdir(pack) or not os.listdir(pack):
            continue
        out = subprocess.run(["git", "-C", pack, "ls-files", "-s", "--", sub],
                             capture_output=True, text=True).stdout.split()
        have = out[1] if len(out) > 2 and out[0] == "160000" else ""
        if not have:
            continue
        if have != want:
            bad.append(f"  FAIL: {e['id']} pins {sub} at {have[:12]}, the registry records {want[:12]}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
check "Every pack's own submodule pins match the registry's vendored record" "$nested_drift"
echo ""

# --- Versioning ---
echo "[Versioning]"
if [ -f .claude/VERSION ]; then
  if grep -qE '(^|[[:space:]])[0-9]+\.[0-9]+\.[0-9]+$' .claude/VERSION; then
    check ".claude/VERSION follows semver" 0
  else
    check ".claude/VERSION follows semver" 1
  fi
else
  check ".claude/VERSION file exists" 1
fi

if [ -f .claude/bin/update.sh ] && [ -x .claude/bin/update.sh ]; then
  check "update.sh exists and is executable" 0
else
  check "update.sh exists and is executable" 1
fi

# update.sh strips retired kit defaults from installs whose version matches its migration
# case. If the shipped version matched, /update would strip values the user of a current
# install set themselves: bump VERSION on release, and don't add it to that case.
if [ -f .claude/VERSION ] && [ -f .claude/bin/update.sh ]; then
  shipped="$(awk '{print $NF}' .claude/VERSION)"
  gate="$(awk '/case "\$CURRENT_VERSION" in/ { getline; sub(/^[[:space:]]+/, ""); sub(/\).*/, ""); print; exit }' .claude/bin/update.sh)"
  gate_ok=1
  if [ -n "$gate" ]; then
    gate_ok=0
    IFS='|' read -r -a gate_pats <<< "$gate"
    for pat in "${gate_pats[@]}"; do
      # shellcheck disable=SC2053  # $pat is a glob on purpose, as in update.sh's case
      [[ "$shipped" == $pat ]] && gate_ok=1
    done
  fi
  check "Shipped VERSION $shipped is outside update.sh's retired-defaults migration case ($gate)" "$gate_ok"
fi

if [ -f .claude/bin/resync.sh ] && [ -x .claude/bin/resync.sh ]; then
  check "resync.sh exists and is executable" 0
else
  check "resync.sh exists and is executable" 1
fi
echo ""

# --- .env.example ---
echo "[Environment]"
if [ -f .env.example ]; then
  check ".env.example exists" 0
else
  check ".env.example exists" 1
fi
echo ""

# --- JSON files ---
echo "[JSON]"
if [ -f .claude/settings.json ]; then
  if python3 -c "import json; json.load(open('.claude/settings.json'))" 2>/dev/null; then
    check "settings.json is valid JSON" 0
  else
    check "settings.json is valid JSON" 1
  fi
else
  check "settings.json exists" 1
fi

if [ -f .mcp.json ]; then
  if python3 -c "import json; json.load(open('.mcp.json'))" 2>/dev/null; then
    check ".mcp.json is valid JSON" 0
  else
    check ".mcp.json is valid JSON" 1
  fi
  # npx -y runs whatever was published last, with no prompt; default servers are pinned
  # like everything else the kit ships (CLAUDE.md ripple map: "Bump a default MCP server").
  unpinned="$(python3 -c 'import json, re
d = json.load(open(".mcp.json"))
bad = []
for name, s in (d.get("mcpServers") or {}).items():
    if s.get("command") != "npx":
        continue
    pkgs = [a for a in s.get("args") or [] if not a.startswith("-")][:1]
    for a in pkgs:
        # Exact x.y.z only, on purpose: prereleases (1.2.3-beta.1) and ranges are rejected too
        if not re.search(r"@\d+\.\d+\.\d+$", a[1:]):
            bad.append(name + ":" + a)
print(" ".join(bad))' 2>/dev/null || echo "unparsed")"
  if [ -z "$unpinned" ]; then
    check ".mcp.json pins every npx server to an exact version (no @latest)" 0
  else
    check ".mcp.json pins every npx server to an exact version (no @latest): $unpinned" 1
  fi
fi
echo ""

# --- Session behavior stays with the user ---
# settings.json ships the security policy and attribution. These keys pinned behavior
# for every user (effort, experimental modes, LSP plugins, MCP auto-approval) or were
# dead; update.sh strips them from older installs.
echo "[Settings]"
# A bare `Bash` or `Bash(*)` entry in permissions.ask is silently voided for any command
# that runs sandboxed, and the kit ships the sandbox on — so such a rule reads as a gate
# and is not one. A content-scoped ask like Bash(git push *) does fire, in default and in
# bypass mode, so the problem is the bare form specifically, not `ask` itself.
bare_ask="$(python3 -c 'import json
d = json.load(open(".claude/settings.json"))
ask = (d.get("permissions") or {}).get("ask") or []
print(" ".join(r for r in ask if r.strip() in ("Bash", "Bash(*)")))' 2>/dev/null || true)"
if [ -z "$bare_ask" ]; then
  check "no bare Bash entry in permissions.ask (the sandbox voids it for sandboxed commands)" 0
else
  echo "  FAIL: permissions.ask contains $bare_ask; scope it to a command or use a hook"
  FAIL=$((FAIL + 1))
fi

retired_keys="$(python3 -c 'import json
d = json.load(open(".claude/settings.json"))
env = d.get("env") or {}
plugins = d.get("enabledPlugins") or {}
keys = [k for k in ("enableAllProjectMcpServers", "defaultMode", "modelDefaults") if k in d]
keys += ["env." + k for k in ("CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CODE_COORDINATOR_MODE",
         "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "BASH_MAX_OUTPUT_LENGTH", "MAX_MCP_OUTPUT_TOKENS") if k in env]
keys += ["enabledPlugins." + p for p in plugins if p.split("@")[0] in ("rust-analyzer-lsp", "typescript-lsp", "csharp-lsp")]
print(" ".join(keys))' 2>/dev/null || true)"
if [ -z "$retired_keys" ]; then
  check "settings.json pins no session behavior (effort, env toggles, LSP plugins, MCP auto-approval)" 0
else
  echo "  FAIL: settings.json sets $retired_keys; leave these to the user (.claude/settings.local.json)"
  FAIL=$((FAIL + 1))
fi
echo ""

# --- Agentic firewall ---
# The tier in security.json is the only record of which rules the kit wrote, and permission
# lists merge across sources with no un-deny primitive: the generated block has to be
# replaced wholesale, every time, or a project pins itself at the strictest tier it ever saw.
echo "[Firewall]"
if [ ! -f .claude/security.json ]; then
  check ".claude/security.json exists (records the firewall tier)" 1
elif ! python3 -c "import json; json.load(open('.claude/security.json'))" 2>/dev/null; then
  check ".claude/security.json is valid JSON" 1
else
  check ".claude/security.json is valid JSON" 0
  fw_tier="$(python3 -c "import json; print(json.load(open('.claude/security.json')).get('tier', ''))" 2>/dev/null)"
  case "$fw_tier" in
    off|relaxed|medium|high) check "security.json tier is one of off|relaxed|medium|high ($fw_tier)" 0 ;;
    *) echo "  FAIL: security.json tier must be off|relaxed|medium|high (got '$fw_tier')"
       FAIL=$((FAIL + 1)) ;;
  esac

  # enforced.ruleIds is what a tier switch subtracts. An id the live settings.json no longer
  # holds means the record has drifted, and the next switch would leave a rule behind.
  stale_ids="$(python3 -c 'import json
sec = json.load(open(".claude/security.json"))
live = json.load(open(".claude/settings.json"))
pool = set()
perms = live.get("permissions") or {}
for key in ("allow", "ask", "deny"):
    pool |= {e for e in perms.get(key) or [] if isinstance(e, str)}
sb = live.get("sandbox") or {}
pool |= {e for e in sb.get("excludedCommands") or [] if isinstance(e, str)}
for group in ("filesystem", "network"):
    for val in (sb.get(group) or {}).values():
        if isinstance(val, list):
            pool |= {e for e in val if isinstance(e, str)}
ids = (sec.get("enforced") or {}).get("ruleIds") or []
print(" ".join(r for r in ids if r not in pool))' 2>/dev/null || echo "__ERROR__")"
  if [ -z "$stale_ids" ]; then
    check "every enforced.ruleIds entry is present in settings.json" 0
  else
    echo "  FAIL: security.json enforced.ruleIds names rules settings.json does not hold: $stale_ids"
    FAIL=$((FAIL + 1))
  fi
fi

# A mid-pattern * does not match an empty string, so Bash(anchor * --final*) sat in the deny
# list without stopping `anchor --final`. Every two-wildcard rule needs its zero-gap twin,
# or another rule that covers the collapsed command.
if [ -f .claude/settings.json ]; then
  gap_rules="$(python3 -c '
import fnmatch, json, re

def zero_gap(pat):
    for i, ch in enumerate(pat):
        if ch == "*" and 0 < i < len(pat) - 1:
            cand = re.sub(r" +", " ", pat[:i] + pat[i + 1:]).strip()
            if cand and cand != pat:
                yield cand

def probe(pat):
    p = pat[:-1] if pat.endswith("*") else pat
    return re.sub(r" +", " ", p.replace("*", "ZZZ")).strip()

perms = json.load(open(".claude/settings.json")).get("permissions") or {}
bad = []
for key in ("deny", "ask"):
    pats = [r[5:-1] for r in perms.get(key) or []
            if isinstance(r, str) and r.startswith("Bash(") and r.endswith(")")]
    have = set(pats)
    for pat in pats:
        if pat.count("*") < 2:
            continue
        for twin in zero_gap(pat):
            if twin in have:
                continue
            cmd = probe(twin)
            if any(fnmatch.fnmatchcase(cmd, o) for o in pats if o != pat):
                continue
            bad.append("%s: Bash(%s) needs Bash(%s)" % (key, pat, twin))
print("\n".join(sorted(set(bad))))' 2>/dev/null || echo "__ERROR__")"
  if [ -z "$gap_rules" ]; then
    check "Every two-wildcard Bash rule has a zero-gap twin" 0
  else
    echo "  FAIL: two-wildcard rules with no zero-gap twin (a mid-pattern * never matches empty):"
    printf '%s\n' "$gap_rules" | head -8 | sed 's/^/         /'
    FAIL=$((FAIL + 1))
  fi
fi

# Generator properties, checked in a throwaway copy so validate.sh never mutates the repo:
# applying a tier twice must be byte-identical, and relaxed -> high -> relaxed must come
# back to the original bytes. Either failing means a tier can be raised but never lowered.
if [ -f .claude/bin/firewall.sh ] && [ -f .claude/security.json ]; then
  fw_tmp="$(mktemp -d 2>/dev/null || true)"
  if [ -z "$fw_tmp" ] || [ ! -d "$fw_tmp" ]; then
    fw_tmp="${TMPDIR:-/tmp}/sak-validate-firewall.$$"
    mkdir -p "$fw_tmp" 2>/dev/null || fw_tmp=""
  fi
  if [ -z "$fw_tmp" ] || [ ! -d "$fw_tmp" ]; then
    echo "  SKIP: no writable temp dir for the firewall round-trip check"
    SKIP=$((SKIP + 1))
  else
    mkdir -p "$fw_tmp/.claude/bin"
    cp .claude/settings.json .claude/security.json "$fw_tmp/.claude/"
    cp .claude/bin/firewall.sh "$fw_tmp/.claude/bin/firewall.sh"
    fw_run() { (cd "$fw_tmp" && CLAUDE_PROJECT_DIR="$fw_tmp" bash .claude/bin/firewall.sh apply "$1" >/dev/null 2>&1); }
    if fw_run relaxed; then
      cp "$fw_tmp/.claude/settings.json" "$fw_tmp/once.json"
      fw_run relaxed
      if cmp -s "$fw_tmp/once.json" "$fw_tmp/.claude/settings.json"; then
        check "firewall.sh apply is idempotent (two applies are byte-identical)" 0
      else
        check "firewall.sh apply is idempotent (two applies are byte-identical)" 1
      fi
      fw_run high && fw_run relaxed
      if cmp -s "$fw_tmp/once.json" "$fw_tmp/.claude/settings.json"; then
        check "firewall.sh relaxed -> high -> relaxed restores the original bytes" 0
      else
        check "firewall.sh relaxed -> high -> relaxed restores the original bytes" 1
      fi
      # The committed settings.json has to be what the generator produces for the
      # declared tier. A rule added to it by hand looks right in the diff and passes
      # every check above, yet reaches no user: install.sh copies this file, so the
      # first apply adopts the rule into enforced.ruleIds and the next one deletes it.
      fw_tier="$(python3 -c "import json; print(json.load(open('.claude/security.json')).get('tier') or 'relaxed')" 2>/dev/null || echo relaxed)"
      if fw_run "$fw_tier" && cmp -s "$fw_tmp/.claude/settings.json" .claude/settings.json; then
        check "settings.json is what firewall.sh generates for the declared tier ($fw_tier)" 0
      else
        check "settings.json is what firewall.sh generates for the declared tier ($fw_tier) — run: bash .claude/bin/firewall.sh apply $fw_tier" 1
      fi
    else
      check "firewall.sh apply <tier> runs in a clean copy" 1
    fi
    rm -rf "$fw_tmp"
  fi
fi

# In user settings a `/`-anchored rule is resolved against the settings file's own
# directory, so `Read(/secrets/**)` documented for ~/.claude/settings.json means
# ~/.claude/secrets/**, not the project's. Anything the kit tells a user to paste there
# must use `~/` or `//`. (Project settings legitimately use `/` — that is the project root.)
echo "[User-scope snippets]"
user_anchored="$(python3 -c '
import glob, re
RULE = re.compile(r"\b(Read|Edit|Write|Bash)\((/(?!/)[^)]*)\)")
hits = []
files = ["README.md", "QUICK-START.md", "CLAUDE-solana.md"]
files += sorted(glob.glob("docs/*.md"))
files += sorted(glob.glob(".claude/commands/*.md")) + sorted(glob.glob(".claude/skills/*.md"))
for path in files:
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        continue
    user_scope = False
    for i, line in enumerate(lines):
        if re.search(r"~/\.claude/settings(\.local)?\.json|\$HOME/\.claude/settings", line):
            user_scope = True
        elif re.search(r"(?<!~)(?<!\$HOME)\B\.claude/settings\.json|^#{1,6} ", line) and "~/" not in line:
            user_scope = False
        if user_scope:
            for m in RULE.finditer(line):
                hits.append("%s:%d: %s(%s)" % (path, i + 1, m.group(1), m.group(2)))
print("\n".join(hits))' 2>/dev/null || echo "__ERROR__")"
if [ -z "$user_anchored" ]; then
  check "No /-anchored permission rule in a ~/.claude/settings.json snippet" 0
else
  echo "  FAIL: a /-anchored rule documented for user settings resolves under ~/.claude/, not the project:"
  printf '%s\n' "$user_anchored" | head -8 | sed 's/^/         /'
  FAIL=$((FAIL + 1))
fi
echo ""

# --- Hook commands ---
# Claude Code runs each hook with `sh -c`. A syntax error exits 2, which it treats as a
# block, so one typo would stop every Bash call or session start.
echo "[Hooks]"
hooks_ok=0
python3 - <<'PY' || hooks_ok=1
import json, subprocess, sys
bad = 0
for path in (".claude/settings.json", "plugin/hooks/hooks.json"):
    for event, entries in json.load(open(path)).get("hooks", {}).items():
        for entry in entries:
            for hook in entry.get("hooks", []):
                r = subprocess.run(["sh", "-n"], input=hook.get("command", ""), capture_output=True, text=True)
                if r.returncode:
                    bad += 1
                    print(f"  FAIL: {path} {event} hook: {r.stderr.strip()[:160]}")
sys.exit(1 if bad else 0)
PY
check "Hook commands in settings.json and plugin/hooks/hooks.json parse with sh -n" "$hooks_ok"
echo ""

# --- Rules frontmatter ---
# Claude Code reads only `paths:` from a rule. A rule without it (including one
# that uses `globs:`) loads into every session and every subagent.
echo "[Rules]"
eager_rules=0
while IFS= read -r f; do
  frontmatter=""
  if head -1 "$f" | grep -q "^---$"; then
    frontmatter="$(awk '/^---$/{c++;next} c==1{print}' "$f")"
  fi
  if ! echo "$frontmatter" | grep -q "^paths:"; then
    echo "  FAIL: $f has no paths: frontmatter, so it loads every session"
    FAIL=$((FAIL + 1))
    eager_rules=$((eager_rules + 1))
  fi
done < <(find .claude/rules -name '*.md' 2>/dev/null)
if [ "$eager_rules" -eq 0 ]; then
  check "No always-loaded rules (every rule is path-scoped with paths:)" 0
fi
echo ""

# --- Summary ---
TOTAL=$((PASS + FAIL))
echo "========================================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (of $((TOTAL + SKIP)) checks)"
if [ "$SKIP" -gt 0 ]; then
  echo "Note: $SKIP checks skipped because submodules aren't initialized."
  echo "      Run 'git submodule update --init --recursive' (or ./install.sh) to check them."
fi
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
