#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit — In-Place Update
# Fetches latest from upstream and applies updates.
# Safe: backs up CLAUDE.md, preserves .env, shows diff.
#
# Usage:
#   bash .claude/bin/update.sh              # from project root
#   bash .agents/bin/update.sh              # from project root (agents mode)
#   bash .claude/bin/update.sh --dry-run    # preview changes only
#
# Env: SOLANA_AI_KIT_UPSTREAM / SOLANA_AI_KIT_BRANCH override the source
# (legacy SOLANA_CLAUDE_UPSTREAM / SOLANA_CLAUDE_BRANCH still honored)

REPO_URL="${SOLANA_AI_KIT_UPSTREAM:-${SOLANA_CLAUDE_UPSTREAM:-https://github.com/solanabr/solana-ai-kit.git}}"
BRANCH="${SOLANA_AI_KIT_BRANCH:-${SOLANA_CLAUDE_BRANCH:-main}}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Auto-detect config dir from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_NAME="$(basename "$CONFIG_DIR")"
TARGET_DIR="$(cd "$CONFIG_DIR/.." && pwd)"

# Verify we're in a project with the config dir
if [ ! -d "$TARGET_DIR/$CONFIG_NAME" ]; then
  echo "Error: $CONFIG_NAME/ not found in $TARGET_DIR. Run from your project root."
  exit 1
fi

# Read current version
CURRENT_VERSION="unknown"
[ -f "$TARGET_DIR/$CONFIG_NAME/VERSION" ] && CURRENT_VERSION="$(awk '{print $NF}' "$TARGET_DIR/$CONFIG_NAME/VERSION")"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Fetch upstream (SOLANA_AI_KIT_LOCAL_SRC for local testing; legacy SOLANA_CLAUDE_LOCAL_SRC honored)
LOCAL_SRC="${SOLANA_AI_KIT_LOCAL_SRC:-${SOLANA_CLAUDE_LOCAL_SRC:-}}"
if [ -n "$LOCAL_SRC" ] && [ -d "$LOCAL_SRC/.claude" ]; then
  echo "Using local source: $LOCAL_SRC"
  mkdir -p "$TEMP_DIR/repo"
  cp -r "$LOCAL_SRC/.claude" "$TEMP_DIR/repo/.claude"
  [ -f "$LOCAL_SRC/CLAUDE-solana.md" ] && cp "$LOCAL_SRC/CLAUDE-solana.md" "$TEMP_DIR/repo/CLAUDE-solana.md"
  [ -f "$LOCAL_SRC/.mcp.json" ] && cp "$LOCAL_SRC/.mcp.json" "$TEMP_DIR/repo/.mcp.json"
  [ -f "$LOCAL_SRC/.env.example" ] && cp "$LOCAL_SRC/.env.example" "$TEMP_DIR/repo/.env.example"
  [ -f "$LOCAL_SRC/.gitmodules" ] && cp "$LOCAL_SRC/.gitmodules" "$TEMP_DIR/repo/.gitmodules"
else
  echo "Fetching latest from upstream..."
  git clone --recurse-submodules --depth 1 --branch "$BRANCH" "$REPO_URL" "$TEMP_DIR/repo" 2>&1 | tail -1 || true
fi

# Read new version
NEW_VERSION="unknown"
[ -f "$TEMP_DIR/repo/.claude/VERSION" ] && NEW_VERSION="$(awk '{print $NF}' "$TEMP_DIR/repo/.claude/VERSION")"

if [ "$CURRENT_VERSION" = "unknown" ]; then
  echo "Installing version tracking (first update)"
else
  echo "Updating v$CURRENT_VERSION → v$NEW_VERSION"
fi
echo ""
echo "Config directory: $CONFIG_NAME/"

# Track changes
CHANGES=""

# Preserved files — never overwrite these
# .env, settings.json, settings.local.json, .mcp.json, MEMORY.md, memory/, CLAUDE.local.md

# Directories to update (full update for both modes)
UPDATE_DIRS="agents skills rules commands bin"
echo "Updating: $UPDATE_DIRS"

for dir in $UPDATE_DIRS; do
  SRC="$TEMP_DIR/repo/.claude/$dir"
  DST="$TARGET_DIR/$CONFIG_NAME/$dir"
  if [ -d "$SRC" ]; then
    if [ "$DRY_RUN" = true ]; then
      if ! diff -rq "$SRC" "$DST" >/dev/null 2>&1; then
        CHANGES="$CHANGES  [would update] $CONFIG_NAME/$dir/\n"
      fi
    else
      if ! diff -rq "$SRC" "$DST" >/dev/null 2>&1; then
        CHANGES="$CHANGES  [updated] $CONFIG_NAME/$dir/\n"
      fi
      cp -r "$SRC" "$TARGET_DIR/$CONFIG_NAME/"
    fi
  fi
done

# NOTE: the loop above just overwrote bin/, i.e. this file. Bash reads a running
# script by byte offset, so an older update.sh carries on with the new code from
# here. Keep every byte above this comment unchanged; add new logic below it.

# hooks/ arrived after that frozen UPDATE_DIRS list, which cannot grow. Same
# semantics as the loop: overwrite with upstream, but into a pre-created
# directory so a symlinked hooks/ is followed and merged into, not replaced.
HOOKS_SRC="$TEMP_DIR/repo/.claude/hooks"
HOOKS_DST="$TARGET_DIR/$CONFIG_NAME/hooks"
if [ -d "$HOOKS_SRC" ]; then
  if ! diff -rq "$HOOKS_SRC" "$HOOKS_DST" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = true ]; then
      CHANGES="$CHANGES  [would update] $CONFIG_NAME/hooks/\n"
    else
      CHANGES="$CHANGES  [updated] $CONFIG_NAME/hooks/\n"
    fi
  fi
  if [ "$DRY_RUN" = false ]; then
    mkdir -p "$HOOKS_DST"
    cp -r "$HOOKS_SRC/." "$HOOKS_DST/"
  fi
fi

# The kit no longer ships rules/. Its old rule files used `globs:`, which Claude Code
# ignores, so they loaded into every session. Remove those copies; rules the user
# wrote are left alone.
for f in anchor.md dotnet.md pinocchio.md rust.md typescript.md; do
  OLD="$TARGET_DIR/$CONFIG_NAME/rules/$f"
  if [ -f "$OLD" ] && grep -q '^globs:' "$OLD"; then
    if [ "$DRY_RUN" = true ]; then
      CHANGES="$CHANGES  [would remove] $CONFIG_NAME/rules/$f (retired kit rule)\n"
    else
      rm "$OLD"
      CHANGES="$CHANGES  [removed] $CONFIG_NAME/rules/$f (retired kit rule)\n"
    fi
  fi
