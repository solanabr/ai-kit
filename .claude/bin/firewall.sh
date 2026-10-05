#!/usr/bin/env bash
set -euo pipefail

# Solana AI Kit — agentic firewall tier generator
#
# The only writer of the kit-owned rule block in .claude/settings.json. It replaces
# the generated `permissions` + `sandbox` lists WHOLESALE on every apply; it never
# appends.
#
# Why wholesale: permission lists merge across settings sources and never override.
# Effective policy over N sources is deny = Udenies, ask = Uasks - deny,
# allow = Uallows - deny - ask, with no un-deny and no un-ask primitive, so a layered
# tier system collapses to the strictest tier any layer ever wrote, permanently.
# `!` negation carves only from earlier `path`/`./path` entries in the same file.
# The one layer with a real carve-out is sandbox.filesystem: denyRead + a narrower
# allowRead re-opens the narrow region, and narrowness decides rather than source
# order, so it survives merging. That is why every tier-varying path decision lives
# in sandbox.filesystem and every tier-varying command decision lives in a hook.
#
# What each apply removes: exactly the strings recorded in
# .claude/security.json -> enforced.ruleIds. Every other entry in those lists —
# including rules the user added — is left in place, in its original order, ahead of
# the regenerated block.
#
# Usage:
#   bash .claude/bin/firewall.sh show                 # report declared vs enforced
#   bash .claude/bin/firewall.sh apply                # apply the declared tier
#   bash .claude/bin/firewall.sh apply high           # switch tier and apply
#   bash .claude/bin/firewall.sh apply high --dry-run # report, write nothing
#
# A switch takes effect in the NEXT session: Claude Code reads permission rules once,
# at session start.

usage() {
  cat <<'USAGE'
Usage: firewall.sh <show|apply> [off|relaxed|medium|high] [--dry-run]

  show    Report the declared tier, the enforced tier and any drift.
  apply   Regenerate the kit-owned permissions + sandbox block for a tier.
          With no tier, applies the tier declared in .claude/security.json.

  --dry-run   Report what would change; write nothing.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_NAME="$(basename "$CONFIG_DIR")"
TARGET_DIR="$(cd "$CONFIG_DIR/.." && pwd)"

MODE=""
TIER=""
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    show|apply|set)            [ -n "$MODE" ] || MODE="$arg" ;;
    off|relaxed|medium|high)   TIER="$arg" ;;
    --tier=*)                  TIER="${arg#--tier=}" ;;
    --dry-run|-n)              DRY_RUN=true ;;
    -h|--help)                 usage; exit 0 ;;
    *)                         echo "firewall.sh: unknown argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || MODE="show"
[ "$MODE" = "set" ] && MODE="apply"

SETTINGS="$CONFIG_DIR/settings.json"

# A symlinked config dir or settings file means the bytes we would replace belong to
# something outside this project. Writing through it is never what the user meant.
if [ "$MODE" = "apply" ]; then
  for p in "$CONFIG_DIR" "$SETTINGS"; do
    if [ -L "$p" ]; then
      echo "firewall.sh: refusing to apply — $p is a symlink." >&2
      echo "  The generated block replaces whole lists; following a symlink would rewrite" >&2
      echo "  a file outside this project. Replace the symlink with a real file and retry." >&2
      exit 1
    fi
  done
fi

# Writes under a linked worktree's git common dir are needed for submodule init, and
# that directory sits outside the working tree. Resolve it here (the generator is the
# only place that can) and emit it only when it really is outside the project root.
GIT_COMMON=""
if command -v git >/dev/null 2>&1; then
  GIT_COMMON="$(cd "$TARGET_DIR" && git rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$GIT_COMMON" ] && GIT_COMMON="$(cd "$TARGET_DIR" && cd "$GIT_COMMON" 2>/dev/null && pwd -P || true)"
fi

# python3 does the JSON work, as it already does in update.sh (retire_kit_defaults.py)
# and /doctor. There is no safe shell fallback: a partial rewrite of this file is worse
# than no rewrite, so stop instead of degrading.
if ! command -v python3 >/dev/null 2>&1; then
  echo "firewall.sh: python3 not found — $CONFIG_NAME/settings.json was left unchanged." >&2
  echo "  Install python3 and re-run: bash $CONFIG_NAME/bin/firewall.sh $MODE${TIER:+ $TIER}" >&2
  exit 1
fi

python3 - "$MODE" "$TIER" "$DRY_RUN" "$TARGET_DIR" "$CONFIG_NAME" "$GIT_COMMON" <<'PY'
import hashlib
import json
import os
import re
import sys

MODE, TIER_ARG, DRY, TARGET, CONFIG, GIT_COMMON = sys.argv[1:7]
DRY = DRY == "true"

SETTINGS_REL = CONFIG + "/settings.json"
SECURITY_REL = CONFIG + "/security.json"
SETTINGS = os.path.join(TARGET, SETTINGS_REL)
SECURITY = os.path.join(TARGET, SECURITY_REL)

# Bump whenever the generated corpus changes in a way an existing install needs.
# update.sh compares this against enforced.ruleSetVersion and re-applies the declared
# tier when it is behind, which is the only route by which a rule change reaches a
# project that already has a security.json.
#   1 -> 2: DENY_MCP_ARBITRARY_EXECUTION at Medium and High.
#   2 -> 3: Edit(/.safe-ai-skill/**) in DENY_SELF_PROTECTION, every tier.
#   3 -> 4: DENY_MCP_CLOUDFLARE_EXECUTION at High only; DENY_SELF_PROTECTION became
#           High-only (Off/Relaxed/Medium now permit edits to the installation's own
#           config) EXCEPT the hooks, which moved to DENY_POLICY_ESCAPE and stay denied
#           at every tier; and its blanket Edit(~/.claude/**) was narrowed to the policy
#           surface so agent memory and ~/.claude/CLAUDE.md are writable at High too.
#   4 -> 5: the families three user-facing surfaces promised a gate for and no mechanism
#           covered. DENY_UNRECOVERABLE_REMOTE at every tier (the --receive-pack /
#           --upload-pack / --exec transport overrides, and `gh issue delete`);
#           DENY_GH_API at Medium and High; and `Bash(git -C *)` left the unconditional
#           wrapper set for DENY_WRAPPERS_HIGH. This is the first bump whose net effect
#           at Relaxed and Medium is to REMOVE a rule, which works only because the
#           catch-up in update.sh subtracts enforced.ruleIds before writing the new
#           block. The rest of those promises are hooks, which arrive with hooks/.
RULE_SET_VERSION = 5
TIERS = ("off", "relaxed", "medium", "high")
RANK = {t: i for i, t in enumerate(TIERS)}
MARK = "@@KIT-GROUP@@"          # serializes to a blank line; never the last element

# ===========================================================================
# permissions.allow — identical at every tier
# ===========================================================================
# Convenience, not policy: it only decides what runs without a prompt. Nothing here
# can override a deny. Commands denied below (env, docker exec) are absent on purpose.

