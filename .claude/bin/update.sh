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
# kit repo into a project (README "Using as a GitHub Template"); its paths
# describe the kit's own repo, so in an .agents/ project every step of it is false.
# Not shipping it beats rewriting it into something plausible but wrong.
AGENTS_SKIP_FILES='commands/cleanup.md'
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
  # the frozen copy loop above already wrote these; remove from the target
  for f in $AGENTS_SKIP_FILES; do rm -f "$TARGET_DIR/$CONFIG_NAME/$f"; done
  strip_md_comments "$TEMP_DIR/repo/CLAUDE-solana.md"
  agents_paths "$TEMP_DIR/repo/CLAUDE-solana.md" "$TEMP_DIR/repo/.gitmodules"
  if [ "$DRY_RUN" = false ]; then
    while IFS= read -r rel; do agents_paths "$TARGET_DIR/$CONFIG_NAME/$rel"; done < <(
      cd "$TEMP_DIR/repo/.claude" && find agents commands rules skills -path skills/ext -prune -o -type f -print 2>/dev/null
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
OLD_SERVERS = {
    "playwright": {"command": "npx", "args": ["-y", "@playwright/mcp@latest", "--headless"]},
    "context-mode": {"command": "npx", "args": ["-y", "context-mode@latest"]},
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
if [ "$INSTR_FILE" = "AGENTS.md" ] && [ "$DRY_RUN" = false ] && [ -f "$GITIGNORE" ] \
  && grep -qF ">>> solana-ai-kit config" "$GITIGNORE" \
  && ! sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$GITIGNORE" | grep -qxF "$INSTR_FILE"; then
  awk -v f="$INSTR_FILE" '/^# <<< solana-ai-kit config <<</ { print f } { print }' "$GITIGNORE" > "$GITIGNORE.tmp" \
    && cat "$GITIGNORE.tmp" > "$GITIGNORE" && rm -f "$GITIGNORE.tmp"
  CHANGES="$CHANGES  [updated] .gitignore — $INSTR_FILE added to the kit config block\n"
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
