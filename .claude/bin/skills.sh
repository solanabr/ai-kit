#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit — skill packs
# The kit pins every ext/ skill pack as a git submodule. skills/skill-registry.json
# marks each pack "core" (installed by default) or "extension" (installed on demand).
# A pack entry with a "commit" is an upstream pack instead (anthropic-skills): the
# skills it lists are fetched from its source at that commit and installed as
# top-level skills, skills/<name>/, where every Agent Skills client finds them.
#
# Usage, from the project root (.agents/bin/skills.sh for --agents installs):
#   bash .claude/bin/skills.sh list              # packs, tier, installed or not, when to install
#   bash .claude/bin/skills.sh add <id> [...]    # install extensions at the commit the kit pins
#
# Called by install.sh, update.sh and resync.sh:
#   skills.sh select <kit .claude dir> <project config dir> [ids]   # trim a kit checkout before install copies it
#   skills.sh prune                                                 # after update.sh has copied every pack
#   skills.sh uninstalled                                           # extensions not installed here, one id per line
#
# skills/extensions.txt lists the extensions a project installed; update.sh keeps
# those and the core packs. skills/<id>.lock records an upstream pack's commit and
# folders. Env: SOLANA_AI_KIT_LOCAL_SRC=/path/to/kit copies from a local checkout
# (offline, tests); SOLANA_AI_KIT_UPSTREAM and SOLANA_AI_KIT_BRANCH override the
# source (default: main); SOLANA_AI_KIT_PACK_MIRROR=/dir fetches upstream pack <id>
# from the git repo /dir/<id> instead of its source (the pinned commit still applies).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_NAME="$(basename "$CONFIG_DIR")"
LIST_FILE="extensions.txt"

# Never installed, whatever the registry lists: anthropics/skills' docx, pdf, pptx and
# xlsx are proprietary (use only within Anthropic's services; no copies or
# redistribution) and doc-coauthoring has no license. Claude users get the document
# skills from Anthropic directly.
DENIED_SKILLS="docx pdf pptx xlsx doc-coauthoring"

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

