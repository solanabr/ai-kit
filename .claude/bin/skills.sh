#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit — skill packs
# The kit pins every ext/ skill pack as a git submodule. skills/skill-registry.json
# marks each pack "core" (installed by default) or "extension" (installed on demand),
# and records the commit each one is pinned at. A pack entry with a "skills" list is an
# upstream pack instead (anthropic-skills): the folders it lists are fetched from its
# source at that commit and installed as top-level skills, skills/<name>/, where every
# Agent Skills client finds them.
#
# Both kinds carry their pin in the same "commit" field, and both are verified against
# it rather than trusted: an upstream pack's fetch asserts FETCH_HEAD, and a submodule
# pack is checked against the kit checkout's gitlink before it is copied. A mismatch
# stops the install instead of silently delivering a commit nobody recorded.
#
# Usage, from the project root (.agents/bin/skills.sh for --agents installs):
#   bash .claude/bin/skills.sh list              # packs, tier, installed or not, when to install
#   bash .claude/bin/skills.sh add <id> [...]    # install extensions at the commit the kit pins
#   bash .claude/bin/skills.sh add --force <id>  # reinstall a pack, e.g. one a killed copy left partial
#
# Called by install.sh, update.sh and resync.sh:
#   skills.sh select <kit .claude dir> <project config dir> [ids]   # trim a kit checkout before install copies it
#   skills.sh prune                                                 # after update.sh has copied every pack
#   skills.sh uninstalled                                           # extensions not installed here, one id per line
#   skills.sh pins [--write] [<kit repo root>]                      # registry pins vs the gitlinks (maintainers, CI)
#   skills.sh budget                                                # --agents: warn past Codex's skill budget
#   skills.sh duplicates                                            # --agents: skill names registered more than once
#
# skills/extensions.txt lists the extensions a project installed (no file: none, so
# core-only); update.sh keeps those and the core packs. skills/kit-packs.txt lists
# every ext/ pack the kit put here, so a pack a later kit drops is removed without
# touching folders the user made. skills/<id>.lock records an upstream pack's commit and
# folders; skills/duplicate-names.txt (--agents) the names budget last warned about.
# Env: SOLANA_AI_KIT_LOCAL_SRC=/path/to/kit copies from a local checkout
# (offline, tests); SOLANA_AI_KIT_UPSTREAM and SOLANA_AI_KIT_BRANCH override the
# source (default: the release tag this install's VERSION names, else main);
# SOLANA_AI_KIT_PACK_MIRROR=/dir fetches upstream pack <id>
# from the git repo /dir/<id> instead of its source (the pinned commit still applies).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_NAME="$(basename "$CONFIG_DIR")"
LIST_FILE="extensions.txt"
PACKS_FILE="kit-packs.txt"
DUPES_FILE="duplicate-names.txt"

# strip_pack_load_surfaces: what a vendored pack must not bring into a project.
# shellcheck source=_pack_strip.sh
source "$SCRIPT_DIR/_pack_strip.sh"

# Never installed, whatever the registry lists: anthropics/skills' docx, pdf, pptx and
# xlsx are proprietary (use only within Anthropic's services; no copies or
# redistribution) and doc-coauthoring has no license. Claude users get the document
# skills from Anthropic directly.
DENIED_SKILLS="docx pdf pptx xlsx doc-coauthoring"

