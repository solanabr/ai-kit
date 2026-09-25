#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit — skill packs
# The kit pins every ext/ skill pack as a git submodule. skills/skill-registry.json
# marks each pack "core" (installed by default) or "extension" (installed on demand).
#
# Usage, from the project root (.agents/bin/skills.sh for --agents installs):
#   bash .claude/bin/skills.sh list              # packs, tier, installed or not, when to install
#   bash .claude/bin/skills.sh add <id> [...]    # install extensions at the commit the kit pins
#
# Called by install.sh and update.sh:
#   skills.sh select <kit .claude dir> <project config dir> [ids]   # trim a kit checkout before install copies it
#   skills.sh prune                                                 # after update.sh has copied every pack
#
# skills/extensions.txt lists the extensions a project installed; update.sh keeps
# those and the core packs. Env: SOLANA_AI_KIT_LOCAL_SRC=/path/to/kit copies from a
# local checkout (offline, tests); SOLANA_AI_KIT_UPSTREAM and SOLANA_AI_KIT_BRANCH
# override the source (default: main).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_NAME="$(basename "$CONFIG_DIR")"
LIST_FILE="extensions.txt"

die() { echo "skills.sh: $*" >&2; exit 1; }

# id<TAB>tier<TAB>triggers for each kit pack. The registry keeps one key per line
# and arrays inline, so awk reads it without jq or python; the test suite holds it
# to that layout (tests/test_skill_extensions.sh).
registry_rows() {
  awk -F'"' '
    /^    \{/               { id = ""; tier = ""; trig = "" }
    /^      "id": "/        { id = $4 }
    /^      "tier": "/      { tier = $4 }
    /^      "triggers": \[/ { for (i = 4; i < NF; i += 2) trig = trig (trig == "" ? "" : ", ") $i }
    /^    \}/               { if (tier != "") printf "%s\t%s\t%s\n", id, tier, trig }
  ' "$1"
}

tier_ids() { registry_rows "$1" | awk -F'\t' -v t="$2" '$2 == t { print $1 }'; }

has_line() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

installed() { [ -n "$(ls -A "$1/skills/ext/$2" 2>/dev/null)" ]; }

# Validate ids against the registry; "all" means every extension.
expand_ids() {
  local reg="$1" known id
  shift
  known="$(registry_rows "$reg" | cut -f1)"
  for id in $(printf '%s ' "$@" | tr ',' ' '); do
    if [ "$id" = all ]; then tier_ids "$reg" extension; continue; fi
    has_line "$known" "$id" || die "unknown skill pack '$id' (see: skills.sh list)"
    echo "$id"
  done
}

# Extensions a project installed. Installs from before the core/extension split
# have no list and carried every pack, so they keep what is on disk.
recorded_extensions() {
  local cfg="$1" reg="$2" id
  if [ -f "$cfg/skills/$LIST_FILE" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$cfg/skills/$LIST_FILE" || true
  else
    for id in $(tier_ids "$reg" extension); do
      if installed "$cfg" "$id"; then echo "$id"; fi
    done
  fi
}

write_list() {
  local cfg="$1"
  shift
  mkdir -p "$cfg/skills"
  {
    echo "# Skill extensions installed in this project, one id per line (ids: skill-registry.json)."
    echo "# bin/skills.sh add writes this file; bin/update.sh keeps these and the core packs."
    printf '%s\n' "$@" | awk 'NF' | sort -u
  } > "$cfg/skills/$LIST_FILE"
}

# Remove the extensions not in $keep from <config dir>/skills/ext.
drop_others() {
  local cfg="$1" reg="$2" keep="$3" id
  for id in $(tier_ids "$reg" extension); do
    has_line "$keep" "$id" || rm -rf "${cfg:?}/skills/ext/${id:?}"
  done
}

summary() {
  local reg="$1" keep="$2" name="$3" ext
  ext="$(printf '%s\n' "$keep" | awk 'NF' | tr '\n' ' ')"
  echo "✓ Skill packs: core $(tier_ids "$reg" core | tr '\n' ' ')| extensions: ${ext:-none}"
  echo "  Add an extension when a task needs it: bash $name/bin/skills.sh add <id> (list: bash $name/bin/skills.sh list)"
}

cmd_select() {
  local src="$1" dst="$2" reg="$1/skills/skill-registry.json" keep
  shift 2
  [ -f "$reg" ] || die "no skill registry at $reg"
  keep="$( { recorded_extensions "$dst" "$reg"; expand_ids "$reg" "$@"; } | awk 'NF && !seen[$0]++')"
  drop_others "$src" "$reg" "$keep"
  write_list "$dst" $keep
  summary "$reg" "$keep" "$(basename "$dst")"
}

cmd_prune() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" keep
  [ -f "$reg" ] || return 0
  keep="$(recorded_extensions "$CONFIG_DIR" "$reg")"
  drop_others "$CONFIG_DIR" "$reg" "$keep"
  write_list "$CONFIG_DIR" $keep
  summary "$reg" "$keep" "$CONFIG_NAME"
}

cmd_add() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" ids id todo="" src tmp url branch local_src extensions paths=()
  [ "$#" -gt 0 ] || die "usage: skills.sh add <id> [<id>...] (see: skills.sh list)"
  [ -f "$reg" ] || die "no skill registry at $reg"
  ids="$(expand_ids "$reg" "$@")"
  for id in $ids; do
    if installed "$CONFIG_DIR" "$id"; then echo "✓ $id is already installed"; else todo="$todo $id"; fi
  done
  if [ -n "$todo" ]; then
    local_src="${SOLANA_AI_KIT_LOCAL_SRC:-${SOLANA_CLAUDE_LOCAL_SRC:-}}"
    if [ -n "$local_src" ] && [ -d "$local_src/.claude/skills/ext" ]; then
      src="$local_src"
    else
      url="${SOLANA_AI_KIT_UPSTREAM:-${SOLANA_CLAUDE_UPSTREAM:-https://github.com/solanabr/solana-ai-kit.git}}"
      branch="${SOLANA_AI_KIT_BRANCH:-${SOLANA_CLAUDE_BRANCH:-main}}"
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      echo "Fetching the pinned packs from $url ($branch)..."
      git clone -q --depth 1 --branch "$branch" "$url" "$tmp/kit"
      for id in $todo; do paths+=(".claude/skills/ext/$id"); done
      git -C "$tmp/kit" submodule update -q --init --recursive --depth 1 --jobs 8 -- "${paths[@]}"
      src="$tmp/kit"
    fi
    mkdir -p "$CONFIG_DIR/skills/ext"
    for id in $todo; do
      [ -n "$(ls -A "$src/.claude/skills/ext/$id" 2>/dev/null)" ] \
        || die "$id is empty in $src (run: git submodule update --init there)"
      rm -rf "${CONFIG_DIR:?}/skills/ext/${id:?}"
      cp -R "$src/.claude/skills/ext/$id" "$CONFIG_DIR/skills/ext/$id"
      # Vendored copy: drop submodule gitfiles, whose gitdir only exists in the kit checkout
      find "$CONFIG_DIR/skills/ext/$id" -name .git -prune -exec rm -rf {} +
      echo "✓ Installed $id in $CONFIG_NAME/skills/ext/$id"
    done
  fi
  extensions="$(tier_ids "$reg" extension)"
  write_list "$CONFIG_DIR" $(recorded_extensions "$CONFIG_DIR" "$reg") \
    $(for id in $ids; do if has_line "$extensions" "$id"; then echo "$id"; fi; done)
}

cmd_list() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" id tier trig state
  [ -f "$reg" ] || die "no skill registry at $reg"
  printf '%-20s %-10s %-10s %s\n' PACK TIER STATE "INSTALL WHEN THE TASK INVOLVES"
  registry_rows "$reg" | while IFS=$'\t' read -r id tier trig; do
    state="-"
    if installed "$CONFIG_DIR" "$id"; then state=installed; fi
    printf '%-20s %-10s %-10s %s\n' "$id" "$tier" "$state" "$trig"
  done
  echo ""
  echo "Install an extension: bash $CONFIG_NAME/bin/skills.sh add <id>"
}

case "${1:-list}" in
  list) cmd_list ;;
  add) shift; cmd_add "$@" ;;
  select) shift; [ "$#" -ge 2 ] || die "usage: skills.sh select <kit .claude dir> <config dir> [ids]"; cmd_select "$@" ;;
  prune) cmd_prune ;;
  -h|--help|help) sed -n '4,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (use: list, add <id>...)" ;;
esac