ALLOW = [
    [
        "Bash(anchor *)",
        "Bash(cargo build*)",
        "Bash(cargo test*)",
        "Bash(cargo clippy *)",
        "Bash(cargo fmt *)",
        "Bash(cargo audit *)",
        "Bash(cargo install *)",
        "Bash(cargo geiger *)",
        "Bash(cargo check *)",
        "Bash(cargo doc *)",
        "Bash(cargo run *)",
        "Bash(cargo add *)",
        "Bash(cargo remove *)",
        "Bash(cargo update *)",
        "Bash(cargo clean *)",
        "Bash(cargo bench *)",
        "Bash(cargo fix *)",
        "Bash(cargo tree *)",
        "Bash(cargo metadata *)",
        "Bash(rustup *)",
        "Bash(rustfmt *)",
        "Bash(trident *)",
    ],
    [
        "Bash(solana config *)",
        "Bash(solana address *)",
        "Bash(solana balance *)",
        "Bash(solana airdrop *)",
        "Bash(solana program show *)",
        "Bash(solana program dump *)",
        "Bash(solana logs *)",
        "Bash(solana account *)",
        "Bash(solana cluster-version *)",
        "Bash(solana epoch-info *)",
        "Bash(solana slot *)",
        "Bash(solana rent *)",
        "Bash(solana decode *)",
        "Bash(solana transaction-history *)",
        "Bash(solana confirm *)",
        "Bash(solana-keygen *)",
        "Bash(solana-test-validator *)",
        "Bash(surfpool *)",
    ],
    [
        "Bash(npm *)",
        "Bash(yarn *)",
        "Bash(pnpm *)",
        "Bash(bun *)",
        "Bash(npx *)",
        "Bash(node *)",
        "Bash(tsx *)",
        "Bash(tsc *)",
        "Bash(next *)",
        "Bash(vite *)",
        "Bash(vitest *)",
        "Bash(prettier *)",
        "Bash(eslint *)",
        "Bash(create-solana-dapp *)",
    ],
    [
        "Bash(git status *)",
        "Bash(git diff *)",
        "Bash(git log *)",
        "Bash(git show *)",
        "Bash(git add *)",
        "Bash(git commit *)",
        "Bash(git push *)",
        "Bash(git pull *)",
        "Bash(git fetch *)",
        "Bash(git branch *)",
        "Bash(git checkout *)",
        "Bash(git switch *)",
        "Bash(git merge *)",
        "Bash(git rebase *)",
        "Bash(git stash *)",
        "Bash(git tag *)",
        "Bash(git remote *)",
        "Bash(git submodule *)",
        "Bash(git blame *)",
        "Bash(git cherry-pick *)",
        "Bash(gh *)",
    ],
    [
        "Bash(ls *)",
        "Bash(cat *)",
        "Bash(head *)",
        "Bash(tail *)",
        "Bash(grep *)",
        "Bash(rg *)",
        "Bash(find *)",
        "Bash(fd *)",
        "Bash(mkdir *)",
        "Bash(touch *)",
        "Bash(echo *)",
        "Bash(printf *)",
        "Bash(pwd)",
        "Bash(cd *)",
        "Bash(cp *)",
        "Bash(mv *)",
        "Bash(wc *)",
        "Bash(sort *)",
        "Bash(uniq *)",
        "Bash(diff *)",
        "Bash(tree *)",
        "Bash(which *)",
        "Bash(command -v *)",
        "Bash(type *)",
        "Bash(export *)",
        "Bash(date *)",
        "Bash(basename *)",
        "Bash(dirname *)",
        "Bash(realpath *)",
        "Bash(readlink *)",
        "Bash(xargs grep *)",
        "Bash(xargs rg *)",
        "Bash(xargs wc *)",
        "Bash(xargs ls *)",
        "Bash(xargs -0 grep *)",
        "Bash(sed *)",
        "Bash(awk *)",
        "Bash(cut *)",
        "Bash(tr *)",
        "Bash(tee *)",
        "Bash(jq *)",
        "Bash(curl *)",
        "Bash(wget *)",
        "Bash(tar *)",
        "Bash(unzip *)",
        "Bash(du *)",
        "Bash(df *)",
        "Bash(file *)",
        "Bash(stat *)",
        "Bash(sha256sum *)",
        "Bash(md5sum *)",
        "Bash(base64 *)",
        "Bash(openssl *)",
    ],
    [
        "Bash(docker build *)",
        "Bash(docker run *)",
        "Bash(docker compose *)",
        "Bash(docker ps *)",
        "Bash(docker logs *)",
        "Bash(docker images *)",
        "Bash(docker stop *)",
        "Bash(docker inspect *)",
    ],
    [
        "Bash(unity-editor *)",
        "Bash(dotnet *)",
        "Bash(nuget *)",
    ],
    [
        "Bash(python *)",
        "Bash(python3 *)",
        "Bash(pip *)",
        "Bash(pip3 *)",
    ],
    [
        "Bash(avm *)",
        "Bash(solana-verify *)",
        "Bash(mollusk *)",
        "Bash(litesvm *)",
        "Bash(spl-token *)",
        "Bash(just *)",
        "Bash(make *)",
        "Bash(cmake *)",
        "Bash(wasm-pack *)",
        "Bash(cross *)",
        "Bash(cargo-generate *)",
        "Bash(solana-install *)",
        # Kit-owned script, so /add-skill can install the extension pack an agent is
        # told to link into before using it. Only list and add: prune, select and
        # uninstalled still prompt. add fetches commit-pinned packs and writes nothing
        # outside skills/ext/, which is narrower than the curl and npm rules above.
        "Bash(bash .claude/bin/skills.sh list)",
        "Bash(bash .claude/bin/skills.sh add *)",
    ],
    [
        "Read(*)",
        "Edit(*)",
        "Write(*)",
        "Glob(*)",
        "Grep(*)",
        "Agent(*)",
        "WebFetch(*)",
        "WebSearch(*)",
    ],
]

# ===========================================================================
# permissions.deny — the never-allowed set
# ===========================================================================
# Every Bash rule below is byte-identical at every tier, and that is deliberate: deny
# is merge-monotonic, so if a rule reaches a user or managed settings file, descending
# a tier cannot take it back out. Most tier variation therefore lives in a
# sandbox.filesystem path or a hook decision.
#
# Three groups are exceptions, and they are safe for the same reason: firewall.sh owns
# one file and subtracts exactly the strings recorded in enforced.ruleIds, so a descent
# does remove them. The relaxed -> high -> relaxed and high -> medium byte-identity
# tests are the proof. The groups are DENY_SELF_PROTECTION (High only),
# DENY_MCP_ARBITRARY_EXECUTION (Medium and High) and DENY_MCP_CLOUDFLARE_EXECUTION
# (High only). The residual is unchanged: a block hand-copied into user or managed
# scope stops tracking the tier, and those denies then cannot be lifted.
#
# Two matcher facts the patterns below are built around:
#   * A mid-pattern `*` does not match the empty string: Bash(anchor * --final*) did
#     NOT stop `anchor --final`. Every two-wildcard rule therefore ships its zero-gap
#     twin.
#   * A trailing ` *` DOES match the bare command, but only when it is the rule's only
#     wildcard, so Bash(gh auth token *) already covers bare `gh auth token`.

DENY_POLICY_ESCAPE = [
    # Unconditional at every tier, Off included. What these have in common is that none
    # of them is "the user customizing their own installation" — the distinction that
    # makes DENY_SELF_PROTECTION below tier-varying.
    #
    # The hooks are the carve-out out of that distinction, and the reason is not that
    # they are more sensitive but that they are a different kind of thing. "Customizing
    # your installation" describes settings.json exactly: declarative config, tuned by
    # hand. It describes hooks/ badly, because these are executable shell scripts — the
    # mainnet-deploy gate, the keypair-read block and the egress denylist are
    # implemented in them, not declared. The decisive point is that /firewall already
    # changes every tier knob without touching hooks/, so a user who wants to customize
    # has a supported path that never requires editing a guard script. The line falls
    # between the config and the thing enforcing it, not between strict and lenient.
    "Edit(/.claude/hooks/**)",
    "Edit(~/.claude/hooks/**)",
    #
    # A nested `claude -p --dangerously-skip-permissions` re-rolls the whole policy in
    # a child process, and npm/npx/node are allowed. That is not editing a config file,
    # it is starting a second agent with no policy at all, so no tier hands it back.
    # Residuals that cannot be closed from here: --settings, --permission-mode,
    # --setting-sources, CLAUDE_CONFIG_DIR.
    "Bash(claude *)",
    "Bash(claude)",
    # An organization's managed settings belong to the administrator, not to the user
    # whose installation the tiers are about, and they are the one tier an agent cannot
    # talk its way out of. Editing them needs root anyway; the rule costs nothing.
    "Edit(//**/managed-settings.json)",
    # safe-ai-skill deep-merges the whole file over its default policy, so an edit here
    # could loosen any of its gates, spend caps included, not just supply_chain. It is a
    # third-party security tool's policy rather than Claude Code's own configuration, so
    # it is not part of the installation Medium and below hand back.
    "Edit(/.safe-ai-skill/**)",
]

# High only. Every other tier lets the agent edit the installation's own CONFIGURATION —
# but not the hooks, which are in DENY_POLICY_ESCAPE above and denied at every tier.
#
# The rationale is the same one that makes High the only tier to refuse Cloudflare's
# `execute`: below High, the kit defers to a user who chose to customize their setup;
# High is the locked-down tier, where "the agent cannot rewrite what constrains it" is
# part of the proposition. At Off, Relaxed and Medium an agent may now edit
# .claude/settings.json, .claude/security.json, .mcp.json and the user-scope
# equivalents.
#
# Edit(...), not Read(...): a Read deny also blocks Edit and Write but leaves
# NotebookEdit open, and would stop the kit's own tooling reading its config. At bypass,
# protected-path writes are allowed and allow rules do not pre-approve them, so an
# explicit deny is the only thing left that stops the rewrite.
DENY_SELF_PROTECTION = [
    "Edit(/.claude/settings.json)",
    "Edit(/.claude/settings.local.json)",
    "Edit(/.claude/settings.*.json)",
    "Edit(/.claude/security.json)",
    "Edit(/.mcp.json)",
    # User scope. Deliberately NOT the blanket Edit(~/.claude/**) this list used to
    # carry: that glob also denied ~/.claude/projects/**/memory/**, the harness's own
    # file-based agent memory, and ~/.claude/CLAUDE.md, which CLAUDE-solana.md tells
    # every user project to write cross-project preferences into. The kit was forbidding
    # a documented feature and its own shipped instruction, and because deny wins over
    # allow in every scope with no un-deny primitive, no allow rule could carve either
    # one back out — the glob itself had to go.
    #
    # What stays denied is the policy surface: the files Claude Code LOADS as
    # configuration or EXECUTES. Caches, logs, transcripts, session state, plans and
    # keybindings are not policy and are left alone. Session transcripts are handled
    # separately and still read-denied at Medium and High (sandbox.filesystem.denyRead
    # carries ~/.claude/projects/**/*.jsonl and ~/.claude/history.jsonl), so the
    # transcripts stay unreadable while the memory directory beside them is writable.
    # ~/.claude/hooks/** is absent from this list because it is unconditional above.
    "Edit(~/.claude/settings.json)",
    "Edit(~/.claude/settings.local.json)",
    "Edit(~/.claude/settings.*.json)",
    "Edit(~/.claude/.credentials.json)",
    "Edit(~/.claude/agents/**)",
    "Edit(~/.claude/commands/**)",
    "Edit(~/.claude/skills/**)",
    "Edit(~/.claude/rules/**)",
    "Edit(~/.claude/output-styles/**)",
    "Edit(~/.claude/plugins/**)",
    "Edit(~/.claude/cowork_plugins/**)",
    "Edit(~/.claude/workflows/**)",
    "Edit(~/.claude/routines/**)",
    "Edit(~/.claude/scheduled_tasks.json)",
    # /loop's prompt file. Re-run on an interval, so rewriting it changes what a
    # recurring run does — the same class as scheduled_tasks.json, not a cache.
    "Edit(~/.claude/loop.md)",
    "Edit(~/.claude/daemon.json)",
    "Edit(~/.claude/launch.json)",
    # Sourced into every Bash invocation, so a write here is code execution on the next
    # shell command — the same class as a hook, not a cache.
    "Edit(~/.claude/shell-snapshots/**)",
    # Where a local `claude` install lives; writing it replaces the binary.
    "Edit(~/.claude/local/**)",
]