# A URL safe to print: git keeps credentials out of its own errors, so ours do too.
# Greedy up to the last @ before the first /, so a raw @ in a password goes with it.
redact_url() { printf '%s' "$1" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@#\1#'; }

die() { echo "skills.sh: $*" >&2; exit 1; }

# id<TAB>tier<TAB>triggers for each kit pack. The registry keeps one key per line
# and arrays inline, so awk reads it without jq or python; the test suite holds it
# to that layout (tests/test_skill_extensions.sh), and check_registry refuses a file
# that lost it. triggers is display text for people and agents (the INSTALL WHEN
# column of list); nothing matches on it.
registry_rows() {
  awk -F'"' '
    /^    \{/               { id = ""; tier = ""; trig = "" }
    /^      "id": "/        { id = $4 }
    /^      "tier": "/      { tier = $4 }
    /^      "triggers": \[/ { for (i = 4; i < NF; i += 2) trig = trig (trig == "" ? "" : ", ") $i }
    /^    \}/               { if (tier != "") printf "%s\t%s\t%s\n", id, tier, trig }
  ' "$1"
}

# A reformatted registry is still valid JSON, but the awk above then reads fewer
# packs, or none, and select would keep every pack. Refuse it instead.
check_registry() {
  local reg="$1" rows tiers
  [ -f "$reg" ] || die "no skill registry at $reg"
  rows="$(registry_rows "$reg" | grep -c . || true)"
  tiers="$(grep -cE '"tier"[[:space:]]*:' "$reg" || true)"
  [ "$rows" = "$tiers" ] || die "read $rows of the $tiers packs in $reg: it lost the layout skills.sh reads (each entry's braces on their own lines at 4 spaces, one key per line at 6, arrays inline). Restore the kit's copy, e.g. with $CONFIG_NAME/bin/update.sh"
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

# Packs with a "skills" list: fetched from their upstream repo folder by folder, not
# vendored from a kit submodule. Every pack has a "commit", so the skills list is what
# separates the two kinds.
upstream_ids() {
  awk -F'"' '
    /^    \{/             { id = ""; tier = ""; skills = "" }
    /^      "id": "/      { id = $4 }
    /^      "tier": "/    { tier = $4 }
    /^      "skills": \[/ { skills = "y" }
    /^    \}/             { if (tier != "" && skills != "") print id }
  ' "$1"
}

# The upstream packs an install should carry: every core one, plus the extensions in
# <keep>. A core pack that is a submodule arrives with the kit clone; a core pack with
# a skills list is not in that clone at all, so it has to be fetched from its own
# source the way an extension is, whether or not anyone asked for it.
wanted_upstream() {  # wanted_upstream <registry> <keep>
  local core id
  core="$(tier_ids "$1" core)"
  for id in $(upstream_ids "$1"); do
    if has_line "$core" "$id" || has_line "$2" "$id"; then echo "$id"; fi
  done
}

# The commit a kit checkout has pack <path> pinned at: the gitlink in its index. Empty
# when <root> is not a git repo or <path> is not a submodule there — a vendored copy,
# where there is nothing to compare against.
gitlink() {
  git -C "$1" ls-files -s -- "$2" 2>/dev/null | awk '$1 == "160000" { print $2 }' || true
}

has_line() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# A bounded one-line rendering of a space-separated id list: every id when there are few,
# the first five and a count when there are many. One line, because install.sh renders a
# pin report as a single warning line.
short_list() {
  local n i=0 out="" item
  # shellcheck disable=SC2086  # word splitting is the point here
  set -- $1
  n=$#
  for item in "$@"; do
    i=$((i + 1))
    if [ "$n" -gt 6 ] && [ "$i" -gt 5 ]; then
      out="$out and $((n - 5)) more"
      break
    fi
    if [ -z "$out" ]; then out="$item"; else out="$out, $item"; fi
  done
  printf '%s' "$out"
}

# An Agent Skills name: lowercase letters and digits in hyphen-separated words. Also
# keeps a registry or lock entry from naming a path outside skills/.
valid_name() { printf '%s\n' "$1" | grep -qxE '[a-z0-9]+(-[a-z0-9]+)*'; }

# A lock still at "commit pending" is a copy that never finished: not installed.
installed() {
  { [ -f "$1/skills/$2.lock" ] && [ "$(lock_value "$1/skills/$2.lock" commit)" != pending ]; } \
    || [ -n "$(ls -A "$1/skills/ext/$2" 2>/dev/null)" ]
}

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
  for name in $(lock_value "$lock" skill); do
    if has_word "$DENIED_SKILLS" "$name"; then return 1; fi
  done
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

# The Apache License 2.0 as git blob ids of its normalised text (CRs dropped, each
# whitespace run one space): the header and terms through "END OF TERMS AND
# CONDITIONS", and the APPENDIX with its copyright line put back to the template's
# "[yyyy] [name of copyright owner]". Both match apache.org/licenses/LICENSE-2.0.txt.
APACHE_TERMS=e4963138c85362572abad346c4773ecdebf11522
APACHE_APPENDIX=aad5408a30d833e1d46729eb152635c107476d5b

# <file> is the Apache License 2.0, with its APPENDIX or without it (frontend-design's
# copy stops before it). Otherwise it prints why and fails.
apache_license() {
  local text terms rest
  [ -f "$1" ] || { echo "missing"; return 1; }
  if grep -qiE 'all rights reserved|may not.*retain copies' "$1"; then
    echo "it reserves rights"; return 1
  fi
  text="$(tr -d '\r' < "$1" | tr -s ' \t\n' '   ' | sed 's/^ //; s/ $//')"
  terms="${text%%END OF TERMS AND CONDITIONS*}END OF TERMS AND CONDITIONS"
  rest="${text#"$terms"}"
  # The appendix's one variable line: the template, or Anthropic's own copyright (the
  # only source is anthropics/skills). Anything else in that slot fails the hash below.
  rest="$(printf '%s' "${rest# }" | sed -E 's/^(.* )?Copyright [0-9]{4}(-[0-9]{4})? Anthropic, PBC\. Licensed under/\1Copyright [yyyy] [name of copyright owner] Licensed under/')"
  if [ "$(printf '%s' "$terms" | git hash-object --stdin)" != "$APACHE_TERMS" ] \
    || { [ -n "$rest" ] && [ "$(printf '%s' "$rest" | git hash-object --stdin)" != "$APACHE_APPENDIX" ]; }; then
    echo "its text is not the Apache License 2.0"; return 1
  fi
}

skill_name() {  # the name: in <SKILL.md>'s frontmatter
  awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit }
    sub(/^name:[[:space:]]*/, "") { gsub(/["'\''[:space:]]/, ""); print; exit }' "$1"
}

# An upstream skill folder the kit may install: a SKILL.md named after the folder, an
# Apache-2.0 LICENSE.txt that travels with every copy, and no symlinks. The copy takes
# the whole subtree, so a nested skill or license file is held to the same rules.
check_skill() {
  local dir="$1" name="$2" named why f rel
  [ -f "$dir/SKILL.md" ] || { echo "no SKILL.md"; return 1; }
  named="$(skill_name "$dir/SKILL.md")"
  [ "$named" = "$name" ] || { echo "its SKILL.md is named '$named'"; return 1; }
  why="$(apache_license "$dir/LICENSE.txt")" || { echo "no Apache-2.0 LICENSE.txt ($why)"; return 1; }
  [ -z "$(find "$dir" -type l)" ] || { echo "it contains symlinks"; return 1; }
  while IFS= read -r f; do
    rel="${f#"$dir"/}"
    if [ "$(basename "$f")" = SKILL.md ]; then
      named="$(skill_name "$f")"
      if has_word "$DENIED_SKILLS" "$(basename "$(dirname "$f")")" || has_word "$DENIED_SKILLS" "$named"; then
        echo "it contains $rel, a skill the kit refuses"; return 1
      fi
    elif ! why="$(apache_license "$f")"; then
      echo "its $rel is not an Apache-2.0 license ($why)"; return 1
    fi
  done < <(find "$dir" -mindepth 2 -type f \( -name SKILL.md -o -iname 'licen[cs]e*' -o -iname 'copying*' \);
           find "$dir" -mindepth 1 -maxdepth 1 -type f \( -iname 'licen[cs]e*' -o -iname 'copying*' \) ! -name LICENSE.txt)
}

# Install upstream pack <id> into <cfg>/skills/<name>/, one folder per skill the
# registry lists, from its source at the pinned commit. Every folder is checked
# before anything is written, and a folder the kit did not install is never
# replaced. On failure it says why on stderr and returns non-zero; the project keeps
# what it had. Callers test the status, which turns off errexit in here. A fourth
# argument "force" refetches a pack that looks current.
ensure_upstream() {
  local reg="$1" cfg="$2" id="$3" force="${4:-}" lock="$2/skills/$3.lock" commit skills url owned name why tmp root paths=()
  skills="$(entry_value "$reg" "$id" skills | tr '\n' ' ')"
  # Where the skill folders live in the upstream tree. Defaults to skills/, which is
  # the common layout; a pack that nests them deeper (providers/.../plugin/skills)
  # declares skills_root instead. Only the source side moves — every pack still
  # installs to <cfg>/skills/<name>/, because that is where the host discovers them.
  root="$(entry_value "$reg" "$id" skills_root)"
  root="${root:-skills}"
  case "$root" in
    /*|*..*|*' '*) echo "skills.sh: $id: skills_root must be a relative path with no '..': '$root'" >&2; return 1 ;;
  esac
  root="${root%/}"
  owned="$(lock_value "$lock" skill | tr '\n' ' ')"
  # The denylist answers before the lock does: a registry and lock that both list a
  # denied skill would otherwise read as current and keep it.
  for name in $skills; do
    has_word "$DENIED_SKILLS" "$name" || continue
    if has_word "$owned" "$name" && valid_name "$name" && [ -e "$cfg/skills/$name" ]; then
      rm -rf "${cfg:?}/skills/${name:?}"
      echo "skills.sh: $id: removed $(basename "$cfg")/skills/$name, which its lock listed" >&2
    fi
    echo "skills.sh: $id: refusing $name: its license does not allow installing it here (Claude users get it from Anthropic)" >&2
    return 1
  done
  [ "$force" != force ] && upstream_current "$reg" "$cfg" "$id" && return 0
  commit="$(entry_value "$reg" "$id" commit)"
  url="$(entry_value "$reg" "$id" source)"
  [ -z "${SOLANA_AI_KIT_PACK_MIRROR:-}" ] || url="$SOLANA_AI_KIT_PACK_MIRROR/$id"
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
    if [ -e "$cfg/skills/$name" ] && ! has_word "$owned" "$name"; then
      echo "skills.sh: $id: $(basename "$cfg")/skills/$name exists and was not installed by the kit; move it away, then retry" >&2
      return 1
    fi
    paths+=("$root/$name")
  done
  tmp="$(mktemp -d)" || return 1
  echo "Fetching $id (${skills% }) from $url at ${commit:0:7} (${root}/)..."
  if ! fetch_paths "$url" "$commit" "$tmp/src" "${paths[@]}"; then
    rm -rf "$tmp"
    echo "skills.sh: $id: could not fetch its skills from $url at $commit" >&2
    return 1
  fi
  for name in $skills; do
    if ! why="$(check_skill "$tmp/src/$root/$name" "$name")"; then
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
    if ! cp -R "$tmp/src/$root/$name" "$cfg/skills/$name"; then
      rm -rf "$tmp"
      echo "skills.sh: $id: could not copy $name into $(basename "$cfg")/skills/" >&2
      return 1
    fi
    # An upstream skill installs where the host already discovers it, so a .claude/ of
    # its own inside it would be a second, unasked-for load surface. Same rule as ext/.
    strip_pack_load_surfaces "$cfg/skills/$name" >/dev/null
  done
  rm -rf "$tmp"
  write_lock "$lock" "$id" "$url" "$commit" $skills || return 1
  echo "✓ Installed $id in $(basename "$cfg")/skills/: ${skills% }"
}

# Pack <id> in the kit checkout <src> is at the commit the registry records for it.
# A mismatch, or an entry with no commit, returns non-zero and says what to do.
#
# A source with no gitlink for it cannot be checked at all: a tarball, a mirror, a fork
# with ext/ committed as plain files, a test fixture. The gitlink comparison is the whole
# mechanism — nothing here hashes a pack's content — so that case is a warning and the
# copy proceeds on the registry's word alone. It must not read as a check that passed.
check_pin() {
  local reg="$1" src="$2" id="$3" path want have
  path="$(entry_value "$reg" "$id" path)"
  want="$(entry_value "$reg" "$id" commit)"
  if ! printf '%s\n' "$want" | grep -qxE '[0-9a-f]{40}'; then
    echo "skills.sh: $id: the registry records no 40-character commit for it" >&2
    return 1
  fi
  have="$(gitlink "$src" "$path")"
  if [ -z "$have" ]; then
    echo "skills.sh: warning: $id's pin is unverified ($src has no gitlink for $path); copying it on the registry's word alone" >&2
    return 0
  fi
  if [ "$have" != "$want" ]; then
    echo "skills.sh: $id: $src has it at ${have:0:12}, the registry pins ${want:0:12}." >&2
    echo "  Not installing a commit the kit does not record. In a kit checkout, resync the two with: bash $CONFIG_NAME/bin/skills.sh pins --write" >&2
    return 1
  fi
}

# Validate ids against the registry; "all" means every extension.
expand_ids() {
  local reg="$1" known id items=()
  shift
  known="$(registry_rows "$reg" | cut -f1)"
  # read -a splits on whitespace without pathname expansion, so '*' stays '*'
  read -ra items <<< "$(printf '%s ' "$@" | tr ',' ' ')"
  [ "${#items[@]}" -gt 0 ] || return 0
  for id in "${items[@]}"; do
    if [ "$id" = all ]; then tier_ids "$reg" extension; continue; fi
    has_line "$known" "$id" || die "unknown skill pack '$id' (see: skills.sh list)"
    echo "$id"
  done
}

# Extensions a project installed: the lines of extensions.txt and nothing else. No list
# means none were chosen, so the project is core-only (#112). That is every install from
# before the core/extension split: it vendored all the packs and wrote no list, so what
# is on disk there is the old default, not a choice — and once update.sh's copy loop has
# run, every pack is on disk whatever was chosen, so the disk is never evidence. Lines
# are trimmed and lowercased; one that is not an extension id in this registry is
# dropped with a warning, so a hand edit can't add a pack nobody chose.
recorded_extensions() {
  local cfg="$1" reg="$2" known id
  [ -f "$cfg/skills/$LIST_FILE" ] || return 0
  known="$(tier_ids "$reg" extension)"
  while IFS= read -r id; do
    if has_line "$known" "$id"; then
      echo "$id"
    else
      echo "skills.sh: ignoring '$id' in $(basename "$cfg")/skills/$LIST_FILE: not a skill extension in this kit" >&2
    fi
  done < <(tr -d '\r' < "$cfg/skills/$LIST_FILE" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); $0 = tolower($0) } NF && !/^#/ && !seen[$0]++')
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

# Record the ext/ packs the kit installed in <cfg>: the core packs and the recorded
# extensions. Called after write_list.
write_packs() {
  local cfg="$1" reg="$2"
  {
    echo "# Skill packs bin/skills.sh installed in this project. When a kit update drops one"
    echo "# from skill-registry.json, update.sh removes it; ext/ folders not listed here stay."
    { tier_ids "$reg" core; recorded_extensions "$cfg" "$reg"; } | awk 'NF' | sort -u
  } > "$cfg/skills/$PACKS_FILE"
}

# Remove the packs a previous kit installed in <cfg> that this registry no longer
# lists: an ext/ folder named in kit-packs.txt or extensions.txt, an upstream pack
# by its lock, and staging folders a killed add left. Folders the user made stay.
prune_orphans() {
  local cfg="$1" reg="$2" known managed dir id lock
  known="$(registry_rows "$reg" | cut -f1)"
  managed="$(cat "$cfg/skills/$PACKS_FILE" "$cfg/skills/$LIST_FILE" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' || true)"
  for dir in "$cfg"/skills/ext/*; do
    [ -d "$dir" ] || continue
    id="$(basename "$dir")"
    case "$id" in
      *.partial.*) id="${id%%.partial.*}" ;;
      *) if has_line "$known" "$id"; then continue; fi ;;
    esac
    has_line "$known" "$id" || has_line "$managed" "$id" || continue
    rm -rf "${dir:?}"
    case "$dir" in *.partial.*) ;; *) echo "- Removed $id: this kit version no longer ships it" ;; esac
  done
  for lock in "$cfg"/skills/*.lock; do
    [ -f "$lock" ] || continue
    id="$(basename "$lock" .lock)"
    valid_name "$id" || continue
    if has_line "$known" "$id"; then continue; fi
    grep -q 'skills.sh and update.sh manage this file' "$lock" || continue
    remove_upstream "$cfg" "$id"
    echo "- Removed $id: this kit version no longer ships it"
  done
}

summary() {
  local reg="$1" keep="$2" name="$3" ext
  ext="$(printf '%s\n' "$keep" | awk 'NF' | tr '\n' ' ')"
  echo "✓ Skill packs: core $(tier_ids "$reg" core | tr '\n' ' ')| extensions: ${ext:-none}"
  echo "  Add an extension when a task needs it: bash $name/bin/skills.sh add <id> (list: bash $name/bin/skills.sh list)"
}

cmd_select() {
  local src="$1" dst="$2" reg="$1/skills/skill-registry.json" recorded keep extensions id
  shift 2
  check_registry "$reg"
  recorded="$(recorded_extensions "$dst" "$reg")"
  # keep is the project's extension list, so --with naming a core pack is a no-op rather
  # than a line in extensions.txt that the next prune would warn about and drop.
  extensions="$(tier_ids "$reg" extension)"
  keep="$( { printf '%s\n' "$recorded"; expand_ids "$reg" "$@"; } | awk 'NF && !seen[$0]++' \
    | while IFS= read -r id; do if has_line "$extensions" "$id"; then echo "$id"; fi; done)"
  drop_others "$src" "$reg" "$keep"
  prune_orphans "$dst" "$reg"
  # Upstream packs are not in the kit checkout: fetch the wanted ones into the project.
  for id in $(wanted_upstream "$reg" "$keep"); do
    ensure_upstream "$reg" "$dst" "$id" && continue
    echo "! $id was not installed; retry with: bash $(basename "$dst")/bin/skills.sh add $id" >&2
    has_line "$recorded" "$id" || keep="$(printf '%s\n' "$keep" | grep -vxF -- "$id" || true)"
  done
  write_list "$dst" "$keep"
  write_packs "$dst" "$reg"
  summary "$reg" "$keep" "$(basename "$dst")"
}

cmd_prune() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" keep id stripped
  [ -f "$reg" ] || return 0
  check_registry "$reg"
  keep="$(recorded_extensions "$CONFIG_DIR" "$reg")"
  drop_others "$CONFIG_DIR" "$reg" "$keep"
  prune_orphans "$CONFIG_DIR" "$reg"
  # update.sh copies the packs itself and then calls this, so the surfaces a pack loads
  # on its own are stripped here rather than in that copy — which also cleans a project
  # installed before the kit stripped them at all.
  stripped="$(strip_pack_load_surfaces "$CONFIG_DIR/skills/ext"/*/)"
  [ "$stripped" = 0 ] || echo "- Removed $stripped pack-local instruction file(s) and .claude/ from skills/ext/"
  # Installed upstream packs move to the commit this kit version pins.
  for id in $(wanted_upstream "$reg" "$keep"); do
    if ! ensure_upstream "$reg" "$CONFIG_DIR" "$id"; then
      echo "! $id was not updated; retry with: bash $CONFIG_NAME/bin/skills.sh add $id" >&2
    fi
  done
  write_list "$CONFIG_DIR" "$keep"
  write_packs "$CONFIG_DIR" "$reg"
  summary "$reg" "$keep" "$CONFIG_NAME"
  cmd_budget
}

# Extensions this project has not installed. Hub links into them dangle until
# skills.sh add, so resync.sh lists them instead of reporting broken paths.
cmd_uninstalled() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" keep id
  [ -f "$reg" ] || return 0
  check_registry "$reg"
  keep="$(recorded_extensions "$CONFIG_DIR" "$reg")"
  for id in $(tier_ids "$reg" extension); do
    has_line "$keep" "$id" || echo "$id"
  done
}

# Copy kit pack <from> to <dest> through a staging folder beside it, so <dest> is
# either the whole pack or absent. A killed copy leaves only <id>.partial.*, which
# the next add of <id> removes. STAGING names the folder for cmd_add's exit trap.
STAGING=""
copy_pack() {
  local from="$1" dest="$2" old
  rm -rf "${dest:?}".partial.*
  STAGING="$(mktemp -d "$dest.partial.XXXXXX")" || return 1
  # Vendored copy: drop submodule gitfiles, whose gitdir only exists in the kit
  # checkout, and the surfaces the pack would load into a session from here — its own
  # .claude/ and its instruction files. Both on the staging folder, so the kit
  # checkout <from> is never written to.
  if ! { cp -R "$from/." "$STAGING" && find "$STAGING" -name .git -prune -exec rm -rf {} + \
        && strip_pack_load_surfaces "$STAGING" >/dev/null; }; then
    rm -rf "$STAGING"; STAGING=""
    return 1
  fi
  old=""
  if [ -e "$dest" ]; then old="$STAGING.old" && mv "$dest" "$old"; fi
  mv "$STAGING" "$dest" || return 1
  STAGING=""
  [ -z "$old" ] || rm -rf "$old"
}

cmd_add() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" ids id todo="" upstream="" failed="" force="" src tmp="" url branch local_src extensions args=() paths=()
  for id in "$@"; do
    case "$id" in
      -f|--force) force=force ;;
      -*) die "unknown option '$id' (use: skills.sh add [--force] <id>...)" ;;
      *) args+=("$id") ;;
    esac
  done
  [ "${#args[@]}" -gt 0 ] || die "usage: skills.sh add [--force] <id> [<id>...] (see: skills.sh list)"
  check_registry "$reg"
  trap 'rm -rf ${tmp:+"$tmp"} ${STAGING:+"$STAGING"}' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ids="$(expand_ids "$reg" "${args[@]}")"
  for id in $ids; do
    if has_line "$(upstream_ids "$reg")" "$id"; then
      if [ -z "$force" ] && upstream_current "$reg" "$CONFIG_DIR" "$id"; then echo "✓ $id is already installed"; else upstream="$upstream $id"; fi
    elif [ -z "$force" ] && installed "$CONFIG_DIR" "$id"; then echo "✓ $id is already installed (reinstall: skills.sh add --force $id)"; else todo="$todo $id"; fi
  done
  if [ -n "$todo" ]; then
    local_src="${SOLANA_AI_KIT_LOCAL_SRC:-${SOLANA_CLAUDE_LOCAL_SRC:-}}"
    if [ -n "$local_src" ] && [ -d "$local_src/.claude/skills/ext" ]; then
      src="$local_src"
    else
      url="${SOLANA_AI_KIT_UPSTREAM:-${SOLANA_CLAUDE_UPSTREAM:-https://github.com/solanabr/ai-kit.git}}"
      # The pins this install checks against are its own release's, and an install now
      # tracks release tags (#125), so fetch the tag its VERSION names rather than main,
      # whose pins move every week. Releases up to v2.4.0 predate tag tracking, so those
      # installs may hold main's content under that VERSION: they keep fetching main. A
      # tag that cannot be cloned (a VERSION nobody tagged yet) falls back to main too.
      branch="${SOLANA_AI_KIT_BRANCH:-${SOLANA_CLAUDE_BRANCH:-}}"
      if [ -z "$branch" ]; then
        # The floor is kit-ref.sh's TAG_FLOOR and install.sh's; tests/test_kit_ref.sh
        # holds all three copies to one value.
        branch="$(awk -v floor="2.4.0" '{ v = $NF; split(v, x, "."); split(floor, y, ".")
          if (v !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) next
          for (i = 1; i <= 3; i++) if (x[i] + 0 != y[i] + 0) { if (x[i] + 0 > y[i] + 0) print "v" v; next } }' \
          "$CONFIG_DIR/VERSION" 2>/dev/null || true)"
      fi
      tmp="$(mktemp -d)"
      echo "Fetching the pinned packs from $(redact_url "$url") (${branch:-main})..."
      if [ -z "${SOLANA_AI_KIT_BRANCH:-${SOLANA_CLAUDE_BRANCH:-}}" ] && [ -n "$branch" ]; then
        # git's own error goes with the fallback notice: a tag nobody pushed and a network
        # or auth failure fail alike here, and only git can say which one this was.
        git clone -q --depth 1 --branch "$branch" "$url" "$tmp/kit" 2>"$tmp/clone.err" \
          || { echo "  could not clone $branch ($(tail -n 1 "$tmp/clone.err" 2>/dev/null)); trying main, so the pins checked below are main's" >&2
               rm -rf "${tmp:?}/kit"; branch=""; }
      fi
      [ -d "$tmp/kit" ] || git clone -q --depth 1 --branch "${branch:-main}" "$url" "$tmp/kit"
      for id in $todo; do paths+=(".claude/skills/ext/$id"); done
      # Not --recursive: a pack's own submodules are pinned by its author, not by this
      # kit, and add would vendor that tree into the project at a pin nobody here
      # records. The registry's "vendored" field keeps those pins visible instead.
      git -C "$tmp/kit" submodule update -q --init --depth 1 --jobs 8 -- "${paths[@]}"
      src="$tmp/kit"
    fi
    mkdir -p "$CONFIG_DIR/skills/ext"
    for id in $todo; do
      [ -n "$(ls -A "$src/.claude/skills/ext/$id" 2>/dev/null)" ] \
        || die "$id is empty in $src (run: git submodule update --init there)"
      check_pin "$reg" "$src" "$id" || die "$id is not at its recorded pin in $src; nothing was installed"
      copy_pack "$src/.claude/skills/ext/$id" "${CONFIG_DIR:?}/skills/ext/${id:?}" \
        || die "could not copy $id into $CONFIG_NAME/skills/ext/ (nothing was installed for it)"
      echo "✓ Installed $id in $CONFIG_NAME/skills/ext/$id"
    done
  fi
  for id in $upstream; do
    ensure_upstream "$reg" "$CONFIG_DIR" "$id" "$force" || failed="$failed $id"
  done
  extensions="$(tier_ids "$reg" extension)"
  write_list "$CONFIG_DIR" "$(recorded_extensions "$CONFIG_DIR" "$reg")" \
    "$(for id in $ids; do if has_line "$extensions" "$id" && ! has_word "$failed" "$id"; then echo "$id"; fi; done)"
  write_packs "$CONFIG_DIR" "$reg"
  cmd_budget
  [ -z "$failed" ] || die "not installed:$failed"
}

