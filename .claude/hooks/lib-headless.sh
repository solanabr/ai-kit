#!/bin/sh
# lib-headless.sh — shared helpers for the solana-ai-kit firewall hooks.
#
# Sourced (never executed) by secrets-guard.sh, onchain-guard.sh and
# egress-guard.sh.  POSIX sh only: no bash builtins, no arrays, no [[ ]].
#
# Why this file exists: under `claude -p` an `ask` decision is a hard failure,
# so a hook that would prompt has to stay silent when there is nobody to
# prompt.  kit_ask does that.  The exception is the irreversible set (mainnet
# writes, npm/cargo publish, --final / finalize / authorize --disable): those
# deny instead of going quiet, so headless never becomes a free pass.
#
# Contract for callers:
#   KIT_INPUT=$(cat); . lib-headless.sh; kit_parse
#   then kit_ask "reason" | kit_deny "reason" | kit_gate mainnet "reason"
#
# Environment knobs (all optional):
#   KIT_FIREWALL_TIER      off|relaxed|medium|high   overrides .claude/security.json
#   KIT_FIREWALL_HEADLESS  1 force headless, 0 force interactive (tests use 0)
#   CONFIRM_MAINNET=1      allow a mainnet write to proceed headless
#   CONFIRM_PUBLISH=1      allow npm/cargo publish to proceed headless

# ---------------------------------------------------------------- JSON in

# kit_field <key> — .tool_input.<key>, falling back to Grok Build's camelCase
# .toolInput.<key>.  Reading only one of the two makes every hook silently
# permit on Grok while still looking healthy here.
#
# The no-jq / malformed-payload path is awk, not sed: the obvious sed pattern
# needs \| alternation to walk JSON string escapes, and BSD sed (every macOS
# install) does not support \| in a BRE, so it silently matches nothing.
kit_field() {
  if [ -n "${KIT_HAVE_JQ-}" ]; then
    printf '%s' "$KIT_INPUT" | jq -r --arg k "$1" \
      '(.tool_input[$k] // .toolInput[$k] // .[$k] // empty) | if type=="string" then . else tostring end' \
      2>/dev/null && return 0
  fi
  printf '%s' "$KIT_INPUT" | KIT_KEY="$1" awk '
    function ws(s) { while (substr(s,1,1) == " " || substr(s,1,1) == "\t" || substr(s,1,1) == "\n" || substr(s,1,1) == "\r") s = substr(s,2); return s }
    BEGIN { RS = "\004"; k = "\"" ENVIRON["KIT_KEY"] "\"" }
    {
      p = index($0, k); if (p == 0) exit
      s = ws(substr($0, p + length(k)))
      if (substr(s,1,1) != ":") exit
      s = ws(substr(s,2))
      if (substr(s,1,1) != "\"") exit
      s = substr(s,2)
      out = ""; buf = ""
      for (i = 1; i <= length(s); i++) {
        if (length(buf) > 2000) { out = out buf; buf = "" }
        c = substr(s,i,1)
        if (c == "\\") {
          d = substr(s,i+1,1); i++
          if (d == "n") buf = buf "\n"
          else if (d == "t") buf = buf "\t"
          else if (d == "r") buf = buf "\r"
          else if (d == "u") i += 4
          else buf = buf d
          continue
        }
        if (c == "\"") break
        buf = buf c
      }
      printf "%s", out buf
    }' 2>/dev/null
}

