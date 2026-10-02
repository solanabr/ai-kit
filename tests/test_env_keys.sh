#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# env-keys.sh is a deliberate hole in the firewall: the tiers deny reading an env file into
# context, and this script is the one audited channel that still answers "is KEY set?". The
# gate is only as narrow as these tests keep it — the load-bearing assertion is that a value
# never reaches stdout, and that no flag, env var or argument can make one.
echo "[test_env_keys] The audited names-and-presence channel for env files"
echo ""

HELPER="$REPO_ROOT/.claude/bin/env-keys.sh"
assert_file_exists "$HELPER" ".claude/bin/env-keys.sh exists"
if [ ! -f "$HELPER" ]; then print_summary; fi
assert_cmd_success "[ -x '$HELPER' ]" ".claude/bin/env-keys.sh is executable"

# A broken env-keys.sh is a silent downgrade: the commands fall back to not knowing. Pin the
# callers so a rename has to update them in the same change.
#
# /cleanup is deliberately NOT in this list: it no longer touches .env at all. It used to
# copy .env.example over it; now it prints that command for the user to run. A command that
# never needs a key's state does not need the helper, and asserting otherwise would push a
# pointless read back into it.
for c in setup-mcp doctor build-app; do
  f="$REPO_ROOT/.claude/commands/$c.md"
  [ -f "$f" ] || continue
  assert_file_contains "$f" "env-keys.sh" "/$c reads env keys through the helper"
done