# Registry pins against the gitlinks of a kit checkout (default: this install's root).
# Read-only, so validate.sh and CI can run it; --write rewrites each submodule entry's
# commit from its gitlink, which is how a Dependabot bump becomes a registry change in
# the same pull request. Nothing here touches an upstream pack's commit: that one is a
# fetch target, not a gitlink, and skills.sh asserts it against FETCH_HEAD instead.
#
# Always reports "checked N of M", because a pack with no gitlink in <root> is not
# verified by anything: there is no content hash of a pack anywhere, so the gitlink is
# the only evidence that what is about to be copied is what the registry names. A source
# with no gitlinks at all (a tarball, a mirror, a fork with ext/ as plain files) verifies
# nothing. Both of those exit 0 — a pack-free tree is legitimate and must not fail a
# build — but neither leads with the ✓ that callers key on for a clean result.
cmd_pins() {
  local write="" root="" arg reg id path want have tmp upstream drift=0 checked=0 total=0 skipped="" pins=""
  for arg in "$@"; do
    case "$arg" in
      -w|--write) write=write ;;
      -*) die "unknown option '$arg' (use: skills.sh pins [--write] [<kit repo root>])" ;;
      *) root="$arg" ;;
    esac
  done
  if [ -n "$root" ]; then
    reg="$root/.claude/skills/skill-registry.json"
    [ -f "$reg" ] || reg="$root/.agents/skills/skill-registry.json"
  else
    root="$(cd "$CONFIG_DIR/.." && pwd)"
    reg="$CONFIG_DIR/skills/skill-registry.json"
  fi
  check_registry "$reg"
  upstream="$(upstream_ids "$reg")"
  # A core plugin is pinned in the marketplace, not by a gitlink: test_skill_extensions
  # holds its commit to that pin instead.
  for id in $(registry_rows "$reg" | awk -F'\t' '$2 != "core-plugin" { print $1 }'); do
    has_line "$upstream" "$id" && continue
    total=$((total + 1))
    path="$(entry_value "$reg" "$id" path)"
    want="$(entry_value "$reg" "$id" commit)"
    have="$(gitlink "$root" "$path")"
    if [ -z "$have" ]; then
      skipped="$skipped $id"
      continue
    fi
    checked=$((checked + 1))
    pins="$pins$path $have