done
[ "$DRY_RUN" = true ] || rmdir "$TARGET_DIR/$CONFIG_NAME/rules" 2>/dev/null || true

# --agents installs: the kit ships .claude/ paths. Point what was just copied at
# .agents/ (same rewrite as install.sh). Left alone: ~/.claude/, the vendored
# ext/ repos, bin/, and lines that already name .agents/ (they handle both modes).
# Claude-Code-only files, not installed by --agents. /cleanup turns a fork of the
# kit repo into a project (docs/install.md "Using as a GitHub Template"); its paths
# describe the kit's own repo, so in an .agents/ project every step of it is false.
# Not shipping it beats rewriting it into something plausible but wrong.
# The firewall is the same case, for a sharper reason: nothing reads a permission
# block under .agents/. Codex reads AGENTS.md plus .agents/skills/ and takes its
# hooks from .codex/hooks.json; Cursor, Copilot, Gemini CLI and opencode read
# instructions only. A tier record and a generated rule block there would be dead
# weight that looks like protection, so --agents installs no firewall at all.
AGENTS_SKIP_FILES='commands/cleanup.md commands/firewall.md bin/firewall.sh security.json'
agents_paths() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && grep -q '\.claude/' "$f" || continue
    sed -E '/\.agents\//!{s#(^|[^[:alnum:]_./~-])\.claude/#\1.agents/#g;s#([$][{]CLAUDE_PROJECT_DIR:-[.][}])/\.claude/#\1/.agents/#g;}' \
      "$f" > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
  done
}
# Codex and opencode do not strip HTML comments, so the maintainer notes in
# CLAUDE-solana.md would reach the model as instructions. Strip them once here:
# the later diff/cp both read this file and would otherwise always disagree.
strip_md_comments() {
  awk '
    { line = $0; cr = ""
      if (sub(/\r$/, "", line)) cr = "\r"
      out = ""; blank = (line ~ /^[ \t]*$/)
      while (1) {
        if (inc) { p = index(line, "-->"); if (p == 0) { line = ""; break }
                   line = substr(line, p + 3); inc = 0 }
        else     { p = index(line, "<!--"); if (p == 0) { out = out line; break }
                   out = out substr(line, 1, p - 1); line = substr(line, p + 4); inc = 1 }
      }
      if (out ~ /[^ \t]/) { print out cr; prev_blank = 0; next }
      if (!blank) next
      if (prev_blank) next
      print cr; prev_blank = 1 }
    END { if (inc) {
            print "strip_md_comments: unterminated <!-- in " FILENAME > "/dev/stderr"
            exit 1 } }
  ' "$1" > "$1.tmp" && cat "$1.tmp" > "$1" && rm -f "$1.tmp"
}
INSTR_FILE="CLAUDE.md"
if [ "$CONFIG_NAME" = ".agents" ]; then
  INSTR_FILE="AGENTS.md"
  # The frozen copy loop above just wrote these. A dry run copies nothing, so there
  # only an older install's copy can be present, and it must stay.
  for f in $AGENTS_SKIP_FILES; do
    [ -f "$TARGET_DIR/$CONFIG_NAME/$f" ] || continue
    if [ "$DRY_RUN" = true ]; then
      CHANGES="$CHANGES  [would remove] $CONFIG_NAME/$f (Claude Code only)\n"
    else
      rm -f "$TARGET_DIR/$CONFIG_NAME/$f"
      CHANGES="$CHANGES  [removed] $CONFIG_NAME/$f (Claude Code only)\n"
    fi
  done
  strip_md_comments "$TEMP_DIR/repo/CLAUDE-solana.md"
  agents_paths "$TEMP_DIR/repo/CLAUDE-solana.md" "$TEMP_DIR/repo/.gitmodules"
  if [ "$DRY_RUN" = false ]; then
    while IFS= read -r rel; do agents_paths "$TARGET_DIR/$CONFIG_NAME/$rel"; done < <(
      cd "$TEMP_DIR/repo/.claude" && find agents commands skills hooks -path skills/ext -prune -o -type f -print 2>/dev/null
    )
    # Older --agents installs registered ext/ under .claude/ paths; drop those
    # stale entries unless a regular .claude/ install still uses them.
    if [ -f "$TARGET_DIR/.gitmodules" ] && [ ! -d "$TARGET_DIR/.claude/skills/ext" ]; then
      STALE="$(git config -f "$TARGET_DIR/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
        | awk '$2 ~ /^\.claude\/skills\/ext\// { sub(/\.path$/, "", $1); print $1 }' || true)"
      for section in $STALE; do git config -f "$TARGET_DIR/.gitmodules" --remove-section "$section"; done
      if [ -n "$STALE" ]; then
        CHANGES="$CHANGES  [migrated] .gitmodules ext/ entries now point at .agents/skills/ext/\n"
      fi
    fi
  fi
fi