# kit_parse — fills KIT_CMD, KIT_PERMISSION_MODE, KIT_CWD from $KIT_INPUT.
#
# One jq invocation, not one per field: jq costs ~25 ms to start and three
# hooks fire on every Bash call.  The command field goes last because command
# substitution eats trailing newlines and a heredoc command has interior ones.
kit_parse() {
  command -v jq >/dev/null 2>&1 && KIT_HAVE_JQ=1 || KIT_HAVE_JQ=
  KIT_CMD= KIT_PERMISSION_MODE= KIT_CWD=
  if [ -n "$KIT_HAVE_JQ" ]; then
    _sep=$(printf '\001')
    _j=$(printf '%s' "$KIT_INPUT" | jq -r '
      def g($k): (.tool_input[$k] // .toolInput[$k] // .[$k] // "");
      def s($v): if ($v | type) == "string" then $v else ($v | tostring) end;
      [s(.permission_mode // .permissionMode // ""), s(.cwd // ""), s(g("command"))]
      | join("")' 2>/dev/null) || _j=
    if [ -n "$_j" ]; then
      KIT_PERMISSION_MODE=${_j%%"$_sep"*}
      _r=${_j#*"$_sep"}
      KIT_CWD=${_r%%"$_sep"*}
      KIT_CMD=${_r#*"$_sep"}
    fi
  fi
  # jq absent, or the payload was not valid JSON: fall back to text extraction
  # rather than letting a truncated payload through unexamined.
  [ -n "$KIT_CMD" ] || KIT_CMD=$(kit_field command 2>/dev/null) || KIT_CMD=
  case $KIT_CMD in null) KIT_CMD= ;; esac
  case $KIT_PERMISSION_MODE in null) KIT_PERMISSION_MODE= ;; esac
  [ -n "$KIT_CWD" ] && [ -d "$KIT_CWD" ] || KIT_CWD=$PWD
}

# ---------------------------------------------------------------- tier

# kit_tier — off|relaxed|medium|high.  Default relaxed, matching the spec.
kit_tier() {
  _t=${KIT_FIREWALL_TIER-}
  if [ -z "$_t" ]; then
    for _d in "${CLAUDE_PROJECT_DIR-}" "${KIT_CWD-}" "$PWD"; do
      [ -n "$_d" ] && [ -r "$_d/.claude/security.json" ] || continue
      _t=$(sed -n 's/.*"tier"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' \
        "$_d/.claude/security.json" 2>/dev/null | head -n 1)
      [ -n "$_t" ] && break
    done
  fi
  _t=$(printf '%s' "$_t" | tr '[:upper:]' '[:lower:]')
  case $_t in
    off | relaxed | medium | high) printf '%s' "$_t" ;;
    *) printf 'relaxed' ;;
  esac
}

# kit_tier_num <tier> — 0..3, for "at Medium or above" comparisons.
kit_tier_num() {
  case $1 in off) printf 0 ;; relaxed) printf 1 ;; medium) printf 2 ;; high) printf 3 ;; *) printf 1 ;; esac
}

# ---------------------------------------------------------------- headless

# kit_is_headless — true when there is no interactive user to answer a prompt.
# Order: explicit override, CI markers, then whether a controlling terminal can
# actually be opened.  A hook's own stdio is always a pipe, so [ -t 1 ] tells
# us nothing; /dev/tty does.  permission_mode is only a tiebreaker: its absence
# means an older or third-party harness, which we would read as non-interactive
# only when the terminal probe also failed — the same answer, so the probe
# decides on its own and KIT_PERMISSION_MODE stays informational.
kit_is_headless() {
  case ${KIT_FIREWALL_HEADLESS-} in 1 | true | yes) return 0 ;; 0 | false | no) return 1 ;; esac
  if [ -n "${CI-}${GITHUB_ACTIONS-}${GITLAB_CI-}${BUILDKITE-}${JENKINS_URL-}${TEAMCITY_VERSION-}${CIRCLECI-}${BITBUCKET_BUILD_NUMBER-}${DRONE-}${CODEBUILD_BUILD_ID-}" ]; then
    return 0
  fi
  if (exec 3</dev/tty) 2>/dev/null; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- JSON out

kit_json_escape() {
  printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037' |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
    awk 'NR>1{printf "\\n"} {printf "%s", $0}'
}

_kit_emit() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$1" "$(kit_json_escape "$2")"
}

# kit_ask <reason> — prompt the user.  Silent (no decision, exit 0) when there
# is no user: an ask is a hard failure under -p, and Relaxed has to be CI-safe.
kit_ask() {
  if kit_is_headless; then
    exit 0
  fi
  _kit_emit ask "$1"
  exit 0
}