DENY_CREDENTIALS = [
    # Both the bare and the /** form for every directory: a /** pattern does not match
    # the directory entry itself.
    "Read(~/.ssh)",
    "Read(~/.ssh/**)",            # ~/.ssh/config ProxyCommand is remote code execution
    "Read(~/.gnupg)",
    "Read(~/.gnupg/**)",
    "Read(~/.aws)",
    "Read(~/.aws/**)",
    "Read(~/.config/solana/id.json)",
    "Read(~/.npmrc)",
    "Read(~/.git-credentials)",
    "Read(~/.netrc)",
    "Read(~/.config/gh/hosts.yml)",
    "Read(~/.kube/config)",
    "Read(~/.cargo/credentials)",
    "Read(~/.cargo/credentials.toml)",
    "Read(~/.docker/config.json)",
    "Read(~/.pypirc)",
    "Read(~/.gem/credentials)",
    "Read(~/.claude/.credentials.json)",
    # macOS keychains, 1Password's group container and Bitwarden's Application Support
    # directory are deliberately NOT listed. Resolving them while building the sandbox
    # profile raises the system "access data from other apps" prompt, and macOS already
    # gates them against every process — broader than a rule binding only this tool. The
    # cross-platform paths below are kept, because nothing gates those for us.
    # The `security` CLI stays denied, which is the reachable way to read a keychain.
    "Read(~/.local/share/keyrings)",
    "Read(~/.local/share/keyrings/**)",
    "Read(~/.gnome2/keyrings)",
    "Read(~/.gnome2/keyrings/**)",
    "Read(~/.password-store)",
    "Read(~/.password-store/**)",
    "Read(~/.config/1Password)",
    "Read(~/.config/1Password/**)",
    # Bitwarden desktop is Electron and unsandboxed, so this is a plain Application
    # Support directory, NOT a TCC-protected container like 1Password's group
    # container. Nothing gates it for us, so the rule stays.
    "Read(~/Library/Application Support/Bitwarden)",
    "Read(~/Library/Application Support/Bitwarden/**)",
    "Read(~/.config/Bitwarden)",
    "Read(~/.config/Bitwarden/**)",
    "Read(~/.config/keepassxc)",
    "Read(~/.config/keepassxc/**)",
]

DENY_BROWSER_STORES = [
    "Read(~/Library/Application Support/Google/Chrome)",
    "Read(~/Library/Application Support/Google/Chrome/**)",
    "Read(~/Library/Application Support/BraveSoftware/Brave-Browser)",
    "Read(~/Library/Application Support/BraveSoftware/Brave-Browser/**)",
    "Read(~/Library/Application Support/Microsoft Edge)",
    "Read(~/Library/Application Support/Microsoft Edge/**)",
    "Read(~/Library/Application Support/Firefox)",
    "Read(~/Library/Application Support/Firefox/**)",
    "Read(~/Library/Application Support/Chromium)",
    "Read(~/Library/Application Support/Chromium/**)",
    "Read(~/Library/Application Support/Vivaldi)",
    "Read(~/Library/Application Support/Vivaldi/**)",
    "Read(~/Library/Application Support/Arc)",
    "Read(~/Library/Application Support/Arc/**)",
    "Read(~/Library/Application Support/com.operasoftware.Opera)",
    "Read(~/Library/Application Support/com.operasoftware.Opera/**)",
    "Read(~/.config/google-chrome)",
    "Read(~/.config/google-chrome/**)",
    "Read(~/.config/BraveSoftware/Brave-Browser)",
    "Read(~/.config/BraveSoftware/Brave-Browser/**)",
    "Read(~/.config/microsoft-edge)",
    "Read(~/.config/microsoft-edge/**)",
    "Read(~/.mozilla/firefox)",
    "Read(~/.mozilla/firefox/**)",
    "Read(~/.config/chromium)",
    "Read(~/.config/chromium/**)",
    "Read(~/.config/vivaldi)",
    "Read(~/.config/vivaldi/**)",
    "Read(~/.config/opera)",
    "Read(~/.config/opera/**)",
    "Read(~/AppData/Local/Google/Chrome/User Data)",
    "Read(~/AppData/Local/Google/Chrome/User Data/**)",
    "Read(~/AppData/Local/BraveSoftware/Brave-Browser/User Data)",
    "Read(~/AppData/Local/BraveSoftware/Brave-Browser/User Data/**)",
    "Read(~/AppData/Local/Microsoft/Edge/User Data)",
    "Read(~/AppData/Local/Microsoft/Edge/User Data/**)",
    "Read(~/AppData/Roaming/Mozilla/Firefox)",
    "Read(~/AppData/Roaming/Mozilla/Firefox/**)",
    "Read(~/AppData/Local/Chromium/User Data)",
    "Read(~/AppData/Local/Chromium/User Data/**)",
    "Read(~/AppData/Local/Vivaldi/User Data)",
    "Read(~/AppData/Local/Vivaldi/User Data/**)",
    "Read(~/AppData/Roaming/Opera Software)",
    "Read(~/AppData/Roaming/Opera Software/**)",
    # Extension settings stores. The shipped Read(**/Local Extension Settings/**) was
    # cwd-relative, so it protected nothing: browser profiles live under $HOME. These
    # are ~/-anchored and also cover a browser pointed at a custom profile directory.
    "Read(~/**/Local Extension Settings)",
    "Read(~/**/Local Extension Settings/**)",
]

DENY_CODE_ON_NEXT_BUILD = [
    # Files that execute code the next time an ordinary command runs. Edit-denied, not
    # Read-denied: reading ~/.gitconfig is useful and harmless; writing it is not.
    "Edit(~/.cargo/config.toml)",        # [target.*.runner] + rustflags run on cargo test
    "Edit(~/.cargo/config)",
    "Edit(**/.cargo/config.toml)",       # in-project, any depth
    "Edit(~/.gitconfig)",                # core.hooksPath, core.editor, alias.*, credential.helper
    "Edit(~/.config/git/config)",
    "Edit(~/.zshenv)",                   # the only zsh file sourced for non-interactive shells
    "Edit(~/.zshrc)",
    "Edit(~/.zprofile)",
    "Edit(~/.zlogin)",
    "Edit(~/.bashrc)",
    "Edit(~/.bash_profile)",
    "Edit(~/.profile)",
    "Edit(~/.config/fish/config.fish)",
    "Edit(~/.config/fish/conf.d/**)",
    "Edit(~/Library/LaunchAgents)",
    "Edit(~/Library/LaunchAgents/**)",
    "Edit(//Library/LaunchAgents)",
    "Edit(//Library/LaunchAgents/**)",
    "Edit(//Library/LaunchDaemons)",
    "Edit(//Library/LaunchDaemons/**)",
    "Edit(~/.config/autostart)",
    "Edit(~/.config/autostart/**)",
]

DENY_HISTORY = [
    # Shell and REPL history leak secrets that were typed, and an agent that can write
    # them can scrub its own tracks. A Read deny covers both.
    "Read(~/.zsh_history)",
    "Read(~/.zhistory)",
    "Read(~/.bash_history)",
    "Read(~/.local/share/fish/fish_history)",
    "Read(~/.config/fish/fish_history)",
    "Read(~/.python_history)",
    "Read(~/.node_repl_history)",
    "Read(~/.psql_history)",
    "Read(~/.sqlite_history)",
    "Read(~/.lesshst)",
]

DENY_SECRET_READS_VIA_BASH = [
    "Bash(cat *id.json)",
    "Bash(cat *keypair*.json)",
    "Bash(cat keypair*.json)",           # zero-gap twin
    "Bash(cat *keypair.json)",           # zero-gap twin
    "Bash(cat ~/.ssh/*)",
    "Bash(cat ~/.config/solana/*.json)",
    "Bash(cat ~/.aws/*)",
    "Bash(cat ~/.gnupg/*)",
    "Bash(cat *.pem)",
    "Bash(cat ~/.config/gh/hosts.yml)",
    "Bash(cat ~/.npmrc)",
    "Bash(cat ~/.git-credentials)",
    "Bash(cat ~/.netrc)",
    "Bash(cat ~/.cargo/credentials*)",
    "Bash(cat ~/.claude/.credentials.json)",
    "Bash(less *id.json)",
    "Bash(xxd *id.json)",
    "Bash(gh auth token *)",
]

