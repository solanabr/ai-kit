---
description: "Scaffold a Solana project (Anchor, fullstack, frontend, Pinocchio) with the kit"
model: sonnet
---

Scaffold a new project and install the kit into it. `$ARGUMENTS`: the project name and, optionally, the type; ask for whatever is missing.

## Steps

1. **Pick the type**, asking unless the arguments make it clear. For program types, if `solana --version` or `anchor --version` fails, send the user to `/doctor` first.

   | Type | Scaffold |
   |------|----------|
   | Anchor program | `anchor init <name> --test-template litesvm`: Rust LiteSVM tests under `programs/<name>/tests/` (the Anchor 1.x default, pinned explicitly). Add `--template multiple` for a `lib.rs` / `instructions/` / `state/` layout. |
   | Fullstack | `npx create-solana-dapp@latest <name> -t solana-foundation/templates/kit/nextjs-anchor` (Next.js + Anchor + Kit) |
   | Frontend only | `npx create-solana-dapp@latest <name> -t <template>` with a Kit template that has no program (`npx create-solana-dapp@latest --list-templates`), or `npx create-next-app@latest <name> --typescript --tailwind --eslint --app --src-dir --import-alias "@/*"` plus the dependencies in [frontend.md](../skills/ext/solana-dev/skills/solana-dev/references/frontend.md) |
   | Native (Pinocchio) | `cargo new --lib <name>` (or `cargo init --lib` in place), set `crate-type = ["cdylib", "lib"]`, add `pinocchio` at the versions in [pinocchio.md](../skills/ext/solana-dev/skills/solana-dev/references/programs/pinocchio.md), build with `cargo build-sbf`, test with Mollusk or LiteSVM |

   Always pass `-t` to create-solana-dapp; without it the CLI stops at an interactive prompt.
2. **Install the kit config.** The new directory must be its own git repository (`git init` if the generator didn't create one), because the installer skips submodule init otherwise. Run the installer against it: `bash <kit-clone>/install.sh <dir>`, or `curl -fsSL https://aikit.superteam.codes | bash -s -- <dir>`; add `--agents` to also write the AGENTS.md bridge for Codex, Cursor and Copilot. It copies `.claude/`, writes `CLAUDE.md` from `CLAUDE-solana.md`, inits the ext/ submodules and gitignores the kit files (`/commit-claude-config` versions them).
3. **Git.** Make the initial commit (`feat: scaffold <name> with solana-ai-kit`), then start work on a branch: `git checkout -b <type>/<scope>-<description>-<DD-MM-YYYY>`.

## Output

Project path and type, the scaffold command used, and next steps: `/build-program` and `/test-rust` (or `/build-app` and `/test-ts`), `/setup-mcp`, `/setup-ci-cd`.
