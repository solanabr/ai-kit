#!/usr/bin/env bash
set -euo pipefail

# The varlock .env.schema: shipped at the kit root, copied into a project by install.sh in
# both modes when absent, added by /update when missing, never overwritten (the kit's
# missing key blocks are appended instead), and never gitignored, since it holds no values and is meant to be committed. Its key
# parity with .env.example is checked in tests/test_env_keys.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

SCHEMA=".env.schema"
TEMP_DIR="$(new_tmp)" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[test_env_schema] varlock .env.schema template"
echo ""

new_project() { mkdir -p "$TEMP_DIR/$1" && git -C "$TEMP_DIR/$1" init -q && echo "$TEMP_DIR/$1"; }
install_kit() { SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$@" > "$QUIET_LOG" 2>&1 || quiet_fail "install.sh $*"; }
# update_kit <dir> <config dir> [args] — runs the project's own copy of update.sh
update_kit() {
  local dir="$1" cfg="$2"
  shift 2
  (cd "$dir" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$cfg/bin/update.sh" "$@" 2>&1)
}
# ignore_status <dir> <path> — git check-ignore's exit status there: 0 ignored, 1 not,
# 128 not a work tree. Assert the number: 128 fails too and proves nothing about the
# .gitignore. Global and system git config are shut out, so a developer's own
# core.excludesFile cannot decide the result.
ignore_status() {
  local rc=0
  (cd "$1" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$TEMP_DIR/no-xdg" \
    git check-ignore -q "$2") || rc=$?
  echo "$rc"
}
same() { diff "$1" "$2" > /dev/null 2>&1 && echo same || echo differs; }
# keeps_prefix <original> <file> — the file still begins with the original, byte for byte
keeps_prefix() { [ "$(head -c "$(wc -c < "$1")" "$2")" = "$(cat "$1")" ] && echo kept || echo changed; }
# kit_keys_once <file> — every key the kit schema declares appears exactly once
kit_keys_once() {
  local k bad=""
  for k in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$REPO_ROOT/$SCHEMA" | tr -d '='); do
    [ "$(grep -c "^$k=" "$1")" = 1 ] || bad="$bad $k"
  done
  echo "${bad:-all-once}"
}

# A project that already uses varlock, with its own root defaults and keys. .env gets
# every kit key, and varlock treats a key its schema does not declare as required, so
# the kit's key blocks are appended. Each carries its own @optional, so it stays optional
# under this project's @defaultRequired=true, and the project's own lines stay as written.
printf '# @defaultRequired=true\n# ---\nMY_APP_KEY=\n' > "$TEMP_DIR/own-schema"

assert_file_exists "$REPO_ROOT/$SCHEMA" "The kit ships $SCHEMA"

# check_mode <label> <config dir> [--agents]
check_mode() {
  local label="$1" cfg="$2" out p
  shift 2
  echo "[install.sh${1:+ $1}]"
  p="$(new_project "$label-fresh")"
  install_kit "$@" "$p"
  assert_file_exists "$p/$SCHEMA" "install.sh${1:+ $1} writes $SCHEMA"
  assert_eq "same" "$(same "$REPO_ROOT/$SCHEMA" "$p/$SCHEMA")" "...as a copy of the kit's template"
  assert_eq "1" "$(ignore_status "$p" "$SCHEMA")" "...and does not gitignore it (git check-ignore exits 1)"
  assert_eq "0" "$(ignore_status "$p" .env)" "...while .env beside it is ignored, so the check can see an ignore"
  printf '# edited by the user\n' >> "$p/$SCHEMA"
  cp "$p/$SCHEMA" "$TEMP_DIR/edited"
  install_kit "$@" "$p"
  assert_eq "same" "$(same "$TEMP_DIR/edited" "$p/$SCHEMA")" "Re-running install.sh${1:+ $1} keeps an edited $SCHEMA byte for byte"

  p="$(new_project "$label-own")"
  cp "$TEMP_DIR/own-schema" "$p/$SCHEMA"
  install_kit "$@" "$p"
  assert_eq "kept" "$(keeps_prefix "$TEMP_DIR/own-schema" "$p/$SCHEMA")" "install.sh${1:+ $1} keeps a project's own $SCHEMA lines as written"
  assert_eq "all-once" "$(kit_keys_once "$p/$SCHEMA")" "...and appends each kit key it lacked, once"
  assert_eq "1" "$(grep -c '^# ---' "$p/$SCHEMA")" "...without the kit's header"

  echo "[update.sh${1:+ $1}]"
  rm -f "$p/$SCHEMA"
  out="$(update_kit "$p" "$cfg" --dry-run)" || true
  assert_contains "$out" "[would create] $SCHEMA" "update.sh --dry-run reports the missing $SCHEMA"
  assert_file_not_exists "$p/$SCHEMA" "...and writes nothing"
  out="$(update_kit "$p" "$cfg")" || true
  assert_contains "$out" "[created] $SCHEMA" "update.sh adds $SCHEMA to an install that lacks it"
  assert_eq "same" "$(same "$REPO_ROOT/$SCHEMA" "$p/$SCHEMA")" "...as a copy of the kit's template"
  assert_eq "1" "$(ignore_status "$p" "$SCHEMA")" "...and does not gitignore it"
  cp "$TEMP_DIR/own-schema" "$p/$SCHEMA"
  out="$(update_kit "$p" "$cfg")" || true
  assert_eq "kept" "$(keeps_prefix "$TEMP_DIR/own-schema" "$p/$SCHEMA")" "update.sh keeps an existing $SCHEMA's lines as written"
  assert_eq "all-once" "$(kit_keys_once "$p/$SCHEMA")" "...and appends each kit key it lacked, once"
  assert_contains "$out" "[updated] $SCHEMA — kit keys added:" "...and says which"
  out="$(update_kit "$p" "$cfg")" || true
  assert_eq "" "$(printf '%s\n' "$out" | grep -F "$SCHEMA" || true)" "...and a second run has nothing to add or say"
}

check_mode claude .claude
check_mode agents .agents --agents

# A kit key the project declares in another spelling varlock accepts is declared: an
# appended second declaration would win and override the project's own decorators.
echo "[a kit key in the project's own spelling]"
FIRST_KEY="$(grep -m1 -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$REPO_ROOT/$SCHEMA" | tr -d '=')"
n=0
for form in "export $FIRST_KEY=" "  $FIRST_KEY=" "$FIRST_KEY = "; do
  n=$((n + 1)); p="$(new_project "spelling-$n")"
  printf '# ---\n# @required\n%s\n' "$form" > "$p/$SCHEMA"
  install_kit "$p"
  assert_eq "0" "$(grep -cE "^$FIRST_KEY=" "$p/$SCHEMA" || true)" "install.sh reads '$form' as declaring $FIRST_KEY, and adds no second declaration"
done
printf '# ---\n# @required\nexport %s=\n' "$FIRST_KEY" > "$p/$SCHEMA"
out="$(update_kit "$p" .claude)" || true
assert_eq "0" "$(grep -cE "^$FIRST_KEY=" "$p/$SCHEMA" || true)" "update.sh does the same for 'export $FIRST_KEY='"

# A schema the user cannot write is left alone, with the missing keys named, and the
# rest of the run goes on: the merge used to abort /update at that line, every run.
echo "[a schema that cannot be written]"
p="$(new_project readonly)"
install_kit "$p"
cp "$TEMP_DIR/own-schema" "$p/$SCHEMA" && chmod 444 "$p/$SCHEMA"
if [ -w "$p/$SCHEMA" ]; then
  echo "  SKIP: running as a user who can write a read-only file (root?)"
else
  install_kit "$p"
  assert_eq "same" "$(same "$TEMP_DIR/own-schema" "$p/$SCHEMA")" "install.sh leaves a read-only $SCHEMA as it was, and finishes"
  out="$(update_kit "$p" .claude)" || true
  assert_contains "$out" "Update complete" "update.sh finishes over a read-only $SCHEMA"
  assert_contains "$out" "[skipped] $SCHEMA is not writable — kit keys missing:" "...and names the keys it could not add"
  assert_eq "same" "$(same "$TEMP_DIR/own-schema" "$p/$SCHEMA")" "...leaving the file as it was"
fi
chmod 644 "$p/$SCHEMA"

print_summary