DENY_WRAPPERS = [
    # Rules cannot see past these, so the wrapper itself is denied.
    # `git -c core.fsmonitor=/tmp/x.sh status` is arbitrary code execution that evades
    # every `git <subcommand>` rule.
    # NOT evasions, deliberately absent: leading VAR=value assignments, subshells,
    # command substitutions, control-flow bodies, and the timeout/time/nice/nohup/
    # stdbuf/command/builtin/noglob wrappers plus bare xargs — the matcher handles all
    # of those already.
    #
    # The matcher handling them is not the same as the HOOKS handling them: a wrapped
    # command still reaches a PreToolUse hook with the wrapper attached, so the on-chain
    # hook normalises statements before matching (see .claude/hooks/onchain-guard.sh).
    # Separately, `command` and `xargs` are allowed only in their read-only forms
    # (`command -v`, `xargs grep|rg|wc|ls`) rather than as blanket globs, because
    # `Bash(xargs *)` pre-approved `xargs -I{} solana program deploy …` outright.
    #
    # `git -C` is NOT here: it moved to DENY_WRAPPERS_HIGH below. `git -c` stays, and the
    # two are not the same kind of thing — see that group for the distinction.
    "Bash(env *)",
    "Bash(sh -c *)",
    "Bash(bash -c *)",
    "Bash(bash -lc *)",
    "Bash(zsh -c *)",
    "Bash(git -c *)",
    "Bash(flock *)",
    "Bash(watch *)",
    "Bash(setsid *)",
    "Bash(ionice *)",
    "Bash(devbox run *)",
    "Bash(direnv exec *)",
    "Bash(mise exec *)",
    "Bash(docker exec *)",
]

# High only. The one wrapper whose denial was costing more than it bought.
#
# `git -c` and `git -C` look like the same evasion and are not. `-c` sets arbitrary
# configuration for one command, and `git -c core.fsmonitor=/tmp/x.sh status` is
# therefore arbitrary code execution wearing a `git status` costume — no rule can see
# past it, and it stays denied at every tier. (CLAUDE.md's commit-attribution
# instruction depends on that deny: it is what forces authorship through the explicit
# `git -c user.name=...` form the maintainer reviews rather than a silent default.)
#
# `-C` only changes directory first. It evades nothing a rule inspects, because every
# `git <subcommand>` rule still matches the subcommand that follows it; what it escapes
# is PATH scoping, by operating on a repository other than this one. That is a real but
# much narrower concern, and the price was wrong: `git -C .claude/skills/ext/<pack>
# log` is how submodule inspection is spelled, so the deny blocked ordinary work at
# every tier to close a gap only High claims to care about. High keeps it, because
# "reads are fenced to the working directory" is High's proposition and a sibling
# repository is outside it.
DENY_WRAPPERS_HIGH = [
    "Bash(git -C *)",
]

DENY_WHOLE_BINARY = [
    # Subcommand granularity is defeated for these.
    "Bash(security *)",        # security -i reads its subcommands from stdin
    "Bash(crontab*)",
    "Bash(launchctl *)",
    "Bash(defaults *)",
    "Bash(gh alias *)",        # aliases expand inside gh, invisible to the matcher
]

DENY_DESTRUCTIVE_SYSTEM = [
    "Bash(sudo *)",
    "Bash(rm -rf /*)",
    "Bash(rm -rf ~)",
    "Bash(rm -rf ~*)",
    "Bash(rm -rf ~/*)",
    "Bash(rm -rf .*)",
    "Bash(rm -rf .git)",
    "Bash(rm -rf .git/*)",
    "Bash(chmod 777 *)",
    "Bash(chmod -R 777 *)",
    "Bash(chown *)",
    "Bash(mkfs*)",             # also catches mkfs.ext4, which "mkfs *" misses
    "Bash(dd *)",
    "Bash(shutdown *)",
    "Bash(reboot *)",
    "Bash(kill -9 *)",
    "Bash(killall *)",
    "Bash(pkill *)",
    "Bash(docker rm *)",
    "Bash(docker rmi *)",
    "Bash(docker system prune *)",
]

DENY_UNRECOVERABLE_GIT = [
    # Verified-live evasions, each with its zero-gap twin. Long options abbreviate in
    # git (not in the solana CLI, which is clap v2 with no InferLongArgs), so
    # `git reset --ha HEAD` walked straight past `git reset --hard *`.
    "Bash(git clean *)",            # git clean is never non-destructive; -xdf, -dfx, --f -d
    "Bash(git restore *)",          # the modern spelling of `git checkout -- .`
    "Bash(git checkout -- *)",
    "Bash(git reset *--ha*)",
    "Bash(git reset --ha*)",
    "Bash(git branch *-D*)",
    "Bash(git branch -D*)",
    "Bash(git branch *--delete*)",
    "Bash(git branch --delete*)",
    "Bash(git branch * -f*)",
    "Bash(git branch -f*)",
    # These two are what make history truly unrecoverable; the rest is reflog-recoverable.
    "Bash(git gc *--prune*)",
    "Bash(git gc --prune*)",
    "Bash(git prune *)",
    "Bash(git reflog expire *)",
    "Bash(git push *--mirror*)",
    "Bash(git push --mirror*)",
]

# Every tier. Two halves, both flag- or subcommand-shaped, both with nothing to vary.
#
# 1. The transport overrides. `--upload-pack` and `--receive-pack` (and `--exec`, its
#    alias on push) name a PROGRAM for git to run as the other end of the transfer, so
#    `git fetch --upload-pack=/tmp/x.sh .` is arbitrary code execution that every
#    `git <subcommand>` rule reads as an ordinary fetch. Two things make it worse here
#    than a bare `sh -c`: the value is a path, not a command string, so none of the
#    secret or on-chain corpora match it; and `git push *`, `git pull *` and
#    `git fetch *` are three of the eight sandbox excludedCommands, so the program runs
#    with the OS sandbox lifted for the whole command line. No tier has a reason to
#    allow one, and no Solana toolchain emits one — the only legitimate use is reaching
#    a git binary at a non-standard path on a server, which a human does by hand.
#    Each carries its zero-gap twin: a mid-pattern * never matches the empty string.
# 2. `gh issue delete`. GitHub does not undo it — not from the UI, not from the API.
#    It is the one `gh` subcommand with no recoverable form, which is why it is a deny
#    where `gh pr merge` next to it in the same promise is a hook ask: a merge can be
#    reverted and the PR reopened. `gh repo delete` deserves the same rule and does not
#    have one yet; `Bash(gh api *)` at Medium and High closes its `-X DELETE` spelling
#    but not the gh subcommand itself.
DENY_UNRECOVERABLE_REMOTE = [
    "Bash(git push *--receive-pack*)",
    "Bash(git push --receive-pack*)",
    "Bash(git push *--exec*)",
    "Bash(git push --exec*)",
    "Bash(git pull *--upload-pack*)",
    "Bash(git pull --upload-pack*)",
    "Bash(git fetch *--upload-pack*)",
    "Bash(git fetch --upload-pack*)",
    "Bash(git clone *--upload-pack*)",
    "Bash(git clone --upload-pack*)",
    "Bash(git ls-remote *--upload-pack*)",
    "Bash(git ls-remote --upload-pack*)",
    "Bash(gh issue delete *)",
]

DENY_IRREVERSIBLE_ONCHAIN = [
    "Bash(solana program deploy *--final*)",
    "Bash(solana program deploy --final*)",
    "Bash(solana program set-upgrade-authority *--final*)",
    "Bash(solana program set-upgrade-authority --final*)",
    "Bash(anchor * --final*)",
    "Bash(anchor --final*)",
    "Bash(solana program close *--bypass-warning*)",
    "Bash(solana program close --bypass-warning*)",
    "Bash(solana program-v4 finalize *)",
    "Bash(spl-token authorize *--disable*)",
    "Bash(spl-token authorize --disable*)",
    "Bash(solana transfer *)",
    "Bash(solana close *)",
    "Bash(solana authorize *)",
    "Bash(solana withdraw-from-nonce-account *)",
    "Bash(spl-token burn *)",
    "Bash(spl-token close *)",
    # Repointing the default signer is invisible in every later command.
    "Bash(solana config set *-k*)",
    "Bash(solana config set -k*)",
]

DENY_SUPPLY_CHAIN = [
    # Publishing is NOT here. It is irreversible (npm unpublish closes after 72h,
    # crates.io never) but it has to vary by tier, and permissions.deny cannot: the lists
    # merge and a deny from any scope wins, so a deny here would apply at relaxed too.
    # egress-guard.sh gates it instead -- allowed at off/relaxed, denied at medium/high --
    # because the hook can read the tier. See FIREWALL-SPEC.md section 3.
    #
    # `npm run *deploy*` and `npm run *release*` are deliberately absent as well: they
    # matched an ordinary frontend deploy script, which is normal work at every tier.
    # gh secret set evades as gh variable set, and by API as
    # `gh api --method PUT .../secrets/NAME` — closed at Medium and High by DENY_GH_API
    # below, still reachable at Off and Relaxed (FIREWALL-SPEC.md section 7 item 2).
    "Bash(gh secret set *)",
    "Bash(gh variable set *)",
]