"
    [ "$have" = "$want" ] && continue
    drift=$((drift + 1))
    echo "$id: gitlink ${have:0:12}, registry ${want:0:12}"
  done
  if [ "$checked" = 0 ]; then
    echo "Checked 0 of $total submodule pins: $root carries no gitlinks, so nothing verified what the packs hold — the registry's commits are a record here, not a check."
    return 0
  fi
  if [ "$drift" = 0 ]; then
    if [ "$checked" != "$total" ]; then
      echo "Checked $checked of $total submodule pins (all matching); the other $((total - checked)) have no gitlink in $root and are unverified: $(short_list "$skipped")."
      return 0
    fi
    echo "✓ All $checked submodule pins match the registry"
    return 0
  fi
  if [ "$write" != write ]; then
    echo "$drift of the $checked pins checked differ (of $total pinned). Rewrite the registry from the gitlinks: bash $CONFIG_NAME/bin/skills.sh pins --write" >&2
    return 1
  fi
  tmp="$(mktemp -d)" || return 1
  printf '%s' "$pins" > "$tmp/pins"
  # Each entry lists "path" then "commit", so the path line selects the commit line to rewrite.
  if awk 'NR == FNR { want[$1] = $2; next }
    /^    \{/ { path = "" }
    /^      "path": "\.claude\/skills\/ext\// { split($0, f, "\""); path = f[4] }
    /^      "commit": "/ && path != "" && (path in want) {
      printf "      \"commit\": \"%s\",\n", want[path]; path = ""; next }
    { print }' "$tmp/pins" "$reg" > "$tmp/registry.json" && mv "$tmp/registry.json" "$reg"; then
    rm -rf "$tmp"
    check_registry "$reg"
    echo "✓ Rewrote $drift pin(s) in $(basename "$reg") from the gitlinks"
  else
    rm -rf "$tmp"
    die "could not rewrite $reg"
  fi
}