# kit_deny <reason> — hard block.  Both shapes: the JSON decision for harnesses
# that read stdout, stderr + exit 2 for Claude Code (and for Grok Build, which
# fails open on output it cannot parse).
kit_deny() {
  _kit_emit deny "$1"
  printf '%s\n' "🛑 Blocked: $1" >&2
  exit 2
}

# kit_gate <mainnet|publish|irreversible> <reason> — the irreversible set.
# Interactive: ask, loudly.  Headless: deny, unless the matching CONFIRM_* env
# var is set, because "nobody is watching" must not mean "go ahead".
# `irreversible` has no env escape by design: --final, program-v4 finalize and
# authorize --disable are deny at every tier, and the user runs them by hand.
kit_gate() {
  case $1 in
    mainnet) _c=${CONFIRM_MAINNET-}; _v=CONFIRM_MAINNET ;;
    publish) _c=${CONFIRM_PUBLISH-}; _v=CONFIRM_PUBLISH ;;
    *) kit_deny "$2" ;;
  esac
  if kit_is_headless; then
    case $_c in
      1 | true | yes) exit 0 ;;
      *) kit_deny "$2 No interactive user to confirm this; re-run with $_v=1 if it is intended." ;;
    esac
  fi
  _kit_emit ask "$2"
  exit 0
}

# ---------------------------------------------------------------- shared regexes

# kit_vault_re — the never-allowed set: credential stores, key material,
# wallet vaults, browser profiles, shell history.  Identical at every tier.
# Deliberately NOT included: project .env and project keypairs (readable at
# every tier per spec 3.2), ~/.config/solana/cli/config.yml (3.3), and the
# persistence / exec-on-next-build files (~/.zshenv, ~/.gitconfig,
# ~/.cargo/config.toml, LaunchAgents) — those are permissions-deny +
# sandbox.denyWrite entries, not read blocks.
kit_vault_re() {
  printf '%s' '(^|/)\.ssh($|/)|(^|/)\.gnupg($|/)|(^|/)\.aws($|/)|(^|/)\.config/solana/.*\.json$|(^|/)\.npmrc$|(^|/)(\.netrc|_netrc)$|(^|/)\.git-credentials$|(^|/)\.config/gh/hosts\.ya?ml$|(^|/)\.kube/config$|(^|/)\.cargo/credentials(\.toml)?$|(^|/)\.docker/config\.json$|(^|/)\.pypirc$|(^|/)\.gem/credentials$|(^|/)\.claude/\.credentials\.json$|\.(pem|p12|pfx|jks|keystore|kdbx|asc|ppk)$|(^|/)Library/Keychains($|/)|\.keychain(-db)?$|(^|/)\.local/share/keyrings($|/)|(^|/)\.gnome2/keyrings($|/)|(^|/)\.password-store($|/)|(^|/)\.(zsh_history|zhistory|bash_history|python_history|node_repl_history|psql_history|sqlite_history|lesshst|rediscli_history|mysql_history)$|(^|/)fish/fish_history$|(^|/)Library/Application Support/(Google/Chrome|BraveSoftware|Microsoft Edge|Firefox|Chromium|Vivaldi|Arc|com\.operasoftware)|(^|/)\.config/(google-chrome|BraveSoftware|microsoft-edge|chromium|vivaldi|opera)($|/)|(^|/)\.mozilla/firefox($|/)|AppData/(Local|Roaming)/(Google/Chrome|BraveSoftware|Microsoft/Edge|Mozilla/Firefox|Chromium|Vivaldi|Opera Software)|Local Extension Settings|^moz-extension'
}

# kit_secret_re — the exfil-sensitive set: everything above, plus the files
# that are fine to read locally but must never leave the machine (project
# .env, program and wallet keypairs, generic secret bundles).
kit_secret_re() {
  printf '%s|%s' "$(kit_vault_re)" '(^|/)\.env([.][^/]*)?$|(^|/)id\.json$|keypair[^/]*\.json$|(^|/)secrets?\.(json|ya?ml|toml|env)$|\.key$|(^|/)(service-account|serviceAccount)[^/]*\.json$'
}
