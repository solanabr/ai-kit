#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit Installer
# Usage:
#   curl -fsSL https://aikit.superteam.codes | bash
#   (fallback if DNS not yet live: curl -fsSL https://raw.githubusercontent.com/solanabr/ai-kit/main/install.sh | bash)
#   bash install.sh /path/to/project
#   bash install.sh --agents /path/to/project   # installs into .agents/ instead of .claude/

REPO_URL="https://github.com/solanabr/ai-kit.git"
SCRIPT_VERSION="dev"

# Parse flags
BRIDGE=false
TARGET_ARG=""
for arg in "$@"; do
  case "$arg" in
    --agents) BRIDGE=true ;;
    *) TARGET_ARG="$arg" ;;
  esac
done

TARGET_DIR="${TARGET_ARG:-.}"
mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# The kit installs one .claude/ tree. --agents adds a bridge on top of it for
# harnesses that read AGENTS.md and .agents/skills/ (Codex, Cursor, Copilot):
# the instruction file plus a single router skill pointing at .claude/skills/.
# Grok Build needs no bridge; it reads .claude/ natively.
CONFIG_DIR=".claude"
INSTR_FILE="CLAUDE.md"

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
  [ -d "$LOCAL_SRC/bridge" ] && cp -r "$LOCAL_SRC/bridge" "$TEMP_DIR/repo/bridge"
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
step "Installing Solana AI Kit v$SCRIPT_VERSION to: $TARGET_DIR ($CONFIG_DIR/)"

# Copy .claude/ as $CONFIG_DIR (selective — protects user files)
step "Copying $CONFIG_DIR/ configuration..."
mkdir -p "$TARGET_DIR/$CONFIG_DIR"

if [ -d "$TARGET_DIR/$CONFIG_DIR/agents" ]; then
  warn "Warning: $CONFIG_DIR/ already exists, merging..."
fi

# Directories: always overwrite with upstream (same as update.sh)
for dir in agents skills rules commands bin; do
  if [ -d "$TEMP_DIR/repo/.claude/$dir" ]; then
    cp -r "$TEMP_DIR/repo/.claude/$dir" "$TARGET_DIR/$CONFIG_DIR/"
  fi
done

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

# --agents: bridge for harnesses that read AGENTS.md and .agents/skills/ (Codex,
# Cursor, Copilot). AGENTS.md carries the same instructions as CLAUDE.md with the
# maintainer HTML comments stripped — Claude Code drops those before the model
# sees them, Codex does not, so they would arrive as instructions every request.
if [ "$BRIDGE" = true ] && [ ! -d "$TEMP_DIR/repo/bridge" ]; then
  warn "Warning: this release predates the AGENTS.md bridge — installed without it."
  warn "         Re-run once a release containing bridge/ is tagged."
  BRIDGE=false
fi
if [ "$BRIDGE" = true ]; then
  step "Installing the AGENTS.md bridge..."
  cp "$TEMP_DIR/repo/CLAUDE-solana.md" "$TEMP_DIR/repo/AGENTS.md"
  strip_md_comments "$TEMP_DIR/repo/AGENTS.md"
  if [ -e "$TARGET_DIR/AGENTS.md" ] && [ ! -f "$TARGET_DIR/AGENTS.md" ]; then
    fail "AGENTS.md exists and is not a regular file — leaving it alone, bridge not installed"
    BRIDGE=false
  fi
fi
if [ "$BRIDGE" = true ]; then
  if [ -f "$TARGET_DIR/AGENTS.md" ] && ! cmp -s "$TEMP_DIR/repo/AGENTS.md" "$TARGET_DIR/AGENTS.md"; then
    warn "Warning: AGENTS.md already exists, backing up to AGENTS.md.bak"
    cp "$TARGET_DIR/AGENTS.md" "$TARGET_DIR/AGENTS.md.bak"
  fi
  cp "$TEMP_DIR/repo/AGENTS.md" "$TARGET_DIR/AGENTS.md"

  # One router skill. Codex injects only name+description per skill and divides a
  # fixed budget across them, so registering the ~230 vendored ext/ packs here
  # would truncate every description to nothing. One entry keeps it readable.
  mkdir -p "$TARGET_DIR/.agents/skills"
  cp -r "$TEMP_DIR/repo/bridge/skills/solana-ai-kit" "$TARGET_DIR/.agents/skills/"

  # Codex and Claude Code share the hook contract, so both call the same script.
  mkdir -p "$TARGET_DIR/.codex"
  if [ -f "$TARGET_DIR/.codex/hooks.json" ]; then
    warn "Warning: .codex/hooks.json already exists, leaving it alone"
  else
    cp "$TEMP_DIR/repo/bridge/codex/hooks.json" "$TARGET_DIR/.codex/hooks.json"
  fi
  ok "Bridge installed — run /hooks in Codex once to trust the deploy gate"
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
    [ "$BRIDGE" = true ] && printf 'AGENTS.md\n.agents/skills/solana-ai-kit/\n.codex/hooks.json\n'
    printf '# <<< solana-ai-kit config <<<\n'
  } >> "$GITIGNORE"
  ok "Kit config gitignored by default — run /commit-claude-config to version it"
elif [ "$BRIDGE" = true ]; then
  # An earlier default install wrote the block without the bridge entries, and an
  # older --agents install listed .agents/ as the config dir. Top it up either way.
  ADDED_IGNORE=""
  for entry in "$CONFIG_DIR/" "$INSTR_FILE" "AGENTS.md" ".agents/skills/solana-ai-kit/" ".codex/hooks.json"; do
    if sed -n '/>>> solana-ai-kit config/,/<<< solana-ai-kit config/p' "$GITIGNORE" | grep -qxF "$entry"; then
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
if [ "$BRIDGE" = true ]; then
  BOX_LINES+=(
    "  3. Run 'claude', or start Codex/Cursor/Copilot here — they read"
    "     AGENTS.md and the router skill in .agents/skills/"
    "  4. In Codex, run /hooks once to trust the mainnet-deploy gate"
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
if [ "$BRIDGE" = true ]; then
  BOX_LINES+=("")
  BOX_LINES+=("Bridge installed: AGENTS.md + one router skill in .agents/skills/,")
  BOX_LINES+=("which points at .claude/skills/SKILL.md. Grok Build needs no bridge —")
  BOX_LINES+=("it reads .claude/ natively.")
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