# Medium and High. The raw API escape hatch, which is how every narrower `gh` deny is
# walked around: `gh repo delete` as `gh api -X DELETE /repos/O/R`, `gh secret set` as
# `gh api --method PUT /repos/O/R/actions/secrets/NAME`.
#
# Why the whole subcommand and not just the mutating methods. A deny glob carries no
# argument form, so it is this or a hook; and a hook would have to classify the method
# correctly in every spelling (`-X`, `--method`, the implicit POST that `-f`/`--field`/
# `--input` triggers, `gh api graphql`, which is always a POST and may or may not
# mutate). One missed spelling in a hook is a silent hole, where one over-broad rule is
# a visible inconvenience with a documented route around it: `gh pr`, `gh issue`,
# `gh repo view`, `gh run` and `gh release view` cover the read cases and stay allowed.
# For a security gate that is the right way round.
#
# Not at Off or Relaxed. Relaxed is the CI tier and the kit's own Action runs there, and
# Relaxed's promise was never "the agent cannot change your repository".
DENY_GH_API = [
    "Bash(gh api *)",
]

# The one tier-varying group in permissions.deny, and the reason it is allowed to be.
#
# `context-mode` ships in .mcp.json, so an arbitrary executor is on by default. Bash has
# three layers in front of it and only two read the command string: permissions.deny and
# the hooks match patterns, and under them sandbox.* refuses at the syscall, which no
# amount of obfuscation reaches. A local MCP server runs outside that sandbox -- verified,
# not assumed: the same `ls ~/.claude/ide` is refused through Bash and succeeds through
# ctx_execute, and ctx_execute can write under $HOME, which is not in the Bash write
# allowlist. So for MCP the hooks are a single layer, and a single pattern layer is one
# obfuscation away from nothing.
#
# A tool-name deny is the second layer. Permission rules for MCP carry no argument
# specifier -- worse than ignored, a parenthesised mcp__ rule is SKIPPED on load -- but a
# tool that cannot be called at all cannot be obfuscated past, and that is exactly what
# Medium and High need, because "there is no arbitrary executor here" is their promise.
# Off and Relaxed make no such promise and keep every tool, with the hooks gating them;
# that is what keeps Relaxed usable and CI-safe.
#
# Why this may vary by tier when DENY_SUPPLY_CHAIN above says publishing may not: the
# objection there is cross-scope merging (no un-deny primitive, so a deny that reached a
# user or managed file could not be taken back on the way down). firewall.sh writes one
# file and removes exactly the strings in enforced.ruleIds, so descending does remove
# these -- the relaxed -> high -> relaxed byte-identity test in validate.sh is what holds
# that. The residual is unchanged from every other rule: a block hand-copied into user or
# managed scope stops tracking the tier.
#
# ctx_index earns its place next to the executors even though it neither executes nor
# fetches. Its `path` takes a file OR a directory, with followSymlinks and
# respectGitignore available, and what it reads becomes retrievable through ctx_search --
# an arbitrary-file-read primitive, outside the sandbox, whose output lands in the
# transcript. At Medium and High, whose whole read story is a path fence, that is the
# fence's negation. The remaining tools stay callable at every tier: ctx_search,
# ctx_stats, ctx_doctor and ctx_purge touch only local indexed state; ctx_insight opens
# one fixed URL; ctx_upgrade returns a command for Bash to run, where all three layers
# still apply.
DENY_MCP_ARBITRARY_EXECUTION = [
    "mcp__context-mode__ctx_execute",
    "mcp__context-mode__ctx_execute_file",
    "mcp__context-mode__ctx_batch_execute",
    "mcp__context-mode__ctx_fetch_and_index",
    "mcp__context-mode__ctx_index",
]

# High only — the one place the MCP deny set differs between Medium and High.
#
# cloudflare/mcp exposes three tools, verified against its README: `docs` searches the
# developer documentation, `search` runs JavaScript against `spec.paths` to find an
# endpoint, and `execute` runs JavaScript calling `cloudflare.request()`. Only the last
# one mutates, and what it reaches is the whole Cloudflare write API — 2,594 endpoints,
# so deploying a Worker, editing a zone's DNS records and purging a Queue are all in
# scope. `docs` and `search` stay callable at every tier: documentation lookup is the
# main reason to attach the server at all.
#
# Why this is High-only while context-mode's executor is denied at Medium too.
# context-mode ships ON BY DEFAULT, so the user never chose it and both gated tiers have
# to speak for them. Cloudflare is opt-in and needs an API token the user creates with
# scopes they pick, so attaching it is itself a decision — which makes Medium's job
# "respect an explicit choice" rather than "protect from a default". High is the
# locked-down interactive tier, and an ungated arbitrary executor contradicts that
# proposition however it arrived.
#
# Two residuals, same as every MCP rule. The `mcp__cloudflare__` prefix is the local
# server NAME, which is what /setup-mcp's documented `claude mcp add ... cloudflare`
# command produces; a server added under another name is not matched. And the
# `?codemode=false` form of the URL registers ~2,500 per-endpoint tools instead of these
# three, none of which this rule names — /setup-mcp tells the user not to use it, and
# the token's scopes remain the only boundary there.
DENY_MCP_CLOUDFLARE_EXECUTION = [
    "mcp__cloudflare__execute",
]

DENY = [
    DENY_POLICY_ESCAPE,
    DENY_CREDENTIALS,
    DENY_BROWSER_STORES,
    DENY_CODE_ON_NEXT_BUILD,
    DENY_HISTORY,
    DENY_SECRET_READS_VIA_BASH,
    DENY_WRAPPERS,
    DENY_WHOLE_BINARY,
    DENY_DESTRUCTIVE_SYSTEM,
    DENY_UNRECOVERABLE_GIT,
    DENY_UNRECOVERABLE_REMOTE,
    DENY_IRREVERSIBLE_ONCHAIN,
    DENY_SUPPLY_CHAIN,
]

# ===========================================================================
# sandbox.excludedCommands
# ===========================================================================
# An excluded command runs with the sandbox off for its WHOLE command line, so
# `git push -h >/dev/null 2>&1; <denied read>` exits 0 where the bare read gets EPERM
# (reproduced on 2.1.267; the docs claim every segment must match, and that is wrong).
#
# Two reasons an entry survives that anyway:
#
#   git/gh  — the sandbox has no way to reach the ssh-agent socket or the gh token,
#             both of which are read-denied, so a sandboxed `git push` cannot
#             authenticate at all. Dropping these breaks the kit's core workflow at
#             every tier. The bypass they re-open is covered at the layer above:
#             secrets-guard.sh segments the command on ; && || | and newline and
#             inspects each statement, so the read in `git push -h; cat <secret>`
#             is still blocked (verified). Belt and braces, not either/or.
#
#   surfpool — genuinely cannot be sandboxed. `surfpool start` panics instantly on
#             macOS SystemConfiguration and allowLocalBinding does not cover it,
#             which breaks anchor test's Anchor-1.x default path at every tier.
#
# Keep this list short and keep every entry justified here. Each one is a hole.
EXCLUDED_COMMANDS = [
    "surfpool *",
    "anchor test*",
    "git push *",
    "git pull *",
    "git fetch *",
    "gh pr *",
    "gh run *",
    "gh issue *",
]

# ===========================================================================
# sandbox.filesystem
# ===========================================================================
# Conventions differ from permission rules: `.` resolves against the settings file's
# directory, which for project settings means the project root.

SB_CREDENTIALS = [
    "~/.ssh",
    "~/.gnupg",
    "~/.aws",
    "~/.config/solana/id.json",
    "~/.claude/.credentials.json",
    "~/Library/Keychains",
    "/Library/Keychains",
    "~/.local/share/keyrings",
    "~/.gnome2/keyrings",
    "~/.password-store",
    "~/.config/1Password",
    "~/.config/Bitwarden",
    "~/.config/keepassxc",
]

SB_HOST_CREDENTIALS = [
    "~/.netrc",
    "~/.git-credentials",
    "~/.npmrc",
    "~/.cargo/credentials",
    "~/.cargo/credentials.toml",
    "~/.docker/config.json",
    "~/.config/gh/hosts.yml",
    "~/.kube/config",
    "~/.pypirc",
    "~/.gem/credentials",
]

SB_BROWSER_STORES = [
    "~/Library/Application Support/Google/Chrome",
    "~/Library/Application Support/BraveSoftware/Brave-Browser",
    "~/Library/Application Support/Microsoft Edge",
    "~/Library/Application Support/Firefox",
    "~/Library/Application Support/Chromium",
    "~/Library/Application Support/Vivaldi",
    "~/Library/Application Support/Arc",
    "~/Library/Application Support/com.operasoftware.Opera",
    "~/.config/google-chrome",
    "~/.config/BraveSoftware/Brave-Browser",
    "~/.config/microsoft-edge",
    "~/.mozilla/firefox",
    "~/.config/chromium",
    "~/.config/vivaldi",
    "~/.config/opera",
    "~/AppData/Local/Google/Chrome/User Data",
    "~/AppData/Local/BraveSoftware/Brave-Browser/User Data",
    "~/AppData/Local/Microsoft/Edge/User Data",
    "~/AppData/Roaming/Mozilla/Firefox",
    "~/AppData/Local/Chromium/User Data",
    "~/AppData/Local/Vivaldi/User Data",
    "~/AppData/Roaming/Opera Software",
]