# ext/ skills are vendored copies: drop submodule gitfiles copied from the fetched
# clone. Keep only a gitfile whose gitdir lives inside this project — that one is a
# real submodule the user checked out. "Does the gitdir exist?" is not enough: with
# SOLANA_AI_KIT_LOCAL_SRC the copied path still resolves, into the kit checkout.
if [ "$DRY_RUN" = false ] && [ -d "$TARGET_DIR/$CONFIG_NAME/skills/ext" ]; then
  TARGET_ABS="$(cd "$TARGET_DIR" && pwd -P)"
  # A real submodule's gitdir lives under the target's git common dir, which is
  # NOT inside the target when the project is a git worktree or is itself a
  # submodule. Accept both, or reinstalling into a worktree deletes live gitfiles.
  GIT_COMMON="$(cd "$TARGET_DIR" && git rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$GIT_COMMON" ] && GIT_COMMON="$(cd "$TARGET_DIR" && cd "$GIT_COMMON" 2>/dev/null && pwd -P || true)"
  while IFS= read -r gitfile; do
    gitdir="$(sed -n 's/^gitdir: //p' "$gitfile" | tr -d '\r')"
    gitdir_abs=""
    [ -n "$gitdir" ] && gitdir_abs="$(cd "$(dirname "$gitfile")" && cd "$gitdir" 2>/dev/null && pwd -P || true)"
    case "$gitdir_abs" in
      "$TARGET_ABS"/*) ;;
      *) if [ -n "$GIT_COMMON" ] && [ "${gitdir_abs#"$GIT_COMMON"/}" != "$gitdir_abs" ]; then :; else rm -f "$gitfile"; fi ;;
    esac
  done < <(find "$TARGET_DIR/$CONFIG_NAME/skills/ext" -name .git -type f)
fi

# A pack's own submodules are pinned by that pack's author, not by the kit. install.sh
# does not fetch them, so a project should not receive them here either: the clone at the
# top of this file uses --recurse-submodules and that line is inside the frozen region,
# so the pruning happens after the copy instead of before the fetch. To opt in to one,
# clone it yourself at the commit the registry records.
#
# The list is derived from each pack's own submodule file, which ships inside the pack and
# is that author's own statement of what it vendors. That covers packs the registry's
# hand-kept "vendored" record misses and a pack that gains a submodule upstream, which
# makes the record a review artifact rather than the thing standing between a user and a
# nested third-party tree. The record is still read, as a second source and a backstop,
# but with python3: a "vendored" object spanning several lines is invisible to a
# line-oriented parser, and that is how 16 of the 18 recorded paths went unpruned. The
# per-pack pass needs no python3, so the primary list survives its absence.
if [ "$DRY_RUN" = false ] && [ -d "$TARGET_DIR/$CONFIG_NAME/skills/ext" ]; then
  EXT_DIR="$TARGET_DIR/$CONFIG_NAME/skills/ext"
  REG_FILE="$TARGET_DIR/$CONFIG_NAME/skills/skill-registry.json"
  PRUNE_LIST="$TEMP_DIR/vendored-prune.txt"
  {
    for pack_modules in "$EXT_DIR"/*/.gitmodules; do
      [ -f "$pack_modules" ] || continue
      pack_dir="$(basename "$(dirname "$pack_modules")")"
      sed -n 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//p' "$pack_modules" | tr -d '\r' \
        | while IFS= read -r rel; do
            [ -n "$rel" ] && printf '%s/%s\n' "$pack_dir" "$rel"
          done
    done
    if [ -f "$REG_FILE" ] && command -v python3 >/dev/null 2>&1; then
      python3 - "$REG_FILE" <<'PY' || true
import json, os, sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        entries = json.load(f).get("entries") or []
except (OSError, ValueError):
    sys.exit(0)
for entry in entries:
    if not isinstance(entry, dict):
        continue
    vendored = entry.get("vendored")
    if not isinstance(vendored, dict):
        continue
    path = entry.get("path") or ""
    pack = os.path.basename(path) if "/skills/ext/" in path else (entry.get("id") or "")
    for rel in vendored:
        if pack and rel:
            print("%s/%s" % (pack, rel))
