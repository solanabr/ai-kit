#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/helpers.sh"

# A kit hook has to reach a project that was installed before it existed (issue #91).
#
# install.sh copies settings.json only when absent, and nothing else in update.sh writes
# the `hooks` block: the context-mode matcher patch edits an entry that is already there,
# and firewall.sh owns permissions and sandbox and nothing else. So a guard added after a
# project was installed used to arrive as a script on disk with no line running it — the
# state that looks configured and enforces nothing.
#
# What this suite holds update.sh to: it registers a kit hook the project is missing, it
# leaves everything else in that file exactly as it found it, and running it twice gives
# the same file as running it once.

echo "[test_update_settings_migration] /update carries the kit's hooks into an older install"
echo ""

PROJ="$(new_tmp)" || exit 1
WORK="$(new_tmp)" || exit 1
trap 'rm -rf "$PROJ" "$WORK"' EXIT

SETTINGS="$PROJ/.claude/settings.json"
SECURITY="$PROJ/.claude/security.json"

run_update() {
  (cd "$PROJ" && SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash .claude/bin/update.sh "$@") 2>&1
}

# guard_entries <script> — how many hook entries in settings.json run that kit script.
guard_entries() {
  python3 - "$SETTINGS" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
needle, n = sys.argv[2], 0
for entries in (data.get("hooks") or {}).values():
    for entry in entries if isinstance(entries, list) else []:
        for hook in entry.get("hooks") or []:
            if needle in (hook.get("command") or ""):
                n += 1
print(n)
PY
}

# json_slice <key> — one top-level key, canonicalized, for before/after comparison.
json_slice() {
  python3 - "$SETTINGS" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps(data.get(sys.argv[2]), sort_keys=True, separators=(",", ":")))
PY
}

# --- A real install, then an older one made out of it -----------------------
(cd "$PROJ" && git init -q)
SOLANA_AI_KIT_LOCAL_SRC="$REPO_ROOT" bash "$REPO_ROOT/install.sh" "$PROJ" >/dev/null 2>&1

echo "[baseline]"
assert_json_valid "$SETTINGS" "a fresh install has a settings.json"
GUARDS="$(python3 - "$REPO_ROOT/.claude/settings.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
names = set()
for entries in (data.get("hooks") or {}).values():
    for entry in entries if isinstance(entries, list) else []:
        for hook in entry.get("hooks") or []:
            for word in (hook.get("command") or "").split("/"):
                word = word.split('"')[0]
                if word.endswith(".sh"):
                    names.add(word)
print(" ".join(sorted(names)))
PY
)"
TOTAL=$((TOTAL + 1))
if [ -n "$GUARDS" ]; then
  echo "  PASS: the kit registers hook scripts to carry over ($GUARDS)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the kit's settings.json registers no hook script, so this suite proves nothing"
  FAIL=$((FAIL + 1))
fi

PERMS_BEFORE="$(json_slice permissions)"
SANDBOX_BEFORE="$(json_slice sandbox)"

# Roll the project back to a pre-guard install: drop every kit hook entry, keep a hook
# the user wrote, and add settings of their own that must come through untouched.
python3 - "$SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
hooks = data.get("hooks") or {}
for event in list(hooks):
    kept = [
        entry for entry in hooks[event]
        if not any(".sh" in (h.get("command") or "") for h in entry.get("hooks") or [])
    ]
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
hooks.setdefault("PreToolUse", []).insert(0, {
    "matcher": "Write",
    "hooks": [{"type": "command", "command": "echo my-own-hook >&2; exit 0"}],
})
data["hooks"] = hooks
data["model"] = "opusplanner"  # a session setting of the user's
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY

# A pre-guard install has no record either.
python3 - "$SECURITY" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data.pop("hookSetVersion", None)
data.pop("hookSetFingerprint", None)
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY

echo ""
echo "[an older install, before the update]"
for script in $GUARDS; do
  assert_eq "0" "$(guard_entries "$script")" "fixture: $script is not registered"
done
assert_eq "1" "$(guard_entries my-own-hook)" "fixture: the user's own hook is there"

# --- Dry run reports and writes nothing -------------------------------------
echo ""
echo "[dry run]"
BEFORE_SHA="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
DRY_OUT="$(run_update --dry-run)"
assert_contains "$DRY_OUT" "would register" "--dry-run says it would register the kit hooks"
assert_eq "$BEFORE_SHA" "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" "--dry-run writes nothing to settings.json"

# --- The real run -----------------------------------------------------------
echo ""
echo "[update]"
RUN1="$(run_update)"
assert_contains "$RUN1" "registered" "the run reports the hooks it registered"
assert_json_valid "$SETTINGS" "settings.json is still valid JSON"
for script in $GUARDS; do
  assert_eq "1" "$(guard_entries "$script")" "$script is registered exactly once"
done

echo ""
echo "[nothing of the user's was touched]"
assert_eq "1" "$(guard_entries my-own-hook)" "the user's own hook is still there, once"
assert_eq "$PERMS_BEFORE" "$(json_slice permissions)" "permissions untouched (firewall.sh owns them)"
assert_eq "$SANDBOX_BEFORE" "$(json_slice sandbox)" "sandbox untouched"
assert_eq '"opusplanner"' "$(json_slice model)" "a session setting of the user's is untouched"
FIRST_PRE="$(python3 - "$SETTINGS" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1], encoding="utf-8"))["hooks"]["PreToolUse"]
print(entries[0]["hooks"][0]["command"])
PY
)"
assert_contains "$FIRST_PRE" "my-own-hook" "the kit's entries were appended, not inserted ahead of the user's"