SB_PERSISTENCE = [
    "~/.cargo/config.toml",
    "~/.cargo/config",
    "~/.gitconfig",
    "~/.config/git/config",
    "~/.zshenv",
    "~/.zshrc",
    "~/.zprofile",
    "~/.zlogin",
    "~/.bashrc",
    "~/.bash_profile",
    "~/.profile",
    "~/.config/fish/config.fish",
    "~/.config/fish/conf.d",
    "~/Library/LaunchAgents",
    "/Library/LaunchAgents",
    "/Library/LaunchDaemons",
    "~/.config/autostart",
]

SB_HISTORY = [
    "~/.zsh_history",
    "~/.zhistory",
    "~/.bash_history",
    "~/.local/share/fish/fish_history",
    "~/.config/fish/fish_history",
    "~/.python_history",
    "~/.node_repl_history",
    "~/.psql_history",
    "~/.sqlite_history",
    "~/.lesshst",
]

SB_POLICY_FILES = [
    "~/.claude/settings.json",
    "~/.claude/settings.local.json",
    "/Library/Application Support/ClaudeCode/managed-settings.json",
]

# Shippability carve-outs. Each one broke a default install:
#   * cargo needs WRITE access to its registry cache or the build dies.
#   * `mktemp -d` sits at update.sh:37, inside the frozen 1-93 byte range, and already
#     fails under the sandbox, which breaks /update and /add-skill.
#   * a linked worktree's git common dir is outside the working tree, so submodule
#     init needs write access to it.
# Credentials and config.toml inside these roots stay denied: for writes, denyWrite is
# a deny-within-allow and wins over the broader allowWrite below.
SB_TOOLCHAIN_WRITE = [
    "~/.cargo",
    "~/.rustup",
    "~/.cache",
    "~/.cache/solana",
    "~/.local/share/solana",
    "~/.avm",
    "~/.npm",
    "~/.anchor",
    "~/.config/solana",
    "~/Library/Caches",
]

# Absolute paths only. Verified in a live session: a project-settings entry is resolved
# against the project root, so "$TMPDIR" became "<project>/$TMPDIR" and "*" became
# "<project>/*" — both inert. /var/folders is where macOS `mktemp -d` actually lands.
SB_TEMP = ["/tmp", "/private/tmp", "/var/folders"]

# Reads are the mirror image: allowRead is an allow-WITHIN-deny, so it re-opens
# whatever it names. These are deliberately narrow subpaths, never `~/.cargo` or
# `~/.cargo/**`, or High's fence would hand back ~/.cargo/credentials.toml.
#
# Each root ships in two spellings. Verified against the 2.1.267 binary: under
# blockReadsOutsideWorkingDirectories "paths with glob characters are not re-opened",
# so a High tier carved out only with `/**` patterns would fence cargo and anchor out
# of their own caches. The glob-free directory entry is the one that re-opens; the
# `/**` twin states the subtree intent for the plain sandbox layer.
SB_TOOLCHAIN_READ = [
    "~/.cargo/registry",
    "~/.cargo/registry/**",
    "~/.cargo/git",
    "~/.cargo/git/**",
    "~/.cargo/bin",
    "~/.cargo/bin/**",
    "~/.cargo/env",
    "~/.rustup",
    "~/.rustup/**",
    "~/.cache/solana",
    "~/.cache/solana/**",
    "~/.local/share/solana",
    "~/.local/share/solana/**",
    "~/.avm",
    "~/.avm/**",
    "~/.npm",
    "~/.npm/**",
    "~/.nvm",
    "~/.nvm/**",
    "~/.bun",
    "~/.bun/**",
    "~/.local/share/pnpm",
    "~/.local/share/pnpm/**",
    "~/.anchor",
    "~/.anchor/**",
    "~/Library/Caches",
    "~/Library/Caches/**",
    # Keeps `solana config get` working while *.json under the dir stays denied. Never
    # deny the Solana config DIRECTORY: anchor init writes
    # wallet = "~/.config/solana/id.json" into Anchor.toml, and a dir-wide read deny
    # leaves solana/anchor unable to resolve a signer at all.
    "~/.config/solana/cli",
    "~/.config/solana/cli/**",
]

# ===========================================================================
# sandbox.network.deniedDomains — refused in every permission mode
# ===========================================================================
# The honest scope: this is the only egress control the kit can ship. A local MCP
# server runs outside the sandbox with full user access, and the network allowlist has
# no effect when set in project settings, so no tier closes egress.

DOMAINS_EXFIL_SINKS = [
    "requestbin.com", "*.requestbin.com",
    "pipedream.net", "*.pipedream.net",
    "webhook.site", "*.webhook.site",
    "requestcatcher.com", "*.requestcatcher.com",
    "beeceptor.com", "*.beeceptor.com",
    "hookb.in", "*.hookb.in",
    "typedwebhook.tools",
    "burpcollaborator.net", "*.burpcollaborator.net",
    "oast.fun", "*.oast.fun",
    "oastify.com", "*.oastify.com",
    "interact.sh", "*.interact.sh",
    "dnslog.cn", "*.dnslog.cn",
    "canarytokens.com", "*.canarytokens.com",
]

DOMAINS_TUNNELS = [
    "ngrok.io", "*.ngrok.io",
    "ngrok.app", "*.ngrok.app",
    "ngrok-free.app", "*.ngrok-free.app",
    "trycloudflare.com", "*.trycloudflare.com",
    "loca.lt", "*.loca.lt",
    "localtunnel.me", "*.localtunnel.me",
    "serveo.net", "*.serveo.net",
    "tunnelmole.net", "*.tunnelmole.net",
    "pagekite.me", "*.pagekite.me",
]

DOMAINS_PASTE_AND_DROPS = [
    "pastebin.com", "*.pastebin.com",
    "paste.ee", "hastebin.com", "dpaste.com", "dpaste.org", "glot.io",
    "ix.io", "sprunge.us", "termbin.com", "0x0.st", "x0.at", "envs.sh",
    "transfer.sh", "file.io", "oshi.at", "bashupload.com", "keep.sh", "temp.sh",
    "gofile.io", "*.gofile.io",
    "anonfiles.com", "catbox.moe", "*.catbox.moe", "uguu.se",
    "tmpfiles.org", "*.tmpfiles.org",
]

DOMAINS_MEDIUM = [
    # Bot and notification sinks, and the free compute hosts a one-line exfil endpoint
    # gets deployed to.
    "api.telegram.org",
    "api.pushover.net",
    "maker.ifttt.com",
    "hooks.zapier.com",
    "*.workers.dev",
    "*.deno.dev",
    "*.glitch.me",
    "*.repl.co",
    "*.replit.dev",
]

DOMAINS_HIGH = [
    "*.vercel.app",
    "*.netlify.app",
    "*.fly.dev",
    "*.onrender.com",
    "*.ngrok.dev",
]

# TODO(T1): whether sandbox.network.strictAllowlist takes effect when set in
# .claude/settings.json is unresolved — one review verified it live in the 2.1.267
# binary, another found the docs stating it has no effect from the only scopes the kit
# writes, and at bypassPermissions the allowlist is inert entirely unless
# strictAllowlist or allowManagedDomainsOnly is on. Until that test lands, no tier
# emits allowedDomains or strictAllowlist: shipping an allowlist that silently does
# nothing would be worse than shipping none, because High would claim egress
# enforcement it does not have. deniedDomains above is refused in every mode and ships
# at every tier from Relaxed up. Recommended default if T1 comes back positive: add
# allowedDomains + strictAllowlist at High ONLY, and keep documenting that a local MCP
# server bypasses it.

# ===========================================================================
# tier -> generated lists and scalars
# ===========================================================================