# The inverse, which is the property that actually matters: no command reads .env directly.
for f in "$REPO_ROOT"/.claude/commands/*.md; do
  BAD="$(grep -nE '(cat|grep|comm|head|tail|source|\.)[[:space:]]+[^|;]*\.env([[:space:]]|$)' "$f" \
    | grep -v '\.env\.example' | grep -v 'env-keys\.sh' || true)"
  assert_eq "" "$BAD" "$(basename "$f" .md) does not read .env directly"
done

WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$WORK"' EXIT

# A marker long and distinctive enough that any leak into stdout is unmistakable.
MARKER="ZmFrZV9zZWNyZXRfbWFya2VyX2RvX25vdF9wcmludA"
FIXTURE="$WORK/.env"
{
  printf '# a comment line\n'
  printf '\n'
  printf 'A_KEY=%s\n' "$MARKER"
  printf 'B_KEY=\n'
  printf 'C_KEY=""\n'
  printf "D_KEY=''\n"
  printf 'export E_KEY=yes\n'
  printf '   F_KEY=indented\n'
  printf 'G_KEY = spaced\n'
  printf 'not a key=value at all\n'
  printf 'this line has no equals sign\n'
  printf '1BAD_KEY=starts with a digit\n'
} > "$FIXTURE"

echo "[parsing]"
set +e
OUT="$(bash "$HELPER" "$FIXTURE" 2>"$WORK/err")"
RC=$?
set -e
assert_eq "0" "$RC" "exit 0 on a readable env file"
assert_eq "" "$(cat "$WORK/err")" "nothing on stderr for a readable env file"
EXPECTED="A_KEY set
B_KEY empty
C_KEY empty
D_KEY empty
E_KEY set
F_KEY set
G_KEY set"
assert_eq "$EXPECTED" "$OUT" "every spelling parses: export, indentation, spaces around =, empty and quoted-empty"

# THE assertion. Everything else in this file exists to protect it.
echo "[no value ever reaches stdout]"
TOTAL=$((TOTAL + 1))
if printf '%s' "$OUT" | grep -qF "$MARKER"; then
  echo "  FAIL: the value leaked into stdout"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: the value never appears in stdout"
  PASS=$((PASS + 1))
fi
# Nor through stderr, nor with a flag, an env var or a second argument. An adversarial
# review named `--raw` as the one addition that would silently destroy the gate.
for extra in --raw --value --values -v --show --print --verbose --json --all --unsafe; do
  set +e
  LEAK="$( (bash "$HELPER" "$FIXTURE" "$extra"; bash "$HELPER" "$extra" "$FIXTURE") 2>&1 )"
  set -e
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$LEAK" | grep -qF "$MARKER"; then
    echo "  FAIL: '$extra' makes env-keys.sh print a value"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: '$extra' does not make env-keys.sh print a value"
    PASS=$((PASS + 1))
  fi
done
for var in ENV_KEYS_RAW ENV_KEYS_SHOW_VALUES SAK_ENV_KEYS_RAW VERBOSE DEBUG RAW; do
  set +e
  LEAK="$(env "$var=1" bash "$HELPER" "$FIXTURE" 2>&1)"
  set -e
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$LEAK" | grep -qF "$MARKER"; then
    echo "  FAIL: \$$var makes env-keys.sh print a value"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: \$$var does not make env-keys.sh print a value"
    PASS=$((PASS + 1))
  fi
done
# Static backstop: the script has exactly one output path for key data, and it emits the
# name plus set|empty. A future `print key, val` would be caught here even if no flag
# reaches it yet.
echo "[static: one output path]"
VALUE_PRINTS="$(grep -vE '^[[:space:]]*#' "$HELPER" \
  | grep -nE '(^|[^[:alnum:]_])(print|printf|echo|cat)[^#]*\$?(val|VALUE|value)' \
  | grep -v 'length(val)' || true)"
TOTAL=$((TOTAL + 1))
if [ -z "$VALUE_PRINTS" ]; then
  echo "  PASS: no statement in env-keys.sh writes a parsed value to any stream"
  PASS=$((PASS + 1))
else
  echo "  FAIL: env-keys.sh has an output path that could carry a value:"
  printf '%s\n' "$VALUE_PRINTS" | sed 's/^/    /'
  FAIL=$((FAIL + 1))
fi

# ── the channel stays narrow ────────────────────────────────────────────────
# A broader path would turn this into a key-name oracle over any credential file.
echo "[path narrowing]"
cp "$FIXTURE" "$WORK/.env.local"
set +e
OUT_LOCAL="$(bash "$HELPER" "$WORK/.env.local" 2>&1)"
RC_LOCAL=$?
set -e
assert_eq "0" "$RC_LOCAL" ".env.local is accepted"
assert_contains "$OUT_LOCAL" "A_KEY set" ".env.local parses like .env"

printf 'SOME_KEY=value\n' > "$WORK/notes.txt"
for bad in "$WORK/notes.txt" /etc/hosts "$WORK/env" "$WORK/environment"; do
  set +e
  BAD_OUT="$(bash "$HELPER" "$bad" 2>&1)"
  BAD_RC=$?
  set -e
  TOTAL=$((TOTAL + 1))
  if [ "$BAD_RC" -eq 1 ] && printf '%s' "$BAD_OUT" | grep -q HELPER_UNAVAILABLE; then
    echo "  PASS: refuses a non-env path with HELPER_UNAVAILABLE: $(basename "$bad")"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: a non-env path was not refused (exit $BAD_RC): $(basename "$bad")"
    FAIL=$((FAIL + 1))
  fi
done

echo "[missing file]"
set +e
MISS_OUT="$(bash "$HELPER" "$WORK/.env.nope" 2>&1)"
MISS_RC=$?
set -e
assert_eq "1" "$MISS_RC" "exit 1 when the env file does not exist"
assert_contains "$MISS_OUT" "HELPER_UNAVAILABLE" "an unreadable file degrades with HELPER_UNAVAILABLE on stderr"

# Default argument: .env in the working directory.
echo "[default path]"
set +e
DEF_OUT="$( (cd "$WORK" && bash "$HELPER") 2>&1 )"
DEF_RC=$?
set -e
assert_eq "0" "$DEF_RC" "no argument reads ./.env"
assert_contains "$DEF_OUT" "A_KEY set" "the default path is ./.env"

# ── installed by install.sh ─────────────────────────────────────────────────
echo "[install]"
INSTALL_TMP="$(new_tmp)" || INSTALL_TMP=""
if [ -z "${INSTALL_TMP:-}" ] || [ ! -d "$INSTALL_TMP" ]; then
  echo "  FAIL: no writable temp dir for the install check"
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
else
  trap 'rm -rf "$WORK" "$INSTALL_TMP"' EXIT
  (cd "$INSTALL_TMP" && git init -q)
  SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$INSTALL_TMP" >/dev/null 2>&1 || true
  assert_file_exists "$INSTALL_TMP/.claude/bin/env-keys.sh" "install.sh installs .claude/bin/env-keys.sh"
  assert_cmd_success "[ -x '$INSTALL_TMP/.claude/bin/env-keys.sh' ]" "the installed env-keys.sh is executable"
fi

print_summary