# --- Versioned gate ---------------------------------------------------------
echo ""
echo "[gate]"
assert_file_contains "$SECURITY" "hookSetVersion" "the applied hook set is recorded in security.json"
assert_json_valid "$SECURITY" "security.json is still valid JSON"
assert_contains "$(python3 -c "
import json; print(json.load(open('$SECURITY')).get('tier'))")" "relaxed" "the recorded tier is untouched"

# --- Idempotent -------------------------------------------------------------
echo ""
echo "[twice == once]"
AFTER_ONE="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
RUN2="$(run_update)"
assert_eq "$AFTER_ONE" "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" "a second /update leaves settings.json byte-identical"
TOTAL=$((TOTAL + 1))
if printf '%s\n' "$RUN2" | grep -q "] registered"; then
  echo "  FAIL: the second run registered hooks again"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: the second run registers nothing"
  PASS=$((PASS + 1))
fi
RUN3="$(run_update)"
assert_eq "$AFTER_ONE" "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" "a third /update is still byte-identical"

# --- One guard missing: only that one comes back ----------------------------
echo ""
echo "[one guard missing]"
ONE_GUARD="$(printf '%s\n' $GUARDS | head -1)"
python3 - "$SETTINGS" "$SECURITY" "$ONE_GUARD" <<'PY'
import json, sys

settings_path, security_path, needle = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(settings_path, encoding="utf-8"))
for event, entries in (data.get("hooks") or {}).items():
    data["hooks"][event] = [
        entry for entry in entries
        if not any(needle in (h.get("command") or "") for h in entry.get("hooks") or [])
    ]
json.dump(data, open(settings_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)

# The gate has to let the run happen: a project that loses a guard between updates is
# behind the recorded set, which is what a bumped HOOK_SET_VERSION expresses.
security = json.load(open(security_path, encoding="utf-8"))
security["hookSetVersion"] = 0
json.dump(security, open(security_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
assert_eq "0" "$(guard_entries "$ONE_GUARD")" "fixture: $ONE_GUARD removed again"
run_update >/dev/null
assert_eq "1" "$(guard_entries "$ONE_GUARD")" "$ONE_GUARD comes back"
for script in $GUARDS; do
  assert_eq "1" "$(guard_entries "$script")" "$script is still registered exactly once"
done

# --- A guard the user rewrote is left alone ---------------------------------
#
# Identity is the script the command names, not the entry's shape, so a project running
# a guard its own way must not get a second copy of it alongside.
echo ""
echo "[a guard the user rewrote]"
python3 - "$SETTINGS" "$SECURITY" "$ONE_GUARD" <<'PY'
import json, sys

settings_path, security_path, needle = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(settings_path, encoding="utf-8"))
for event, entries in (data.get("hooks") or {}).items():
    data["hooks"][event] = [
        entry for entry in entries
        if not any(needle in (h.get("command") or "") for h in entry.get("hooks") or [])
    ]
data["hooks"].setdefault("PreToolUse", []).append({
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "sh ./tools/%s with-my-own-flags" % needle}],
})
json.dump(data, open(settings_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)

security = json.load(open(security_path, encoding="utf-8"))
security["hookSetVersion"] = 0
json.dump(security, open(security_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
run_update >/dev/null
assert_eq "1" "$(guard_entries "$ONE_GUARD")" "the user's own invocation of $ONE_GUARD is not doubled"
assert_file_contains "$SETTINGS" "with-my-own-flags" "the user's own invocation is still the one that runs"

# --- An install with no settings.json is reported, not rebuilt --------------
echo ""
echo "[no settings.json]"
mv "$SETTINGS" "$WORK/settings.json.away"
reopen_gate() {
  python3 - "$SECURITY" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["hookSetVersion"] = 0
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
}
reopen_gate
NO_SETTINGS_OUT="$(run_update)"
assert_contains "$NO_SETTINGS_OUT" "settings.json is missing" "a project with no settings.json is told, not silently skipped"
assert_file_not_exists "$SETTINGS" "/update does not write a settings.json the project does not have"
mv "$WORK/settings.json.away" "$SETTINGS"

# --- What is still fresh-install-only is said out loud ----------------------
echo ""
echo "[honesty]"
python3 - "$SETTINGS" "$SECURITY" <<'PY'
import json, sys
settings_path, security_path = sys.argv[1], sys.argv[2]
data = json.load(open(settings_path, encoding="utf-8"))
data.pop("enabledPlugins", None)
data.pop("extraKnownMarketplaces", None)
json.dump(data, open(settings_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
security = json.load(open(security_path, encoding="utf-8"))
security["hookSetVersion"] = 0
json.dump(security, open(security_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
PLUGIN_OUT="$(run_update)"
assert_contains "$PLUGIN_OUT" "security plugin is not" "a missing plugin registration is reported rather than assumed"
TOTAL=$((TOTAL + 1))
if python3 -c "
import json,sys
d = json.load(open('$SETTINGS'))
sys.exit(0 if not d.get('enabledPlugins') else 1)"; then
  echo "  PASS: /update does not enable a plugin on the user's behalf"
  PASS=$((PASS + 1))
else
  echo "  FAIL: /update wrote enabledPlugins into the project"
  FAIL=$((FAIL + 1))
fi

print_summary