def plan(tier):
    """Return ({list path: [group, ...]}, {scalar path: value or None})."""
    at = RANK[tier]
    off = tier == "off"
    medium_up = at >= RANK["medium"]
    high = tier == "high"

    # Tier-varying permissions.deny groups, assembled in one place so the order the
    # generator writes them in is fixed. Two of these are Bash rules, which every other
    # Bash deny deliberately is not — see the note on permissions.deny below.
    deny_extra = []
    if high:
        deny_extra.append(DENY_SELF_PROTECTION)
        deny_extra.append(DENY_WRAPPERS_HIGH)
    if medium_up:
        deny_extra.append(DENY_GH_API)

    lists = {
        "permissions.allow": ALLOW,
        # No tier emits permissions.ask. Verified in-session: `git clean -n` matched
        # Bash(git clean *) in ask and ran silently with no prompt, while `sudo -n true`
        # matched deny and was blocked. The ask layer is inert here (sandboxed Bash
        # auto-allow, or bypass suppressing ask — indistinguishable from inside, and
        # both demand the same fix). Every prompt the kit wants is a hook returning
        # permissionDecision "ask"; every hard block is a deny rule or hook exit 2.
        # It is also what keeps Relaxed CI-safe: an ask is a hard failure under -p.
        "permissions.ask": [],
        # Tier-varying deny groups, all of them: DENY_SELF_PROTECTION and
        # DENY_WRAPPERS_HIGH at High, DENY_GH_API at Medium and High, and the two MCP
        # groups appended after the Off early-return below.
        #
        # DENY_WRAPPERS_HIGH and DENY_GH_API are the only Bash rules in the whole corpus
        # that vary by tier, and they carry the residual the other tier-varying groups
        # carry: /firewall subtracts exactly enforced.ruleIds from the one file it owns,
        # so a descent really does lift them, but a generated block hand-copied into user
        # or managed scope stops tracking the tier and then nothing can.
        "permissions.deny": DENY + deny_extra,
        "sandbox.excludedCommands": [] if off else [EXCLUDED_COMMANDS],
        "sandbox.network.deniedDomains": [],
        "sandbox.filesystem.denyRead": [],
        "sandbox.filesystem.allowRead": [],
        "sandbox.filesystem.denyWrite": [],
        "sandbox.filesystem.allowWrite": [],
    }

    scalars = {
        "sandbox.enabled": not off,
        "sandbox.network.allowLocalBinding": None if off else True,
        # High only, and ABSENT everywhere else. Never `false`: the two scalars take
        # the highest-precedence source and project settings outrank user settings, so
        # a project `false` would override a user who turned it on for themselves.
        "permissions.blockReadsOutsideWorkingDirectories": True if high else None,
    }

    if off:
        # Off disables the OS sandbox and generates no path or egress fencing. The
        # never-allowed deny set above still applies, DENY_POLICY_ESCAPE included, so a
        # nested `claude --dangerously-skip-permissions` is refused even here. What Off
        # does NOT carry is DENY_SELF_PROTECTION: like Relaxed and Medium, it lets the
        # agent edit the installation's own config files.
        return lists, scalars

    # Medium and High both state that an arbitrary executor is not reachable, and a
    # default-on MCP server with one makes that false unless the tool itself is refused.
    # Relaxed keeps every context-mode tool and relies on the hooks; see the group above.
    # High additionally refuses the one opt-in executor, which is the only place the two
    # gated tiers differ: Medium respects an explicitly attached server, High does not.
    if medium_up:
        extra = list(deny_extra)
        extra.append(DENY_MCP_ARBITRARY_EXECUTION)
        if high:
            extra.append(DENY_MCP_CLOUDFLARE_EXECUTION)
        lists["permissions.deny"] = DENY + extra

    domains = [DOMAINS_EXFIL_SINKS, DOMAINS_TUNNELS, DOMAINS_PASTE_AND_DROPS]
    if medium_up:
        domains.append(DOMAINS_MEDIUM)
    if high:
        domains.append(DOMAINS_HIGH)
    lists["sandbox.network.deniedDomains"] = domains

    lists["sandbox.filesystem.denyWrite"] = [
        SB_CREDENTIALS,
        SB_HOST_CREDENTIALS,
        SB_BROWSER_STORES,
        SB_PERSISTENCE,
        SB_HISTORY,
        SB_POLICY_FILES,
    ]

    # allowWrite is an allowlist, and a project-settings one APPENDS to Claude Code's
    # own built-in write allowlist rather than replacing it. Verified in a live session:
    # a write to ~/Documents was refused at Relaxed, so writes outside the working
    # directory are already fenced by the harness at every tier the sandbox is on —
    # the kit cannot loosen that, and High cannot tighten it further here. What these
    # entries do is widen the fence by exactly the roots a Solana build needs, which is
    # the shippability fix: before them, cargo could not write its registry cache and
    # `mktemp -d` (update.sh:37, inside the frozen byte range) failed outright.
    # denyWrite is a deny-within-allow, so credentials inside these roots stay denied.
    lists["sandbox.filesystem.allowWrite"] = [
        ["."] + SB_TEMP,
        SB_TOOLCHAIN_WRITE,
        git_common_write(),
    ]

    deny_read = [SB_CREDENTIALS, SB_BROWSER_STORES, SB_HISTORY]
    if medium_up:
        deny_read.append(SB_HOST_CREDENTIALS)
        deny_read.append([
            # *.json under the Solana config dir, never the directory itself.
            "~/.config/solana/*.json",
            # Transcripts replay every secret the session ever read.
            "~/.claude/projects/**/*.jsonl",
            "~/.claude/history.jsonl",
        ])
    if high:
        # The fence. allowRead below re-opens the narrow regions a build needs;
        # narrowness decides, not source order, so it survives settings merging.
        deny_read.append(["~/"])
        lists["sandbox.filesystem.allowRead"] = [["."] + SB_TEMP, SB_TOOLCHAIN_READ]
    lists["sandbox.filesystem.denyRead"] = deny_read

    # TODO(T3): FIREWALL-SPEC.md section 3.2 proposes blocking the model from project
    # keypairs with permissions.deny Read(**/*-keypair.json) while letting the
    # subprocess read them through sandbox allowRead(["./target", "./.anchor"]). That
    # only works if allowRead outranks a Read-deny projected into denyRead, which is
    # test T3 and is unresolved. Defaulted to the maintainer's plain allow: no keypair
    # Read-deny at any tier, so `anchor test` cannot break. Bash reads of keypairs are
    # still denied (DENY_SECRET_READS_VIA_BASH) and still hook-blocked, which is where
    # the real exposure was — a keypair read into the transcript. If T3 comes back
    # positive, add the Read denies here at Medium and High only, and note that
    # `target/deploy/*-keypair.json` is multi-segment so it gets no any-depth
    # promotion, and that `*-keypair.json` does not match `keypair.json`.

    return lists, scalars


def git_common_write():
    """Write access to the git common dir, only when it is outside the project."""
    entries = [".git"]
    if GIT_COMMON:
        try:
            common = os.path.realpath(GIT_COMMON)
            root = os.path.realpath(TARGET)
            if os.path.commonpath([common, root]) != root:
                entries.append(common)
        except (OSError, ValueError):
            pass
    return entries


MANAGED_LISTS = (
    "permissions.allow",
    "permissions.ask",
    "permissions.deny",
    "sandbox.excludedCommands",
    "sandbox.network.deniedDomains",
    "sandbox.filesystem.denyRead",
    "sandbox.filesystem.allowRead",
    "sandbox.filesystem.denyWrite",
    "sandbox.filesystem.allowWrite",
)

MANAGED_SCALARS = (
    "sandbox.enabled",
    "sandbox.network.allowLocalBinding",
    "permissions.blockReadsOutsideWorkingDirectories",
)

# Canonical key order inside each regenerated container, so two applies of the same
# tier produce the same bytes no matter which keys existed before. Keys the kit does
# not manage keep their relative order, after the managed ones.
ORDER = {
    "permissions": ("allow", "ask", "deny", "blockReadsOutsideWorkingDirectories"),
    "sandbox": ("enabled", "excludedCommands", "network", "filesystem"),
    "sandbox.network": ("allowLocalBinding", "deniedDomains", "allowedDomains", "strictAllowlist"),
    "sandbox.filesystem": ("denyRead", "allowRead", "denyWrite", "allowWrite"),
}

# Rules the kit shipped before the firewall that no tier re-emits. Removed once, on the
# first apply, alongside the union of every tier's own rules. After that, removal is
# driven purely by enforced.ruleIds.
LEGACY_RULE_IDS = [
    # superseded deny rules, each replaced by a form its evasion cannot walk around
    "Bash(mkfs *)",
    "Bash(git reset --hard *)",
    "Bash(git clean -fd *)",
    "Bash(git clean -fdx*)",
    "Bash(git clean -fX*)",
    "Bash(git push --force *)",
    "Bash(git push -f *)",
    "Bash(git push * --force*)",
    "Bash(git push * -f *)",
    "Bash(curl *convex.cloud*)",
    "Read(**/Local Extension Settings/**)",
    # the pre-firewall ask list, now carried by the hooks
    "Bash(solana program deploy *)",
    "Bash(solana program write-buffer *)",
    "Bash(solana program upgrade *)",
    "Bash(solana program extend *)",
    "Bash(solana program migrate *)",
    "Bash(solana program close *)",
    "Bash(solana program set-upgrade-authority *)",
    "Bash(solana program set-buffer-authority *)",
    "Bash(solana program-v4 deploy *)",
    "Bash(solana program-v4 retract *)",
    "Bash(solana program-v4 transfer-authority *)",
    "Bash(anchor deploy *)",
    "Bash(anchor upgrade *)",
    "Bash(anchor program deploy *)",
    "Bash(anchor program upgrade *)",
    "Bash(anchor program write-buffer *)",
    "Bash(anchor program close *)",
    "Bash(anchor program set-upgrade-authority *)",
    "Bash(anchor program set-buffer-authority *)",
    "Bash(solana withdraw-stake *)",
    "Bash(solana withdraw-from-vote-account *)",
    "Bash(spl-token transfer *)",
    "Bash(spl-token authorize *)",
    # Force push, `gh pr merge` and the solana-keygen --force spellings stay retired:
    # each is now a hook, which can read the tier and the arguments a glob cannot. The
    # transport overrides and `gh issue delete` came OUT of this list in rule set 5 and
    # are emitted again by DENY_UNRECOVERABLE_REMOTE, so listing them here too would
    # only make the apply subtract a rule it immediately re-adds.
    "Bash(git push --force*)",
    "Bash(gh pr merge *)",
    "Bash(solana-keygen new *--force*)",
    "Bash(solana-keygen new -f*)",
    "Bash(solana-keygen new * -f*)",
    "Bash(solana-keygen recover *--force*)",
    "Bash(solana-keygen recover -f*)",
    "Bash(solana-keygen recover * -f*)",
    # allow entries now denied as matcher-evading wrappers
    "Bash(env *)",
    "Bash(docker exec *)",
    # the six excludedCommands entries that made the whole-command-line escape reachable
    "git push *",
    "git pull *",
    "git fetch *",
    "gh pr *",
    "gh run *",
    "gh issue *",
]