PY
    fi
  } | sort -u > "$PRUNE_LIST" || true
  PRUNED=0
  while IFS= read -r nested; do
    # pack/subpath only, and nothing that could climb out of ext/
    case "$nested" in */*) ;; *) continue ;; esac
    case "$nested" in /*) continue ;; esac
    case "/$nested/" in */../*) continue ;; esac
    [ -e "$EXT_DIR/$nested" ] || continue
    rm -rf "${EXT_DIR:?}/${nested:?}"
    PRUNED=$((PRUNED + 1))
  done < "$PRUNE_LIST"
  if [ "$PRUNED" -gt 0 ]; then
    CHANGES="$CHANGES  [pruned] $PRUNED nested third-party tree(s) under $CONFIG_NAME/skills/ext/ — a pack's own submodules are not part of what the kit pins\n"
  fi
fi

# The packs just copied should be at the commits the registry records. The copy has
# already happened by here, so this reports rather than blocks — a fresh install.sh run
# refuses the same mismatch outright.
if [ "$DRY_RUN" = false ] && [ -f "$TEMP_DIR/repo/.claude/bin/skills.sh" ]; then
  PIN_SRC="$TEMP_DIR/repo"
  [ -n "$LOCAL_SRC" ] && PIN_SRC="$LOCAL_SRC"
  if ! PIN_REPORT="$(bash "$TEMP_DIR/repo/.claude/bin/skills.sh" pins "$PIN_SRC" 2>&1)"; then
    echo "Note: a skill pack is not at the commit skill-registry.json records for it:"
    printf '%s\n' "$PIN_REPORT" | sed 's/^/  /'
  fi
fi

# Merge .gitmodules (don't overwrite — user may have their own submodules)
if [ -f "$TEMP_DIR/repo/.gitmodules" ]; then
  if [ ! -f "$TARGET_DIR/.gitmodules" ]; then
    if ! diff -q "$TEMP_DIR/repo/.gitmodules" "$TARGET_DIR/.gitmodules" >/dev/null 2>&1; then
      CHANGES="$CHANGES  [updated] .gitmodules\n"
    fi
    if [ "$DRY_RUN" = false ]; then
      cp "$TEMP_DIR/repo/.gitmodules" "$TARGET_DIR/.gitmodules"
    fi
  else
    # Append submodule entries that don't already exist in target. One pass with a
    # flag: a nested read loop would swallow the next [submodule] header.
    ADDED_SUBMODS=""
    COPYING=false
    while IFS= read -r line; do
      if [[ "$line" =~ ^\[submodule\ \"(.+)\"\] ]]; then
        COPYING=false
        submod="${BASH_REMATCH[1]}"
        if ! grep -qF "[submodule \"$submod\"]" "$TARGET_DIR/.gitmodules"; then
          ADDED_SUBMODS="$ADDED_SUBMODS $submod"
          COPYING=true
          if [ "$DRY_RUN" = false ]; then
            printf '\n%s\n' "$line" >> "$TARGET_DIR/.gitmodules"
          fi
        fi
      elif [ "$COPYING" = true ] && [ -n "$line" ] && [ "$DRY_RUN" = false ]; then
        printf '%s\n' "$line" >> "$TARGET_DIR/.gitmodules"
      fi
    done < "$TEMP_DIR/repo/.gitmodules"
    if [ -n "$ADDED_SUBMODS" ]; then
      CHANGES="$CHANGES  [merged] .gitmodules (added:$ADDED_SUBMODS)\n"
    fi
  fi
fi

# Skill packs: the copy loop brought every ext/ pack. Keep the core packs and the
# extensions this project installed (skills/extensions.txt); drop the rest.
if [ "$DRY_RUN" = false ] && [ -f "$SCRIPT_DIR/skills.sh" ]; then
  bash "$SCRIPT_DIR/skills.sh" prune
fi

# Update VERSION
if [ -f "$TEMP_DIR/repo/.claude/VERSION" ]; then
  if [ "$DRY_RUN" = false ]; then
    cp "$TEMP_DIR/repo/.claude/VERSION" "$TARGET_DIR/$CONFIG_NAME/VERSION"
  fi
  CHANGES="$CHANGES  [updated] $CONFIG_NAME/VERSION → $NEW_VERSION\n"
fi

# Retired kit defaults. This script never overwrites settings.json or .mcp.json, so
# installs from kit <= 2.1.0 keep the overrides the kit no longer sets. Remove each one
# only while it still holds the kit's own value; anything the user changed stays.
case "$CURRENT_VERSION" in
  unknown|1.*|2.0.*|2.1.0)
    if command -v python3 >/dev/null 2>&1; then
      cat > "$TEMP_DIR/retire_kit_defaults.py" <<'PY'
import json, sys

dry_run, target, config = sys.argv[1] == "true", sys.argv[2], sys.argv[3]
OLD_ENV = {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": ["1"],
    "CLAUDE_CODE_COORDINATOR_MODE": ["1"],
    "CLAUDE_CODE_EFFORT_LEVEL": ["max", "auto"],
    "BASH_MAX_OUTPUT_LENGTH": ["30000"],
    "MAX_MCP_OUTPUT_TOKENS": ["25000"],
}
OLD_KEYS = {
    "enableAllProjectMcpServers": True,
    "defaultMode": "default",
    "modelDefaults": {"agent": "opus", "command": "sonnet"},
}
OLD_PLUGINS = ["rust-analyzer-lsp", "typescript-lsp", "csharp-lsp"]
# context-mode is deliberately absent: it is a default server again, so stripping it here
# would delete it from .mcp.json on the same run that installed it.
OLD_SERVERS = {
    "playwright": {"command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless"]},
    "memsearch": {"command": "npx", "args": ["-y", "memsearch-mcp@latest"]},
    "surfpool": {"command": "surfpool", "args": ["mcp"]},
}


def same(a, b):  # exact match: 1 does not count as true
    return type(a) is type(b) and a == b


def strip_settings(d):
    gone = []
    env = d.get("env")
    if isinstance(env, dict):
        for key, olds in OLD_ENV.items():
            if any(same(env.get(key), v) for v in olds):
                del env[key]
                gone.append("env." + key)
        if gone and not env:
            del d["env"]
    for key, old in OLD_KEYS.items():
        if key in d and same(d[key], old):
            del d[key]
            gone.append(key)
    plugins = d.get("enabledPlugins")
    if isinstance(plugins, dict):
        before = len(gone)
        for name in OLD_PLUGINS:
            if plugins.get(name + "@claude-plugins-official") is True:
                del plugins[name + "@claude-plugins-official"]
                gone.append("enabledPlugins." + name)
        if len(gone) > before and not plugins:
            del d["enabledPlugins"]
    return gone


def strip_servers(d):
    servers = d.get("mcpServers")
    if not isinstance(servers, dict):
        return []
    gone = [name for name, old in OLD_SERVERS.items() if same(servers.get(name), old)]
    for name in gone:
        del servers[name]
    return ["mcpServers." + name for name in gone]


removed = False
for rel, strip in ((config + "/settings.json", strip_settings), (".mcp.json", strip_servers)):
    path = target + "/" + rel
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        continue  # missing, or not plain JSON: leave it alone
    gone = strip(data) if isinstance(data, dict) else []
    if not gone:
        continue
    if not dry_run:
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        except OSError as e:
            print("  [skipped] %s: could not write (%s)" % (rel, e.strerror))
            continue
    removed = True
    print("  [%s] %s: %s" % ("would remove" if dry_run else "removed", rel, ", ".join(gone)))
if removed:
    print("  [notice] Retired kit defaults. To keep one, set it in %s/settings.local.json;"
          " re-add an MCP server with: claude mcp add <name> -- <command>" % config)
PY
      RETIRED="$(python3 "$TEMP_DIR/retire_kit_defaults.py" "$DRY_RUN" "$TARGET_DIR" "$CONFIG_NAME")" || RETIRED=""
      [ -z "$RETIRED" ] || CHANGES="$CHANGES$RETIRED\n"
    else
      CHANGES="$CHANGES  [skipped] retired kit defaults left in place (python3 not found)\n"
    fi
    ;;
esac

# ── Agentic firewall: adopt a tier on installs made before it existed ───────
# Gated on the file, not a version: security.json is what records the tier, and
# install.sh writes one for every new install, so its absence means a pre-firewall
# install. Like retire_kit_defaults.py above, this mutates a protected file in place
# — the whole-file copy is the thing update.sh never does. Two rules keep it safe:
#
#   * The tier block only ever replaces permissions the kit itself wrote. If
#     permissions or sandbox differ from every settings.json the kit shipped in
#     2.x, that is a policy someone tuned: adopt `off`, keep their version, say so.
#     Whole-block comparison is why no per-rule conflict list is needed — a user
#     who deleted one kit rule lands in that branch and nothing is rewritten.
#   * bin/firewall.sh is the only writer of the rule block, and the copy loop above
#     just updated it. So this writes security.json and nothing else: it resolves
#     the tier, deliberately records no `enforced` block, and hands the generation
#     to `firewall.sh apply`. With no enforced.ruleSetVersion to go on, that apply
#     takes its bootstrap path and removes every rule the kit could have written
#     before the record existed — the subtraction, from the one component that
#     knows the legacy set. Duplicating it here would be a second writer and a
#     second copy of the rule corpus to keep in step.
#
# --agents installs get no firewall at all (see AGENTS_SKIP_FILES above): nothing
# reads a permission block under .agents/, so there is no tier to migrate there.
if [ "$CONFIG_NAME" != ".claude" ]; then
  :
elif command -v python3 >/dev/null 2>&1 && [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
  cat > "$TEMP_DIR/firewall_migrate.py" <<'PY'
import hashlib, json, os, sys

dry_run = sys.argv[1] == "true"
target, config, upstream, temp = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
can_apply = sys.argv[6] == "true"

CONFIG_PATH = os.path.join(target, config)
SETTINGS = os.path.join(CONFIG_PATH, "settings.json")
SECURITY = os.path.join(CONFIG_PATH, "security.json")

# Hash of the permissions + sandbox block of every settings.json the kit shipped in
# 2.x before the firewall. A match means the policy is still the kit's own.
# Regenerate one with:
#   git show <ref>:.claude/settings.json | python3 -c 'import hashlib,json,sys;d=json.load(sys.stdin);print(hashlib.sha256(json.dumps({"permissions":d.get("permissions"),"sandbox":d.get("sandbox")},sort_keys=True,separators=(",",":"),ensure_ascii=False).replace(".agents/",".claude/").encode()).hexdigest()[:16])'
BASELINES = {
    "7788a4944b97d723": "2.0.0",
    "86b53470f39214d1": "2.0.1",
    "841633698e42d1db": "2.0.2 and 2.1.0",
    "036fd95c5bd945a8": "2.1.0 main",
}


def report(tag, msg):
    print("  [%s] %s" % (tag, msg))


def give_up(msg):
    report("skipped", "firewall tier: " + msg)
    sys.exit(0)


def block_hash(d):
    s = json.dumps({"permissions": d.get("permissions"), "sandbox": d.get("sandbox")},
                   sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    # --agents installs have .claude/ rewritten in their rules; compare the shipped form.
    return hashlib.sha256(s.replace(".agents/", ".claude/").encode("utf-8")).hexdigest()[:16]


if os.path.exists(SECURITY):
    sys.exit(0)  # tier already recorded; /firewall owns it from here
if os.path.islink(CONFIG_PATH) or os.path.islink(SETTINGS):
    give_up("%s/ or its settings.json is a symlink; left alone" % config)

settings = None
if os.path.exists(SETTINGS):
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            settings = json.load(f)
    except (OSError, ValueError):
        give_up("%s/settings.json is not plain JSON; left alone" % config)
    if not isinstance(settings, dict):
        give_up("%s/settings.json is not a JSON object; left alone" % config)

found = block_hash(settings) if settings is not None else ""
pristine = settings is None or found in BASELINES
tier = "relaxed" if pristine else "off"

# Seed from the upstream file so the tier documentation lands with it. Its `enforced`
# record describes the kit's own repo, not this install, and a record carrying a
# ruleSetVersion would tell firewall.sh to subtract rules that were never here while
# leaving the legacy ones behind. Drop it: "never applied" is the truth, and it is
# what makes the next apply remove the legacy set.
doc = {}
try:
    with open(upstream, encoding="utf-8") as f:
        base = json.load(f)
    if isinstance(base, dict):
        doc = base
except (OSError, ValueError):
    pass
doc.pop("enforced", None)
doc["tier"] = tier
doc["_migrated"] = "tier adopted by update.sh for a pre-firewall install"

verb = "would set" if dry_run else "set"
if pristine:
    report(verb, "%s/security.json: tier %s on a pre-firewall install" % (config, tier))
    if can_apply:
        # Only the dry run reports settings.json from here. In a real run the caller
        # reports what firewall.sh actually wrote, so a failed apply cannot leave a
        # "[set]" line standing over a file nothing touched.
        if dry_run:
            report(verb, "%s/settings.json: %s firewall rules, replacing the kit's own" % (config, tier))
    else:
        report("notice", "firewall rules not generated: %s/bin/firewall.sh is missing."
                         " Run /firewall %s once it is there." % (config, tier))
else:
    report(verb, "%s/security.json: tier off (permissions were tuned here)" % config)
    report("notice", "%s/settings.json carries permission rules the kit did not write, so"
                     " the firewall stays off and your rules are untouched."
                     " Run /firewall relaxed to adopt the kit set." % config)

if not dry_run:
    tmp = SECURITY + ".firewall.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, SECURITY)  # atomic: same directory
    if pristine and can_apply:
        with open(os.path.join(temp, "firewall-apply"), "w", encoding="utf-8") as f:
            f.write(tier)
PY
  # firewall.sh generates the rules; without it only the tier is recorded, and the
  # kit's own rules stay exactly where they are.
  FW_APPLY=false
  FW_SH="$TARGET_DIR/$CONFIG_NAME/bin/firewall.sh"
  if [ -f "$FW_SH" ]; then
    FW_APPLY=true
  fi
  MIGRATED="$(python3 "$TEMP_DIR/firewall_migrate.py" "$DRY_RUN" "$TARGET_DIR" "$CONFIG_NAME" \
    "$TEMP_DIR/repo/.claude/security.json" "$TEMP_DIR" "$FW_APPLY")" || MIGRATED=""
  [ -z "$MIGRATED" ] || CHANGES="$CHANGES$MIGRATED\n"
  if [ -f "$TEMP_DIR/firewall-apply" ]; then
    FW_TIER="$(cat "$TEMP_DIR/firewall-apply")"
    # Contract: `firewall.sh apply [<tier>]`, resolving its own paths from bin/.
    # The tier is recorded either way, so the bare form is equivalent.
    if (bash "$FW_SH" apply "$FW_TIER" >/dev/null 2>&1) || (bash "$FW_SH" apply >/dev/null 2>&1); then
      CHANGES="$CHANGES  [set] $CONFIG_NAME/settings.json: $FW_TIER rules generated by firewall.sh\n"
    else
      # Nothing was written here, so settings.json still holds the policy it had.
      CHANGES="$CHANGES  [skipped] firewall rules: firewall.sh apply failed, settings.json unchanged. Run /firewall $FW_TIER\n"
    fi
  fi
elif [ ! -f "$TARGET_DIR/$CONFIG_NAME/security.json" ]; then
  CHANGES="$CHANGES  [skipped] firewall tier left unset (python3 or a writable temp dir not found)\n"
fi

# ── MCP gating: reach the two things an existing install cannot get otherwise ──
#
# The hooks/ copy above already delivered the guard scripts, and `firewall.sh apply`
# owns the permission block. Neither covers these two, so both need a migration here:
#
#   1. The PreToolUse matcher lives in settings.json under `hooks`, which this script
#      never overwrites and firewall.sh never manages. An install that keeps matcher
#      "Bash" has the new MCP-aware guards on disk and nothing routing MCP calls into
#      them -- the worst of the three states, because it looks configured.
#   2. An install that already has a security.json is skipped by firewall_migrate.py
#      above (correctly -- /firewall owns the tier from then on), so a change to the
#      generated corpus never lands. enforced.ruleSetVersion is the record of which
#      corpus was written; when it is behind the shipped one, re-apply the declared
#      tier. That is the general mechanism, not an MCP special case.
#
# Both are gated on content rather than a version window, so they are idempotent and a
# user who edited either part is left alone.
#
# --agents installs are skipped for the same reason the tier migration skips them:
# nothing under .agents/ reads a settings.json, so a matcher or a rule block there would
# be weight that looks like protection. Codex takes its hooks from .codex/hooks.json.
MCP_MATCHER='Bash|mcp__context-mode__.*'
if [ "$CONFIG_NAME" != ".claude" ]; then
  :
elif command -v python3 >/dev/null 2>&1 && [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
  cat > "$TEMP_DIR/mcp_matcher.py" <<'PY'
import json, os, sys

dry_run, target, config, matcher = sys.argv[1] == "true", sys.argv[2], sys.argv[3], sys.argv[4]
SETTINGS = os.path.join(target, config, "settings.json")

# The three guards the kit registers. An entry is rewritten only when its command names
# one of them, so a Bash hook the user added keeps its own narrower matcher.
GUARDS = ("secrets-guard.sh", "onchain-guard.sh", "egress-guard.sh")

if os.path.islink(SETTINGS):
    sys.exit(0)
try:
    with open(SETTINGS, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    sys.exit(0)
entries = hooks.get("PreToolUse")
if not isinstance(entries, list):
    sys.exit(0)

changed = 0
for entry in entries:
    if not isinstance(entry, dict) or entry.get("matcher") != "Bash":
        continue
    cmds = entry.get("hooks")
    if not isinstance(cmds, list):
        continue
    if not any(
        isinstance(h, dict) and any(g in (h.get("command") or "") for g in GUARDS)
        for h in cmds
    ):
        continue
    entry["matcher"] = matcher
    changed += 1

if not changed:
    sys.exit(0)
if not dry_run:
    tmp = SETTINGS + ".mcp.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        os.replace(tmp, SETTINGS)
    except OSError as e:
        print("  [skipped] %s/settings.json: could not write (%s)" % (config, e.strerror))
        sys.exit(0)
print("  [%s] %s/settings.json: %d PreToolUse matcher(s) now also match context-mode's"
      " MCP tools, so the secrets, on-chain and egress guards see ctx_execute payloads"
      % ("would update" if dry_run else "updated", config, changed))
PY
  MCPM="$(python3 "$TEMP_DIR/mcp_matcher.py" "$DRY_RUN" "$TARGET_DIR" "$CONFIG_NAME" "$MCP_MATCHER")" || MCPM=""
  [ -z "$MCPM" ] || CHANGES="$CHANGES$MCPM\n"

  # Rule-set catch-up. Reads the shipped version out of the firewall.sh just copied in,
  # so there is one source for it and no literal here to drift.
  #
  # The mechanism is version-generic, so a bump needs no edit here. Worth naming once:
  # `firewall.sh apply` subtracts exactly the strings in enforced.ruleIds before writing
  # the new block, so a bump that DROPS a rule works the same way as one that adds — and
  # the hook halves of a bump do not come through here at all. They arrive with the
  # hooks/ copy above, which is why a hook gate reaches an install whose ruleSetVersion
  # is already current (rule set 5 shipped four of those).
  #
  # Rule set 6 is entirely in the corpus, so this catch-up is the ONLY route by which it
  # reaches an install that already has a security.json: `gh repo delete` and
  # `git config alias.*` denied at every tier, and Playwright's executors denied by name
  # at Medium and High (`browser_evaluate` at High only). Purely additive, like v5's
  # Bash half, so the re-apply adds rules and removes none.
  FW_SH="$TARGET_DIR/$CONFIG_NAME/bin/firewall.sh"
  SEC_JSON="$TARGET_DIR/$CONFIG_NAME/security.json"
  if [ -f "$FW_SH" ] && [ -f "$SEC_JSON" ]; then
    WANT_RS="$(awk -F= '/^RULE_SET_VERSION[[:space:]]*=/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$FW_SH" 2>/dev/null)"
    HAVE_RS="$(awk '/"ruleSetVersion"[[:space:]]*:/{gsub(/[^0-9]/,""); print; exit}' "$SEC_JSON" 2>/dev/null)"
    DECL_TIER="$(awk '/"tier"[[:space:]]*:/{t=$0; sub(/.*"tier"[^"]*"/,"",t); sub(/".*/,"",t); print t; exit}' "$SEC_JSON" 2>/dev/null)"
    if [ -n "$WANT_RS" ] && [ -n "$HAVE_RS" ] && [ "$HAVE_RS" -lt "$WANT_RS" ] 2>/dev/null; then
      if [ "$DRY_RUN" = true ]; then
        CHANGES="$CHANGES  [would update] $CONFIG_NAME/settings.json: firewall rule set v$HAVE_RS -> v$WANT_RS (re-applying ${DECL_TIER:-the declared tier})\n"
      elif bash "$FW_SH" apply >/dev/null 2>&1; then
        CHANGES="$CHANGES  [updated] $CONFIG_NAME/settings.json: firewall rule set v$HAVE_RS -> v$WANT_RS (${DECL_TIER:-declared tier} re-applied)\n"
      else
        CHANGES="$CHANGES  [skipped] firewall rule set still v$HAVE_RS: firewall.sh apply failed, settings.json unchanged. Run /firewall ${DECL_TIER:-relaxed}\n"
      fi
    fi
  fi

  # ── Kit hooks: the enforcement an existing install could not otherwise get ──
  #
  # install.sh copies settings.json only when absent, and nothing above rewrites the
  # `hooks` block: the matcher patch edits an entry that is already there, and
  # firewall.sh owns permissions and sandbox and nothing else. So a guard the kit added
  # after a project was installed has its script on disk — the hooks/ copy near the top
  # delivers that — and no line in settings.json running it. That is issue #91, and it
  # is the structural reason a correction can land upstream and reach nobody.
  #
  # What this does: append a kit hook entry the project does not already run. Never
  # rewrite, reorder or remove one — an entry the user wrote, or edited, is theirs, and
  # an entry naming a kit script is taken as already handled whatever its matcher or
  # shape. "A kit hook" means the command names a file the kit ships in hooks/, so a
  # guard added later is carried over by this same code with no edit here; the SessionStart
  # banner names no such file and is deliberately left out, being cosmetic and having no
  # identity stable enough to avoid appending a second copy of it.
  #
  # Gate: HOOK_SET_VERSION below, bumped when the kit's hook set changes, compared with
  # what the last run recorded — the same shape as the rule-set catch-up above. It is
  # paired with a fingerprint of the shipped hooks block so a forgotten bump is caught
  # too, because a missed bump here reproduces exactly the defect this fixes. Both are
  # recorded in security.json, which firewall.sh carries through untouched. The work is
  # also idempotent on content alone: a second run finds every script present and
  # appends nothing, so a lost record costs a no-op, not a duplicate.
  # 1 -> 2: egress-guard grew the GITEXEC pass (git config keys that make git run a
  # command later). The guard SCRIPT reaches every install through the hooks/ copy near
  # the top of this file regardless of this number — the bump forces one more
  # registration pass, which matters for a project whose settings.json is missing a kit
  # guard entry, since the fingerprint beside this gate would otherwise match and skip.
  HOOK_SET_VERSION=2
  cat > "$TEMP_DIR/kit_hooks.py" <<'PY'