# "<key>" of registry entry <id>: a string, or an inline array's items one per line.
entry_value() {
  awk -F'"' -v id="$2" -v key="$3" '
    /^    \{/        { cur = "" }
    /^      "id": "/ { cur = $4 }
    cur == id && index($0, "      \"" key "\": ") == 1 {
      if ($3 ~ /\[/) { for (i = 4; i < NF; i += 2) print $i } else print $4
    }
  ' "$1"
}

# Packs with a "commit": fetched from their upstream repo, not from a kit submodule.
upstream_ids() {
  awk -F'"' '
    /^    \{/            { id = ""; tier = ""; commit = "" }
    /^      "id": "/     { id = $4 }
    /^      "tier": "/   { tier = $4 }
    /^      "commit": "/ { commit = $4 }
    /^    \}/            { if (tier != "" && commit != "") print id }
  ' "$1"
}

has_line() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# An Agent Skills name: lowercase letters and digits in hyphen-separated words. Also
# keeps a registry or lock entry from naming a path outside skills/.
valid_name() { printf '%s\n' "$1" | grep -qxE '[a-z0-9]+(-[a-z0-9]+)*'; }

installed() { [ -f "$1/skills/$2.lock" ] || [ -n "$(ls -A "$1/skills/ext/$2" 2>/dev/null)" ]; }

lock_value() { if [ -f "$1" ]; then awk -v k="$2" '$1 == k { print $2 }' "$1"; fi; }

write_lock() {
  local lock="$1" id="$2" url="$3" commit="$4"
  shift 4
  {
    echo "# $id: skill folders bin/skills.sh copied unchanged, each with its LICENSE.txt,"
    echo "# from $url at the commit below. skills.sh and update.sh manage this file."
    echo "commit $commit"
    printf 'skill %s\n' "$@" | awk '!seen[$0]++'
  } > "$lock"
}

# Upstream pack <id> is installed in <cfg> at the registry's commit, with every skill it lists.
upstream_current() {
  local reg="$1" cfg="$2" id="$3" lock="$2/skills/$3.lock" name
  [ -f "$lock" ] || return 1
  [ "$(lock_value "$lock" commit)" = "$(entry_value "$reg" "$id" commit)" ] || return 1
  [ "$(lock_value "$lock" skill | sort)" = "$(entry_value "$reg" "$id" skills | sort)" ] || return 1
  for name in $(lock_value "$lock" skill); do
    [ -f "$cfg/skills/$name/SKILL.md" ] || return 1
  done
}

# Remove the folders an upstream pack installed (its lock lists them) and the lock.
remove_upstream() {
  local lock="$1/skills/$2.lock" name
  [ -f "$lock" ] || return 0
  for name in $(lock_value "$lock" skill); do
    if valid_name "$name"; then rm -rf "${1:?}/skills/${name:?}"; fi
  done
  rm -f "$lock"
}

# Check out only the given paths of <commit> from <url> into <dir>. The fetch is
# blob-less, so no file outside those paths is downloaded.
fetch_paths() {
  local url="$1" commit="$2" dir="$3"
  shift 3
  git -c init.defaultBranch=main init -q "$dir" \
    && git -C "$dir" remote add origin "$url" \
    && git -C "$dir" -c protocol.version=2 fetch -q --depth 1 --filter=blob:none origin "$commit" \
    && [ "$(git -C "$dir" rev-parse FETCH_HEAD)" = "$commit" ] \
    && git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD -- "$@"
}

# An upstream skill folder the kit may install: a SKILL.md named after the folder, an
# Apache-2.0 LICENSE.txt that travels with every copy, and no symlinks.
check_skill() {
  local dir="$1" name="$2" named
  [ -f "$dir/SKILL.md" ] || { echo "no SKILL.md"; return 1; }
  named="$(awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit }
    sub(/^name:[[:space:]]*/, "") { gsub(/["'\''[:space:]]/, ""); print; exit }' "$dir/SKILL.md")"
  [ "$named" = "$name" ] || { echo "its SKILL.md is named '$named'"; return 1; }
  if ! grep -q 'Apache License' "$dir/LICENSE.txt" 2>/dev/null || ! grep -q 'Version 2\.0' "$dir/LICENSE.txt"; then
    echo "no Apache-2.0 LICENSE.txt"; return 1
  fi
  [ -z "$(find "$dir" -type l)" ] || { echo "it contains symlinks"; return 1; }
}

# Install upstream pack <id> into <cfg>/skills/<name>/, one folder per skill the
# registry lists, from its source at the pinned commit. Every folder is checked
# before anything is written, and a folder the kit did not install is never
# replaced. On failure it says why on stderr and returns non-zero; the project keeps
# what it had. Callers test the status, which turns off errexit in here.
ensure_upstream() {
  local reg="$1" cfg="$2" id="$3" lock="$2/skills/$3.lock" commit skills url owned name why tmp paths=()
  upstream_current "$reg" "$cfg" "$id" && return 0
  commit="$(entry_value "$reg" "$id" commit)"
  skills="$(entry_value "$reg" "$id" skills | tr '\n' ' ')"
  url="$(entry_value "$reg" "$id" source)"
  [ -z "${SOLANA_AI_KIT_PACK_MIRROR:-}" ] || url="$SOLANA_AI_KIT_PACK_MIRROR/$id"
  owned="$(lock_value "$lock" skill | tr '\n' ' ')"
  if ! printf '%s\n' "$commit" | grep -qxE '[0-9a-f]{40}'; then
    echo "skills.sh: $id: the registry commit must be a full 40-character SHA" >&2
    return 1
  fi
  if [ -z "${skills// /}" ]; then
    echo "skills.sh: $id: the registry lists no skills" >&2
    return 1
  fi
  for name in $skills; do
    if ! valid_name "$name"; then
      echo "skills.sh: $id: invalid skill name '$name'" >&2
      return 1
    fi
    if has_word "$DENIED_SKILLS" "$name"; then
      echo "skills.sh: $id: refusing $name: its license does not allow installing it here (Claude users get it from Anthropic)" >&2
      return 1
    fi
    if [ -e "$cfg/skills/$name" ] && ! has_word "$owned" "$name"; then
      echo "skills.sh: $id: $(basename "$cfg")/skills/$name exists and was not installed by the kit; move it away, then retry" >&2
      return 1
    fi
    paths+=("skills/$name")
  done
  tmp="$(mktemp -d)" || return 1
  echo "Fetching $id (${skills% }) from $url at ${commit:0:7}..."
  if ! fetch_paths "$url" "$commit" "$tmp/src" "${paths[@]}"; then
    rm -rf "$tmp"
    echo "skills.sh: $id: could not fetch its skills from $url at $commit" >&2
    return 1
  fi
  for name in $skills; do
    if ! why="$(check_skill "$tmp/src/skills/$name" "$name")"; then
      rm -rf "$tmp"
      echo "skills.sh: $id: refusing $name at $commit: $why" >&2
      return 1
    fi
  done
  # Claim the folders before touching them, so an interrupted copy is retried, not refused.
  if ! { mkdir -p "$cfg/skills" && write_lock "$lock" "$id" "$url" pending $owned $skills; }; then
    rm -rf "$tmp"
    return 1
  fi
  for name in $owned; do
    if valid_name "$name"; then rm -rf "${cfg:?}/skills/${name:?}"; fi
  done
  for name in $skills; do
    if ! cp -R "$tmp/src/skills/$name" "$cfg/skills/$name"; then
      rm -rf "$tmp"
      echo "skills.sh: $id: could not copy $name into $(basename "$cfg")/skills/" >&2
      return 1
    fi
  done
  rm -rf "$tmp"
  write_lock "$lock" "$id" "$url" "$commit" $skills || return 1
  echo "✓ Installed $id in $(basename "$cfg")/skills/: ${skills% }"
}

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

# Remove the extensions not in $keep from <config dir>/skills.
drop_others() {
  local cfg="$1" reg="$2" keep="$3" id
  for id in $(tier_ids "$reg" extension); do
    has_line "$keep" "$id" && continue
    rm -rf "${cfg:?}/skills/ext/${id:?}"
    remove_upstream "$cfg" "$id"
  done
}

summary() {
  local reg="$1" keep="$2" name="$3" ext
  ext="$(printf '%s\n' "$keep" | awk 'NF' | tr '\n' ' ')"
  echo "✓ Skill packs: core $(tier_ids "$reg" core | tr '\n' ' ')| extensions: ${ext:-none}"
  echo "  Add an extension when a task needs it: bash $name/bin/skills.sh add <id> (list: bash $name/bin/skills.sh list)"
}

cmd_select() {
  local src="$1" dst="$2" reg="$1/skills/skill-registry.json" recorded keep id
  shift 2
  [ -f "$reg" ] || die "no skill registry at $reg"
  recorded="$(recorded_extensions "$dst" "$reg")"
  keep="$( { printf '%s\n' "$recorded"; expand_ids "$reg" "$@"; } | awk 'NF && !seen[$0]++')"
  drop_others "$src" "$reg" "$keep"
  # Upstream packs are not in the kit checkout: fetch the kept ones into the project.
  for id in $(upstream_ids "$reg"); do
    has_line "$keep" "$id" || continue
    ensure_upstream "$reg" "$dst" "$id" && continue
    echo "! $id was not installed; retry with: bash $(basename "$dst")/bin/skills.sh add $id" >&2
    has_line "$recorded" "$id" || keep="$(printf '%s\n' "$keep" | grep -vxF -- "$id" || true)"
  done
  write_list "$dst" $keep
  summary "$reg" "$keep" "$(basename "$dst")"
}

cmd_prune() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" keep id
  [ -f "$reg" ] || return 0
  keep="$(recorded_extensions "$CONFIG_DIR" "$reg")"
  drop_others "$CONFIG_DIR" "$reg" "$keep"
  # Installed upstream packs move to the commit this kit version pins.
  for id in $(upstream_ids "$reg"); do
    if has_line "$keep" "$id" && ! ensure_upstream "$reg" "$CONFIG_DIR" "$id"; then
      echo "! $id was not updated; retry with: bash $CONFIG_NAME/bin/skills.sh add $id" >&2
    fi
  done
  write_list "$CONFIG_DIR" $keep
  summary "$reg" "$keep" "$CONFIG_NAME"
}

# Extensions this project has not installed. Hub links into them dangle until
# skills.sh add, so resync.sh lists them instead of reporting broken paths.
cmd_uninstalled() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" keep id
  [ -f "$reg" ] || return 0
  keep="$(recorded_extensions "$CONFIG_DIR" "$reg")"
  for id in $(tier_ids "$reg" extension); do
    has_line "$keep" "$id" || echo "$id"
  done
}

cmd_add() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" ids id todo="" upstream="" failed="" src tmp url branch local_src extensions paths=()
  [ "$#" -gt 0 ] || die "usage: skills.sh add <id> [<id>...] (see: skills.sh list)"
  [ -f "$reg" ] || die "no skill registry at $reg"
  ids="$(expand_ids "$reg" "$@")"
  for id in $ids; do
    if has_line "$(upstream_ids "$reg")" "$id"; then
      if upstream_current "$reg" "$CONFIG_DIR" "$id"; then echo "✓ $id is already installed"; else upstream="$upstream $id"; fi
    elif installed "$CONFIG_DIR" "$id"; then echo "✓ $id is already installed"; else todo="$todo $id"; fi
  done
  if [ -n "$todo" ]; then
    local_src="${SOLANA_AI_KIT_LOCAL_SRC:-${SOLANA_CLAUDE_LOCAL_SRC:-}}"
    if [ -n "$local_src" ] && [ -d "$local_src/.claude/skills/ext" ]; then
      src="$local_src"
    else
      url="${SOLANA_AI_KIT_UPSTREAM:-${SOLANA_CLAUDE_UPSTREAM:-https://github.com/solanabr/ai-kit.git}}"
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
  for id in $upstream; do
    ensure_upstream "$reg" "$CONFIG_DIR" "$id" || failed="$failed $id"
  done
  extensions="$(tier_ids "$reg" extension)"
  write_list "$CONFIG_DIR" $(recorded_extensions "$CONFIG_DIR" "$reg") \
    $(for id in $ids; do if has_line "$extensions" "$id" && ! has_word "$failed" "$id"; then echo "$id"; fi; done)
  [ -z "$failed" ] || die "not installed:$failed"
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
  uninstalled) cmd_uninstalled ;;
  -h|--help|help) sed -n '4,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (use: list, add <id>...)" ;;
esac