# ---------------------------------------------------------------- helpers

def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        die("%s is not readable as JSON (%s)" % (path, exc))


def die(msg):
    sys.stderr.write("firewall.sh: %s\n" % msg)
    raise SystemExit(1)


def flatten(groups, lead_blank):
    """Groups -> a flat list with MARK between them. Never leaves MARK last."""
    out = []
    for group in groups:
        group = [e for e in group if e]
        if not group:
            continue
        if out or lead_blank:
            out.append(MARK)
        out.extend(group)
    return out


def dump(obj):
    """Serialize with the kit's house style: 2-space indent, a blank line between
    top-level keys, and a blank line where a MARK sentinel sits inside a list."""
    text = json.dumps(obj, indent=2, ensure_ascii=False)
    marker = '"%s"' % MARK
    out = []
    seen_top = False
    for line in text.split("\n"):
        if line.strip().rstrip(",") == marker:
            out.append("")
            continue
        if re.match(r'^  "', line):
            if seen_top:
                out.append("")
            seen_top = True
        out.append(line)
    return "\n".join(out) + "\n"


def write_atomic(path, text):
    directory = os.path.dirname(path) or "."
    tmp = os.path.join(directory, "." + os.path.basename(path) + ".firewall.tmp")
    mode = None
    try:
        mode = os.stat(path).st_mode & 0o7777
    except OSError:
        pass
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def container(root, path, create):
    """Walk a dotted path to the dict holding its last segment."""
    parts = path.split(".")
    node = root
    for part in parts[:-1]:
        child = node.get(part)
        if not isinstance(child, dict):
            if not create:
                return None, parts[-1]
            child = {}
            node[part] = child
        node = child
    return node, parts[-1]


def reorder(root):
    for path, keys in ORDER.items():
        node, last = container(root, path, False)
        if node is None:
            continue
        current = node.get(last)
        if not isinstance(current, dict):
            continue
        ordered = {k: current[k] for k in keys if k in current}
        for k in current:
            if k not in ordered:
                ordered[k] = current[k]
        node[last] = ordered       # replacing a value keeps the key's position


def bootstrap_ids():
    """Everything the kit could have written before enforced.ruleIds existed."""
    ids = set(LEGACY_RULE_IDS)
    for tier in TIERS:
        lists, _ = plan(tier)
        for groups in lists.values():
            for group in groups:
                ids.update(e for e in group if e)
    return ids


def diff(before, after):
    rest = list(after)
    removed = []
    for entry in before:
        if entry in rest:
            rest.remove(entry)
        else:
            removed.append(entry)
    rest = list(before)
    added = []
    for entry in after:
        if entry in rest:
            rest.remove(entry)
        else:
            added.append(entry)
    return added, removed


def report(label, entries, cap=8):
    if not entries:
        return
    shown = entries[:cap]
    for entry in shown:
        print("      %s %s" % (label, entry))
    if len(entries) > len(shown):
        print("      %s ... and %d more" % (label, len(entries) - len(shown)))


# ---------------------------------------------------------------- main

settings = load(SETTINGS)
if settings is None:
    settings = {}
if not isinstance(settings, dict):
    die("%s does not contain a JSON object" % SETTINGS_REL)

security = load(SECURITY)
if security is None:
    security = {"tier": "relaxed"}
if not isinstance(security, dict):
    die("%s does not contain a JSON object" % SECURITY_REL)

declared = security.get("tier")
if not declared:
    # /firewall's fallback path writes declared.tier; honor it as an input alias and
    # normalize it back into the canonical top-level `tier` on write.
    nested = security.get("declared")
    if isinstance(nested, dict):
        declared = nested.get("tier")
enforced_before = security.get("enforced") if isinstance(security.get("enforced"), dict) else {}

if MODE == "show":
    live = set()
    for path in MANAGED_LISTS:
        node, last = container(settings, path, False)
        if node:
            live.update(e for e in (node.get(last) or []) if isinstance(e, str))
    recorded = set(enforced_before.get("ruleIds") or [])
    print("declared tier : %s" % (declared or "none (defaults to relaxed)"))
    print("enforced tier : %s" % (enforced_before.get("tier") or "none — never applied"))
    print("rule set      : v%s" % (enforced_before.get("ruleSetVersion") or "-"))
    print("target        : %s" % (enforced_before.get("target") or SETTINGS_REL))
    print("recorded      : %d rules" % len(recorded))
    print("absent        : %d recorded rules missing from %s" % (len(recorded - live), SETTINGS_REL))
    if declared and enforced_before.get("tier") and declared != enforced_before.get("tier"):
        print("drift         : declared '%s' has not been applied; run: firewall.sh apply" % declared)
    if recorded - live:
        print("drift         : settings.json lost rules the last apply wrote; re-apply")
    raise SystemExit(0)

tier = TIER_ARG or declared or "relaxed"
if tier not in TIERS:
    die("unknown tier '%s' (expected one of: %s)" % (tier, ", ".join(TIERS)))

lists, scalars = plan(tier)

if enforced_before.get("ruleSetVersion"):
    remove = set(enforced_before.get("ruleIds") or [])
    first_apply = False
else:
    remove = bootstrap_ids()
    first_apply = True

print("firewall: %s -> %s%s" % (
    enforced_before.get("tier") or "unapplied", tier, " (dry run)" if DRY else ""))

rule_ids = []
seen_ids = set()
changed = 0
foreign_kept = 0

for path in MANAGED_LISTS:
    node, last = container(settings, path, True)
    current = node.get(last)
    before = [e for e in current if isinstance(e, str)] if isinstance(current, list) else []
    kept = [e for e in before if e not in remove]
    foreign_kept += len(kept)
    block = flatten(lists[path], bool(kept))
    final = kept + block
    after = [e for e in final if e != MARK]

    for entry in after:
        if entry not in seen_ids:
            seen_ids.add(entry)
            rule_ids.append(entry)

    if final:
        node[last] = final
    elif last in node:
        del node[last]

    added, removed = diff(before, after)
    if added or removed:
        changed += 1
        print("  %s: %d -> %d (+%d / -%d)" % (path, len(before), len(after), len(added), len(removed)))
        report("+", added)
        report("-", removed)

for path in MANAGED_SCALARS:
    node, last = container(settings, path, True)
    value = scalars[path]
    had = last in node
    if value is None:
        if had:
            del node[last]
            print("  %s: removed (was %r)" % (path, "?"))
            changed += 1
    elif not had or node[last] != value:
        node[last] = value
        print("  %s: %r" % (path, value))
        changed += 1

# Drop containers the kit emptied, so Off -> Relaxed -> Off round-trips byte-exactly.
for parent in ("sandbox.filesystem", "sandbox.network", "sandbox", "permissions"):
    node, last = container(settings, parent, False)
    if node is not None and isinstance(node.get(last), dict) and not node[last]:
        del node[last]

reorder(settings)

fingerprint = {
    "ruleSetVersion": RULE_SET_VERSION,
    "tier": tier,
    "lists": {p: [e for g in lists[p] for e in g if e] for p in MANAGED_LISTS},
    "scalars": {p: scalars[p] for p in MANAGED_SCALARS},
}
digest = hashlib.sha256(
    json.dumps(fingerprint, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()

security["tier"] = tier
security.pop("declared", None)
security["enforced"] = {
    "tier": tier,
    "ruleSetVersion": RULE_SET_VERSION,
    "target": SETTINGS_REL,
    "sha256": digest,
    "ruleIds": rule_ids,
}

settings_text = dump(settings)
security_text = dump(security)

if first_apply and foreign_kept:
    print("  note: %d rule(s) already in those lists were not written by any tier and "
          "were left in place, ahead of the generated block." % foreign_kept)
if not changed:
    print("  already in sync — no rule changes")

if DRY:
    print("  dry run: %s and %s were not written" % (SETTINGS_REL, SECURITY_REL))
    raise SystemExit(0)

write_atomic(SETTINGS, settings_text)
write_atomic(SECURITY, security_text)
print("  wrote %s (%d rules) and %s" % (SETTINGS_REL, len(rule_ids), SECURITY_REL))
print("  takes effect in the next session: permission rules are read once, at session start")
PY