import hashlib, json, os, sys

dry_run = sys.argv[1] == "true"
target, config, upstream, security_path = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
want_version = int(sys.argv[6])

SETTINGS = os.path.join(target, config, "settings.json")


def report(tag, msg):
    print("  [%s] %s" % (tag, msg))


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    tmp = path + ".hooks.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)  # atomic: same directory


upstream_settings = load(upstream)
if not isinstance(upstream_settings, dict):
    sys.exit(0)
shipped = upstream_settings.get("hooks")
if not isinstance(shipped, dict) or not shipped:
    sys.exit(0)

fingerprint = hashlib.sha256(
    json.dumps(shipped, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
).hexdigest()[:16]

security = load(security_path)
if not isinstance(security, dict):
    security = None
have_version, have_fingerprint = 0, ""
if security is not None:
    try:
        have_version = int(security.get("hookSetVersion") or 0)
    except (TypeError, ValueError):
        have_version = 0
    have_fingerprint = security.get("hookSetFingerprint") or ""
if have_version >= want_version and have_fingerprint == fingerprint:
    sys.exit(0)

# The kit's own hook scripts, read from the hooks/ directory just copied in rather than
# listed here, so this never drifts from what ships.
try:
    kit_scripts = set(
        name for name in os.listdir(os.path.join(os.path.dirname(upstream), "hooks"))
        if name.endswith((".sh", ".awk", ".py"))
    )
except OSError:
    kit_scripts = set()
if not kit_scripts:
    sys.exit(0)


def scripts_of(entry):
    """Kit scripts an entry's commands name. Empty means it is not a kit hook."""
    found = set()
    if isinstance(entry, dict):
        for hook in entry.get("hooks") or []:
            if isinstance(hook, dict):
                command = hook.get("command") or ""
                found |= set(name for name in kit_scripts if name in command)
    return found


if os.path.islink(SETTINGS):
    sys.exit(0)
settings = load(SETTINGS)
if settings is None:
    report("skipped", "%s/settings.json is missing or not plain JSON, so the kit's"
                      " PreToolUse guards are not registered in this project. Re-run"
                      " install.sh here, or copy the hooks block from the kit." % config)
    sys.exit(0)
if not isinstance(settings, dict):
    sys.exit(0)

hooks = settings.get("hooks")
if hooks is None:
    hooks = {}
elif not isinstance(hooks, dict):
    sys.exit(0)

added = []
for event, shipped_entries in shipped.items():
    if not isinstance(shipped_entries, list):
        continue
    live = hooks.get(event)
    if live is not None and not isinstance(live, list):
        continue
    present = set()
    for entry in live or []:
        present |= scripts_of(entry)
    for entry in shipped_entries:
        wanted = scripts_of(entry)
        if not wanted or wanted & present:
            continue  # not a kit hook, or this project already runs it
        if live is None:
            live = []
            hooks[event] = live
        live.append(json.loads(json.dumps(entry)))
        present |= wanted
        added.extend("%s/%s" % (event, name) for name in sorted(wanted))

if added and not dry_run:
    settings["hooks"] = hooks
    try:
        write_json(SETTINGS, settings)
    except OSError as exc:
        report("skipped", "%s/settings.json: could not write (%s)" % (config, exc.strerror))
        sys.exit(0)
if added:
    report("would register" if dry_run else "registered",
           "%s/settings.json: %d kit hook(s) an older install never got — %s"
           % (config, len(added), ", ".join(added)))

# The rest of what the kit puts in settings.json still reaches fresh installs only:
# enabling a plugin fetches and runs a third-party binary, which is the user's call and
# not something an update should make for them. Say so rather than let the absence read
# as a choice already made.
pending = [
    key for key in ("extraKnownMarketplaces", "enabledPlugins")
    if isinstance(upstream_settings.get(key), dict) and not settings.get(key)
]
if pending:
    report("notice", "%s/settings.json has no %s: the kit's security plugin is not"
                     " enabled here. Add it with /plugin, or copy those keys from the"
                     " kit — an update will not enable a plugin for you."
                     % (config, " or ".join(pending)))

if dry_run:
    sys.exit(0)
if security is None:
    sys.exit(0)  # no record to write; the content check keeps the next run a no-op
security["hookSetVersion"] = want_version
security["hookSetFingerprint"] = fingerprint
try:
    write_json(security_path, security)
except OSError:
    pass  # the merge already happened; re-running it costs nothing
PY
  KIT_HOOKS="$(python3 "$TEMP_DIR/kit_hooks.py" "$DRY_RUN" "$TARGET_DIR" "$CONFIG_NAME" \
    "$TEMP_DIR/repo/.claude/settings.json" "$TARGET_DIR/$CONFIG_NAME/security.json" \
    "$HOOK_SET_VERSION")" || KIT_HOOKS=""
  [ -z "$KIT_HOOKS" ] || CHANGES="$CHANGES$KIT_HOOKS\n"
fi

# CHANGELOG.md stays in source repo — not shipped to user projects

# Merge .env.example — append new vars without overwriting user edits
# shellcheck source=_env_merge.sh
source "$SCRIPT_DIR/_env_merge.sh"
if [ -f "$TEMP_DIR/repo/.env.example" ]; then
  if [ "$DRY_RUN" = true ]; then
    # Check if there would be new vars
    if [ -f "$TARGET_DIR/.env.example" ]; then
      local_keys=$(grep -oE '^[A-Z_][A-Z0-9_]*=' "$TARGET_DIR/.env.example" 2>/dev/null || true)
      new_keys=""
      while IFS= read -r line; do
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
          key="${BASH_REMATCH[1]}"
          if ! echo "$local_keys" | grep -q "^${key}=$"; then
            new_keys="$new_keys $key"
          fi
        fi
      done < "$TEMP_DIR/repo/.env.example"
      if [ -n "$new_keys" ]; then
        CHANGES="$CHANGES  [would add] New env vars in .env.example:$new_keys\n"
      fi
    else
      CHANGES="$CHANGES  [would create] .env.example\n"
    fi
  else
    merge_env_file "$TEMP_DIR/repo/.env.example" "$TARGET_DIR/.env.example"
    if [ -f "$TARGET_DIR/.env" ]; then
      merge_env_file "$TEMP_DIR/repo/.env.example" "$TARGET_DIR/.env"
    fi
    CHANGES="$CHANGES  [merged] .env.example (new vars appended)\n"
  fi
fi

# Instruction file (CLAUDE.md, or AGENTS.md for --agents) — don't overwrite,
# offer the upstream version for manual merge
if [ -f "$TEMP_DIR/repo/CLAUDE-solana.md" ]; then
  if [ -f "$TARGET_DIR/$INSTR_FILE" ]; then
    if ! diff -q "$TEMP_DIR/repo/CLAUDE-solana.md" "$TARGET_DIR/$INSTR_FILE" >/dev/null 2>&1; then
      if [ "$DRY_RUN" = false ]; then
        cp "$TEMP_DIR/repo/CLAUDE-solana.md" "$TARGET_DIR/$INSTR_FILE.upstream"
      fi
      CHANGES="$CHANGES  [notice] New upstream $INSTR_FILE available at $INSTR_FILE.upstream — review and merge manually\n"
    fi
  else
    if [ "$DRY_RUN" = false ]; then
      cp "$TEMP_DIR/repo/CLAUDE-solana.md" "$TARGET_DIR/$INSTR_FILE"
    fi
    CHANGES="$CHANGES  [created] $INSTR_FILE\n"
    if [ "$INSTR_FILE" = "AGENTS.md" ] && [ -f "$TARGET_DIR/CLAUDE.md" ]; then
      CHANGES="$CHANGES  [notice] --agents installs now use AGENTS.md; CLAUDE.md is no longer updated\n"
    fi
  fi
fi

# Older --agents installs listed CLAUDE.md in the .gitignore config block; add AGENTS.md
GITIGNORE="$TARGET_DIR/.gitignore"

# Ignores added after an install may already exist: install.sh writes them for fresh
# installs, so without this an existing project never gets them. Appended outside the
# kit config block, since a user may have removed that block with /commit-claude-config.
if [ "$DRY_RUN" = false ] && [ -f "$GITIGNORE" ]; then
  for ignore in ".memsearch/" "$CONFIG_NAME/worktrees/"; do
    grep -qxF "$ignore" "$GITIGNORE" && continue
    printf '%s\n' "$ignore" >> "$GITIGNORE"
    CHANGES="$CHANGES  [updated] .gitignore — $ignore added\n"
  done
fi
if [ "$INSTR_FILE" = "AGENTS.md" ] && [ "$DRY_RUN" = false ] && [ -f "$GITIGNORE" ] \
  && grep -qF ">>> solana-ai-kit config" "$GITIGNORE" \
  && ! sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$GITIGNORE" | grep -qxF "$INSTR_FILE"; then
  awk -v f="$INSTR_FILE" '/^# <<< solana-ai-kit config <<</ { print f } { print }' "$GITIGNORE" > "$GITIGNORE.tmp" \
    && cat "$GITIGNORE.tmp" > "$GITIGNORE" && rm -f "$GITIGNORE.tmp"
  CHANGES="$CHANGES  [updated] .gitignore — $INSTR_FILE added to the kit config block\n"
fi

# safe-ai-skill project policy (Claude Code installs only; its hooks don't run under
# --agents): add it when missing, never overwrite it, and gitignore it with the kit
# config while that block is present.
POLICY=".safe-ai-skill/policy.yaml"
POLICY_SRC="$TEMP_DIR/repo/$POLICY"
[ -f "$POLICY_SRC" ] || POLICY_SRC="${LOCAL_SRC:+$LOCAL_SRC/$POLICY}"
if [ "$CONFIG_NAME" = ".claude" ] && [ -n "$POLICY_SRC" ] && [ -f "$POLICY_SRC" ]; then
  if [ ! -f "$TARGET_DIR/$POLICY" ]; then
    if [ "$DRY_RUN" = true ]; then
      CHANGES="$CHANGES  [would create] $POLICY\n"
    else
      mkdir -p "$TARGET_DIR/.safe-ai-skill" && cp "$POLICY_SRC" "$TARGET_DIR/$POLICY"
      CHANGES="$CHANGES  [created] $POLICY\n"
    fi
  fi
  if [ -f "$GITIGNORE" ] && grep -qF ">>> solana-ai-kit config" "$GITIGNORE" \
    && ! sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$GITIGNORE" | tr -d '\r' | grep -qxF ".safe-ai-skill/"; then
    if [ "$DRY_RUN" = true ]; then
      CHANGES="$CHANGES  [would update] .gitignore — .safe-ai-skill/ added to the kit config block\n"
    else
      awk '/^# <<< solana-ai-kit config <<</ { print ".safe-ai-skill/" } { print }' "$GITIGNORE" > "$GITIGNORE.tmp" \
        && cat "$GITIGNORE.tmp" > "$GITIGNORE" && rm -f "$GITIGNORE.tmp"
      CHANGES="$CHANGES  [updated] .gitignore — .safe-ai-skill/ added to the kit config block\n"
    fi
  fi
fi

# CLAUDE.local.md is created organically by Claude when needed (gitignored)

# Update submodules
if [ "$DRY_RUN" = false ]; then
  echo "Updating submodules..."
  (cd "$TARGET_DIR" && git submodule update --init --recursive 2>/dev/null) || echo "Note: Submodule update skipped"
fi

echo ""
if [ "$DRY_RUN" = true ]; then
  echo "=== DRY RUN — no changes written ==="
  echo ""
fi

if [ -n "$CHANGES" ]; then
  echo "Changes:"
  printf "$CHANGES"
else
  echo "Already up to date."
fi

echo ""
echo "Update complete!"

# The standard plugins are installed by the user from inside Claude Code, so no
# install or update step can place them. Print the commands rather than assume
# an older install ever saw them. Claude Code only: an --agents install has no
# /plugin.
if [ "$CONFIG_NAME" = ".claude" ]; then
  echo ""
  echo "Standard plugins (skip any you already have):"
  echo "  /plugin marketplace add zilliztech/memsearch"
  echo "  /plugin install memsearch"
  echo "  /plugin install rust-analyzer-lsp@claude-plugins-official"
  echo "Also typescript-lsp and csharp-lsp for those languages. Install the"
  echo "language server first; memsearch needs a restart to activate."
fi
