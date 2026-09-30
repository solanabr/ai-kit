#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit Installer
# Usage:
#   curl -fsSL https://aikit.superteam.codes | bash
#   (fallback if DNS not yet live: curl -fsSL https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh | bash)
#   bash install.sh /path/to/project
#   bash install.sh --agents /path/to/project   # installs into .agents/ instead of .claude/
#   bash install.sh --with sendai,jupiter /path/to/project   # core skill packs plus these extensions (--with all: every one)

REPO_URL="https://github.com/solanabr/ai-kit.git"
SCRIPT_VERSION="dev"

# Parse flags
AGENTS_ONLY=false
TARGET_ARG=""
WITH_SKILLS=""
WITH_NEXT=false
for arg in "$@"; do
  if [ "$WITH_NEXT" = true ]; then WITH_SKILLS="$WITH_SKILLS,$arg"; WITH_NEXT=false; continue; fi
  case "$arg" in
    --agents) AGENTS_ONLY=true ;;
    --with) WITH_NEXT=true ;;
    --with=*) WITH_SKILLS="$WITH_SKILLS,${arg#--with=}" ;;
    *) TARGET_ARG="$arg" ;;
  esac
done

TARGET_DIR="${TARGET_ARG:-.}"
mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# Set config directory and instruction file based on flag
# (--agents targets AGENTS.md readers such as Codex and opencode)
if [ "$AGENTS_ONLY" = true ]; then
  CONFIG_DIR=".agents"
  INSTR_FILE="AGENTS.md"
else
  CONFIG_DIR=".claude"
  INSTR_FILE="CLAUDE.md"
fi

# ── Branding ──────────────────────────────────────────────────────────────
# Solana gradient (purple → green), only on interactive truecolor terminals.
# NO_COLOR (https://no-color.org) and non-TTY output stay plain.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && printf %s "${COLORTERM:-}" | grep -qiE 'truecolor|24bit'; then
  C1=$'\033[38;2;153;69;255m'; C2=$'\033[38;2;131;98;237m'
  C3=$'\033[38;2;109;126;220m'; C4=$'\033[38;2;86;155;202m'
  C5=$'\033[38;2;64;184;184m'; C6=$'\033[38;2;42;212;167m'
  C7=$'\033[38;2;20;241;149m'
  CDIM=$'\033[2m'; CRST=$'\033[0m'; CSUB=$'\033[2;38;2;100;100;100m'
else
  C1=""; C2=""; C3=""; C4=""; C5=""; C6=""; C7=""; CDIM=""; CRST=""; CSUB=""
fi

# Parallel jobs for submodule fetches (network-bound; floor at 8)
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"
case "$JOBS" in ''|*[!0-9]*) JOBS=8 ;; esac
[ "$JOBS" -ge 8 ] || JOBS=8

print_banner() {
  printf '%s%s%s\n' "$C1" '   _____ ____  __    ___    _   _____' "$CRST"
  printf '%s%s%s\n' "$C2" '  / ___// __ \/ /   /   |  / | / /   |' "$CRST"
  printf '%s%s%s\n' "$C3" '  \__ \/ / / / /   / /| | /  |/ / /| |' "$CRST"
  printf '%s%s%s\n' "$C4" ' ___/ / /_/ / /___/ ___ |/ /|  / ___ |' "$CRST"
  printf '%s%s%s\n' "$C5" '/____/\____/_____/_/  |_/_/ |_/_/  |_|' "$CRST"
  printf '%s%s%s\n' "$C6" '           ▄▀█ █   █▄▀ █ ▀█▀' "$CRST"
  printf '%s%s%s\n' "$C7" '           █▀█ █   █ █ █  █' "$CRST"
  printf '%s\n\n' "${CSUB}         by @SuperteamBR 🇧🇷${CRST}"
}

