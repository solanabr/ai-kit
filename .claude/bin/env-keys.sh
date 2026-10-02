#!/usr/bin/env bash
# Print the key names in an env file and whether each one has a value.
#
# This is the single audited channel for answering "is HELIUS_API_KEY set?"
# without reading the file into the model's context. It prints one line per
# key -- "NAME set" or "NAME empty" -- and never prints a value.
#
# There is deliberately no flag, env var or argument that makes it print a
# value, and adding one would defeat the firewall tier that allows this
# script while denying .env reads. Keep it that way.
#
# Usage: env-keys.sh [path]        (default: .env)
# Exit:  0 with one line per key; 1 when the file cannot be read, with
#        HELPER_UNAVAILABLE on stderr so callers degrade instead of failing.
set -euo pipefail

FILE="${1:-.env}"

# Narrow the channel to env files. A broader path would turn this into a
# general key-name oracle over any credential file on the machine.
case "$(basename -- "$FILE")" in
  .env|.env.*) ;;
  *)
    echo "HELPER_UNAVAILABLE: refusing a non-env path: $FILE" >&2
    exit 1
    ;;
esac

if [ ! -r "$FILE" ]; then
  echo "HELPER_UNAVAILABLE: cannot read $FILE" >&2
  exit 1
fi

awk '
  /^[[:space:]]*#/   { next }
  /^[[:space:]]*$/   { next }
  {
    line = $0
    sub(/^[[:space:]]*export[[:space:]]+/, "", line)
    sub(/^[[:space:]]+/, "", line)

    eq = index(line, "=")
    if (eq == 0) next

    key = substr(line, 1, eq - 1)
    sub(/[[:space:]]+$/, "", key)
    if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next

    val = substr(line, eq + 1)
    sub(/^[[:space:]]+/, "", val)
    sub(/[[:space:]]+$/, "", val)

    # An empty quoted string counts as empty, not set.
    if (val == "\"\"" || val == "\047\047") val = ""

    print key, (length(val) ? "set" : "empty")
  }
' "$FILE"