# Codex splits one description budget (~22 KB) evenly across every skill it registers
# and cuts each description to its share with no marker; far enough past it, it lists
# names with no description and then drops skills outright, so it cannot route to them
# (#212). Measured on codex-cli 0.155-0.156 against --agents installs: 42 project skills
# all whole, sendai's 57 with 11 cut. It is a count of SKILL.md files, not of packs —
# sendai alone ships 49 — and Codex's built-in and user-level skills share the same
# budget, so the line sits below the first measured cut rather than at it. Claude Code
# and Grok are not affected: a .claude/ install is never checked. opencode has no cap at
# all and carries every description in every session, which this cannot warn about.
CODEX_SKILL_LIMIT=45

# The skills Codex registers from this install: every SKILL.md under skills/, at any
# depth, except inside dot-directories, which neither Codex nor opencode scans.
registered_skills() {
  find "$1/skills" -mindepth 1 -name '.*' -prune -o -name SKILL.md -print 2>/dev/null | wc -l | tr -d ' '
}

same_skill_copy() {  # same_skill_copy <copy> <kept>: every file in <copy> is in <kept>, byte-identical
  local f
  [ -z "$(find "$1" -type l -print -quit)" ] || return 1
  while IFS= read -r f; do
    cmp -s "$1/$f" "$2/$f" || return 1
  done < <(cd "$1" && find . -type f)
}