# Log helpers — glyph prefixes only; message text stays grep-stable.
step() { printf '▸ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*"; }

print_banner

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Support local source for testing: SOLANA_AI_KIT_LOCAL_SRC=/path/to/repo
# (SOLANA_CLAUDE_LOCAL_SRC honored as legacy fallback)
LOCAL_SRC="${SOLANA_AI_KIT_LOCAL_SRC:-${SOLANA_CLAUDE_LOCAL_SRC:-}}"
if [ -n "$LOCAL_SRC" ] && [ -d "$LOCAL_SRC/.claude" ]; then
  step "Using local source: $LOCAL_SRC"
  mkdir -p "$TEMP_DIR/repo"
  cp -r "$LOCAL_SRC/.claude" "$TEMP_DIR/repo/.claude"
  cp "$LOCAL_SRC/CLAUDE-solana.md" "$TEMP_DIR/repo/CLAUDE-solana.md"
  [ -f "$LOCAL_SRC/.mcp.json" ] && cp "$LOCAL_SRC/.mcp.json" "$TEMP_DIR/repo/.mcp.json"
  [ -f "$LOCAL_SRC/.env.example" ] && cp "$LOCAL_SRC/.env.example" "$TEMP_DIR/repo/.env.example"
  [ -f "$LOCAL_SRC/.gitmodules" ] && cp "$LOCAL_SRC/.gitmodules" "$TEMP_DIR/repo/.gitmodules"
  [ -f "$LOCAL_SRC/.claude/VERSION" ] && cp "$LOCAL_SRC/.claude/VERSION" "$TEMP_DIR/repo/.claude/VERSION"
  # CHANGELOG.md stays in the repo — not shipped to user projects
else
  # Resolve latest tagged release; fall back to main (only needed for a network clone)
  step "Cloning repository..."
  LATEST_TAG=$(git ls-remote --tags --sort=-v:refname "$REPO_URL" 'refs/tags/v*' 2>/dev/null \
    | head -1 | sed 's|.*refs/tags/||; s|\^{}||')
  BRANCH="${LATEST_TAG:-main}"
  # Parallel + shallow submodule fetch (pins preserved; far faster than serial)
  git clone --recurse-submodules --shallow-submodules --jobs "$JOBS" --depth 1 --branch "$BRANCH" "$REPO_URL" "$TEMP_DIR/repo" 2>&1 | tail -1 || true
fi

# Read version from source
[ -f "$TEMP_DIR/repo/.claude/VERSION" ] && SCRIPT_VERSION="$(awk '{print $NF}' "$TEMP_DIR/repo/.claude/VERSION")"

# ext/ skills are vendored copies: drop the fetched checkout's submodule
# gitfiles, whose gitdir points into that checkout and would dangle here.
if [ -d "$TEMP_DIR/repo/.claude/skills/ext" ]; then
  find "$TEMP_DIR/repo/.claude/skills/ext" -name .git -type f -exec rm -f {} +
fi

# --agents: the kit ships .claude/ paths in its docs, skills, settings and
# .gitmodules. Point them at .agents/ so nothing references a directory this
# mode never creates. Left alone: ~/.claude/ (user-global), paths inside the
# vendored ext/ repos, bin/ (scripts resolve their own dir), and lines that
# already name .agents/ (those are written to handle both modes).
# Claude-Code-only files, not installed by --agents. /cleanup turns a fork of the
# kit repo into a project (README Option 0, run as `claude -m /cleanup`); its paths
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
# Claude Code strips HTML comments before the model sees them; Codex and opencode
# do not, so the maintainer notes in CLAUDE-solana.md would reach the model as
# instructions on every request. Strip them from the AGENTS.md source instead.
# Transform once, here: the later cmp/cp both read this file, so a mismatch
# would otherwise make every run look like a user edit.
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
if [ "$AGENTS_ONLY" = true ]; then
  R="$TEMP_DIR/repo"
  for f in $AGENTS_SKIP_FILES; do rm -f "$R/.claude/$f"; done
  strip_md_comments "$R/CLAUDE-solana.md"
  agents_paths "$R/CLAUDE-solana.md" "$R/.gitmodules" "$R/.claude/settings.json"
  while IFS= read -r f; do agents_paths "$f"; done < <(
    find "$R/.claude/agents" "$R/.claude/commands" "$R/.claude/rules" "$R/.claude/skills" \
      -path "$R/.claude/skills/ext" -prune -o -type f -print 2>/dev/null
  )
fi

step "Installing Solana AI Kit v$SCRIPT_VERSION to: $TARGET_DIR ($CONFIG_DIR/)"

# Copy .claude/ as $CONFIG_DIR (selective — protects user files)
step "Copying $CONFIG_DIR/ configuration..."
mkdir -p "$TARGET_DIR/$CONFIG_DIR"

if [ -d "$TARGET_DIR/$CONFIG_DIR/agents" ]; then
  warn "Warning: $CONFIG_DIR/ already exists, merging..."
fi

# Skill packs: keep the core ext/ packs, plus extensions named with --with or already
# installed here (skills/skill-registry.json tiers). Releases without skills.sh vendor every pack.
if [ -f "$TEMP_DIR/repo/.claude/bin/skills.sh" ]; then
  bash "$TEMP_DIR/repo/.claude/bin/skills.sh" select "$TEMP_DIR/repo/.claude" "$TARGET_DIR/$CONFIG_DIR" "$WITH_SKILLS"
fi

# Directories: always overwrite with upstream (same as update.sh)
for dir in agents skills rules commands bin; do
  if [ -d "$TEMP_DIR/repo/.claude/$dir" ]; then
    cp -r "$TEMP_DIR/repo/.claude/$dir" "$TARGET_DIR/$CONFIG_DIR/"
  fi
done

# The copy merges, so it never removes the Claude-Code-only files an older --agents
# install shipped. Remove them here.
if [ "$AGENTS_ONLY" = true ]; then
  for f in $AGENTS_SKIP_FILES; do
    if [ -f "$TARGET_DIR/$CONFIG_DIR/$f" ]; then
      rm -f "$TARGET_DIR/$CONFIG_DIR/$f"
      ok "Removed $CONFIG_DIR/$f (Claude Code only)"
    fi
  done
fi

# Older installs also copied the ext/ submodule gitfiles. Keep only a gitfile whose
# gitdir lives inside this project (a real submodule the user checked out); a copied
# one points outside, and with a local source it still resolves, so existence alone
# is not enough of a test.
if [ -d "$TARGET_DIR/$CONFIG_DIR/skills/ext" ]; then
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
  done < <(find "$TARGET_DIR/$CONFIG_DIR/skills/ext" -name .git -type f)
fi

# VERSION: always overwrite (CHANGELOG stays in source repo only)
[ -f "$TEMP_DIR/repo/.claude/VERSION" ] && cp "$TEMP_DIR/repo/.claude/VERSION" "$TARGET_DIR/$CONFIG_DIR/VERSION"

# Protected files: only copy if target doesn't exist yet
if [ -f "$TEMP_DIR/repo/.claude/settings.json" ] && [ ! -f "$TARGET_DIR/$CONFIG_DIR/settings.json" ]; then
  cp "$TEMP_DIR/repo/.claude/settings.json" "$TARGET_DIR/$CONFIG_DIR/settings.json"
fi

# MCP config: lives at project root as .mcp.json (Claude Code only reads this path)
if [ -f "$TEMP_DIR/repo/.mcp.json" ] && [ ! -f "$TARGET_DIR/.mcp.json" ]; then
  cp "$TEMP_DIR/repo/.mcp.json" "$TARGET_DIR/.mcp.json"
fi

# Copy CLAUDE-solana.md as the instruction file (CLAUDE.md, or AGENTS.md with --agents).
# Back up only real edits: re-running the installer must not overwrite an earlier
# backup of the user's own file with the kit's copy.
step "Copying $INSTR_FILE..."
if [ -f "$TARGET_DIR/$INSTR_FILE" ] && ! cmp -s "$TEMP_DIR/repo/CLAUDE-solana.md" "$TARGET_DIR/$INSTR_FILE"; then
  warn "Warning: $INSTR_FILE already exists, backing up to $INSTR_FILE.bak"
  cp "$TARGET_DIR/$INSTR_FILE" "$TARGET_DIR/$INSTR_FILE.bak"
fi
cp "$TEMP_DIR/repo/CLAUDE-solana.md" "$TARGET_DIR/$INSTR_FILE"

# Older --agents installs registered the ext/ skills under .claude/ paths; drop
# those stale entries unless a regular .claude/ install still uses them.
if [ "$AGENTS_ONLY" = true ] && [ -f "$TARGET_DIR/.gitmodules" ] && [ ! -d "$TARGET_DIR/.claude/skills/ext" ]; then
  git config -f "$TARGET_DIR/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | awk '$2 ~ /^\.claude\/skills\/ext\// { sub(/\.path$/, "", $1); print $1 }' \
    | while IFS= read -r section; do git config -f "$TARGET_DIR/.gitmodules" --remove-section "$section"; done || true
fi

# Merge .gitmodules (don't overwrite — user may have their own submodules)
if [ -f "$TEMP_DIR/repo/.gitmodules" ]; then
  if [ ! -f "$TARGET_DIR/.gitmodules" ]; then
    cp "$TEMP_DIR/repo/.gitmodules" "$TARGET_DIR/.gitmodules"
  else
    # Append submodule entries that don't already exist in target. One pass with a
    # flag: a nested read loop would swallow the next [submodule] header.
    COPYING=false
    while IFS= read -r line; do
      if [[ "$line" =~ ^\[submodule\ \"(.+)\"\] ]]; then
        COPYING=false
        if ! grep -qF "[submodule \"${BASH_REMATCH[1]}\"]" "$TARGET_DIR/.gitmodules"; then
          COPYING=true
          printf '\n%s\n' "$line" >> "$TARGET_DIR/.gitmodules"
        fi
      elif [ "$COPYING" = true ] && [ -n "$line" ]; then
        printf '%s\n' "$line" >> "$TARGET_DIR/.gitmodules"
      fi
    done < "$TEMP_DIR/repo/.gitmodules"
  fi
fi

# Initialize submodules in target
step "Initializing submodules..."
(cd "$TARGET_DIR" && git submodule update --init --recursive --jobs "$JOBS" 2>/dev/null) || warn "Note: Submodule init skipped (not a git repo or submodules already set up)"

# ── .gitignore: keep the kit out of the user's repo by default ──────────────
# Three sections so /commit-claude-config can surgically un-ignore the config.
GITIGNORE="$TARGET_DIR/.gitignore"
[ -f "$GITIGNORE" ] || : > "$GITIGNORE"

append_ignore() {  # append a pattern once (exact-line match)
  grep -qxF "$1" "$GITIGNORE" || printf '%s\n' "$1" >> "$GITIGNORE"
}

# 1) External skill submodules — always ignored (re-fetched via submodule update)
if ! grep -qF "$CONFIG_DIR/skills/ext/" "$GITIGNORE"; then
  printf '\n# External Claude skill submodules (re-fetched via: git submodule update --init)\n' >> "$GITIGNORE"
  append_ignore "$CONFIG_DIR/skills/ext/"
  ok "Added $CONFIG_DIR/skills/ext/ to .gitignore"
fi

# 2) Kit config — gitignored by default; /commit-claude-config versions it
if ! grep -qF ">>> solana-ai-kit config" "$GITIGNORE"; then
  {
    printf '\n# >>> solana-ai-kit config — gitignored by default; run /commit-claude-config to version it >>>\n'
    printf '.gitmodules\n'
    printf '%s/\n' "$CONFIG_DIR"
    printf '%s\n' "$INSTR_FILE"
    printf '.mcp.json\n'
    printf '# <<< solana-ai-kit config <<<\n'
  } >> "$GITIGNORE"
  ok "Kit config gitignored by default — run /commit-claude-config to version it"
else
  # A block written by an earlier install can be missing this mode's entries: an
  # older --agents install listed CLAUDE.md, and a second install in the other mode
  # (--agents next to .claude/, or the reverse) left its config dir and instruction
  # file untracked (.agents/ alone is 60MB of vendored trees). Ignore CRs when
  # matching: Git for Windows checks a tracked .gitignore out with CRLF endings.
  ADDED_IGNORE=""
  for entry in "$CONFIG_DIR/" "$INSTR_FILE"; do
    if sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$GITIGNORE" | tr -d '\r' | grep -qxF "$entry"; then
      continue
    fi
    awk -v f="$entry" '/^# <<< solana-ai-kit config <<</ { print f } { print }' "$GITIGNORE" > "$GITIGNORE.tmp" \
      && cat "$GITIGNORE.tmp" > "$GITIGNORE" && rm -f "$GITIGNORE.tmp"
    ADDED_IGNORE="$ADDED_IGNORE $entry"
  done
  if [ -n "$ADDED_IGNORE" ]; then
    ok "Added to the gitignore config block:$ADDED_IGNORE"
  fi
fi

# 3) Local-only — never committed (.env holds API keys once filled; .env.example stays tracked)
if ! grep -qF "# solana-ai-kit local-only" "$GITIGNORE"; then
  printf '\n# solana-ai-kit local-only (never committed)\n' >> "$GITIGNORE"
fi
append_ignore "CLAUDE.local.md"
append_ignore "$CONFIG_DIR/context/"
append_ignore ".env"
append_ignore ".env.local"

# Merge .env.example (append-only — preserves user edits on reinstall)
# shellcheck source=.claude/bin/_env_merge.sh
source "$TEMP_DIR/repo/.claude/bin/_env_merge.sh"
if [ -f "$TEMP_DIR/repo/.env.example" ]; then
  merge_env_file "$TEMP_DIR/repo/.env.example" "$TARGET_DIR/.env.example"
  if [ ! -f "$TARGET_DIR/.env" ]; then
    cp "$TARGET_DIR/.env.example" "$TARGET_DIR/.env"
    ok "Created .env from .env.example"
  else
    # Append new keys (with empty values) to existing .env
    merge_env_file "$TEMP_DIR/repo/.env.example" "$TARGET_DIR/.env"
  fi
fi

echo ""
BOX_LINES=(
  "Installation complete!"
  ""
  "Next steps:"
  "  1. cd $TARGET_DIR"
  "  2. Edit .env to add your API keys (Helius, RPC, etc.)"
)
if [ "$AGENTS_ONLY" = true ]; then
  BOX_LINES+=(
    "  3. Start Codex, opencode or another AGENTS.md-aware agent here;"
    "     it reads AGENTS.md and the skills in $CONFIG_DIR/skills/"
  )
else
  BOX_LINES+=(
    "  3. Run 'claude' to start Claude Code with Solana config"
    "  4. Try /build-program or /audit-solana commands"
    ""
    "This is the full install. If you also enable the solana-ai-kit"
    "plugin, prefer one path — both double-load commands/hooks/MCP"
    "(run /doctor to check)."
  )
fi
BOX_LINES+=(
  ""
  "$CONFIG_DIR/, $INSTR_FILE, .mcp.json and .gitmodules are gitignored"
  "by default to keep your repo clean. To version the kit config,"
  "run /commit-claude-config (or edit .gitignore)."
)
if [ "$AGENTS_ONLY" = true ]; then
  BOX_LINES+=("")
  BOX_LINES+=("Note: Installed into $CONFIG_DIR/ (--agents mode). $CONFIG_DIR/agents/,")
  BOX_LINES+=("$CONFIG_DIR/commands/ and .mcp.json keep Claude Code's format; other tools")
  BOX_LINES+=("can use them as prompts or context.")
fi
BOX_W=0
for line in "${BOX_LINES[@]}"; do
  if [ "${#line}" -gt "$BOX_W" ]; then BOX_W="${#line}"; fi
done
BOX_BORDER=""
i=0
while [ "$i" -lt $((BOX_W + 2)) ]; do BOX_BORDER="${BOX_BORDER}─"; i=$((i + 1)); done
printf '%s╭%s╮%s\n' "$C1" "$BOX_BORDER" "$CRST"
for line in "${BOX_LINES[@]}"; do
  printf '%s│%s %-*s %s│%s\n' "$CDIM" "$CRST" "$BOX_W" "$line" "$CDIM" "$CRST"
done
printf '%s╰%s╯%s\n' "$C7" "$BOX_BORDER" "$CRST"