kit_links_to() {  # kit_links_to <cfg> <path under skills/>: a kit file outside ext/ names it
  grep -rqF --exclude-dir=ext -- "$2/" "$1" 2>/dev/null \
    || grep -qF -- "$2/" "$1/../AGENTS.md" 2>/dev/null
}

# Some packs ship the same skill twice or three times, one copy per layout they publish
# — skills/<name>/ for Agent Skills clients and plugins/<p>/skills/<name>/ for a Claude
# Code plugin (alchemy, mongodb, redis). Codex and opencode find SKILL.md at any depth,
# so under .agents/ each copy registers under the same name (#212): Codex lists every
# copy and pays a share of its budget for each, while opencode keeps one per name.
# Within one pack, a copy whose every file is byte-identical to a file in another
# copy of that name is removed from this install, keeping one: a copy the kit links
# to, otherwise the shallowest, then the first by path. Nothing that differs is
# removed, nor a pack's root or a copy any kit file links to, so no content and no
# kit link is lost. Only for .agents/ (cmd_budget): Claude Code does not register
# skills nested inside ext/, and a .claude/ install keeps each pack exactly as pinned.
# Prints how many copies it removed.
drop_duplicate_skills() {
  local cfg="$1" tab pack id rows name copies kept rel removed=0
  tab="$(printf '\t')"
  for pack in "$cfg"/skills/ext/*/; do
    [ -d "$pack" ] || continue
    pack="${pack%/}"
    id="$(basename "$pack")"
    # name<TAB>depth<TAB>dir (relative to the pack, "." for its root) of every SKILL.md.
    rows="$(find "$pack" -mindepth 1 -name '.*' -prune -o -name SKILL.md -print 2>/dev/null \
      | while IFS= read -r rel; do
          rel="$(dirname "$rel")"; rel="${rel#"$pack"}"; rel="${rel#/}"; rel="${rel:-.}"
          printf '%s\t%s\t%s\n' "$(skill_name "$pack/$rel/SKILL.md")" \
            "$(printf '%s' "$rel" | tr -cd / | wc -c | tr -d ' ')" "$rel"
        done | LC_ALL=C sort -t "$tab" -k1,1 -k2,2n -k3,3)"
    for name in $(printf '%s\n' "$rows" | cut -f1 | awk 'NF' | uniq -d); do
      valid_name "$name" || continue
      copies="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1 == n { print $3 }')"
      kept=""
      while IFS= read -r rel; do
        if [ "$rel" != . ] && kit_links_to "$cfg" "ext/$id/$rel"; then kept="$rel"; break; fi
      done <<< "$copies"
      [ -n "$kept" ] || kept="$(printf '%s\n' "$copies" | sed -n 1p)"
      while IFS= read -r rel; do
        [ "$rel" != "$kept" ] && [ "$rel" != . ] || continue
        case "$kept/" in "$rel"/*) continue ;; esac   # holds the kept copy
        if kit_links_to "$cfg" "ext/$id/$rel"; then continue; fi
        same_skill_copy "$pack/$rel" "$pack/$kept" || continue
        rm -rf "${pack:?}/${rel:?}"
        removed=$((removed + 1))
      done <<< "$copies"
    done
  done
  echo "$removed"
}

# Names still registered more than once from skills/: different skills that share a
# name, across packs (helius in helius and sendai) or within one (helius's per-harness
# variants), plus any copy drop_duplicate_skills kept. Their content differs, so no
# rule here can pick one without dropping a real skill; the user decides by removing a
# pack. Prints "<name> (<dir>, <dir>)" lines, each dir relative to skills/.
duplicate_skill_names() {
  local root="$1/skills" f rel
  find "$root" -mindepth 1 -name '.*' -prune -o -name SKILL.md -print 2>/dev/null \
    | while IFS= read -r f; do
        rel="${f#"$root"/}"
        [ "$rel" = SKILL.md ] || rel="${rel%/SKILL.md}"
        printf '%s\t%s\n' "$(skill_name "$f")" "$rel"
      done | LC_ALL=C sort \
    | awk -F'\t' '$1 != "" { n[$1]++; w[$1] = w[$1] (w[$1] == "" ? "" : ", ") $2 }
        END { for (k in n) if (n[k] > 1) print k " (" w[k] ")" }' | LC_ALL=C sort
}

# The duplicate-name warning comes from packs the user chose, and only removing a pack
# changes it, so printed on every add, /update and install it is noise that buries the
# budget warning after it. It prints when the set of names differs from the one
# recorded in skills/$DUPES_FILE, which it then rewrites: once per change, whether a
# pack added a name or dropped one. No duplicates left, no file.
cmd_budget() {
  local n removed dupes names rec
  [ "$CONFIG_NAME" = ".agents" ] || return 0
  removed="$(drop_duplicate_skills "$CONFIG_DIR")"
  [ "${removed:-0}" = 0 ] || echo "✓ Removed $removed duplicate skill copies packs ship twice (byte-identical), so each registers once"
  dupes="$(duplicate_skill_names "$CONFIG_DIR")"
  names="$(printf '%s\n' "$dupes" | awk 'NF { print $1 }')"
  rec="$CONFIG_DIR/skills/$DUPES_FILE"
  if [ -z "$names" ]; then
    rm -f "$rec"
  elif [ "$names" != "$(awk '!/^#/ && NF { print $1 }' "$rec" 2>/dev/null || true)" ]; then
    {
      echo "! $(printf '%s\n' "$names" | grep -c .) skill names are registered more than once from $CONFIG_NAME/skills/: $(short_list "$(printf '%s\n' "$names" | tr '\n' ' ')")"
      echo "  Mostly different skills that share a name. Codex lists every copy, each taking a share of its"
      echo "  description budget; opencode keeps one per name. Where each comes from: bash $CONFIG_NAME/bin/skills.sh duplicates"
      echo "  Said once: this repeats only when that set changes ($CONFIG_NAME/skills/$DUPES_FILE)."
    } >&2
    {
      echo "# Skill names registered more than once, as bin/skills.sh last reported them. It warns"
      echo "# again only when this set changes; delete this file to see the warning again."
      printf '%s\n' "$names"
    } > "$rec" 2>/dev/null || true
  fi
  n="$(registered_skills "$CONFIG_DIR")"
  [ "${n:-0}" -gt "$CODEX_SKILL_LIMIT" ] || return 0
  {
    echo "! $n skills are registered from $CONFIG_NAME/skills/, past the ~$CODEX_SKILL_LIMIT Codex's shared description budget holds."
    echo "  Codex shortens every description to fit, without saying so, and well past it drops them, so it stops routing to those skills."
    echo "  To remove an extension: delete its line from $CONFIG_NAME/skills/$LIST_FILE, then run: bash $CONFIG_NAME/bin/skills.sh prune"
  } >&2
}

cmd_list() {
  local reg="$CONFIG_DIR/skills/skill-registry.json" id tier trig state
  check_registry "$reg"
  printf '%-20s %-11s %-10s %s\n' PACK TIER STATE "INSTALL WHEN THE TASK INVOLVES"
  registry_rows "$reg" | while IFS=$'\t' read -r id tier trig; do
    state="-"
    if [ "$tier" = core-plugin ]; then state=plugin
    elif installed "$CONFIG_DIR" "$id"; then state=installed; fi
    printf '%-20s %-11s %-10s %s\n' "$id" "$tier" "$state" "$trig"
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
  pins) shift; cmd_pins "$@" ;;
  budget) cmd_budget ;;
  duplicates) duplicate_skill_names "$CONFIG_DIR" ;;
  -h|--help|help) sed -n '4,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (use: list, add <id>...)" ;;
esac
