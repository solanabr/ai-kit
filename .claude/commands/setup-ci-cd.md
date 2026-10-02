---
description: "Set up GitHub Actions CI for Solana programs: lint, build, test, audit"
---

Create a GitHub Actions pipeline for this repo's programs, adapted to what the repo actually uses (Anchor or native, where tests live, package manager). Workflow and deploy-stage patterns: [deployment.md](../skills/deployment.md). Test layers: [testing.md](../skills/ext/solana-dev/skills/solana-dev/references/testing.md).

## Steps

1. Write `.github/workflows/solana-security.yml`, triggered on pull requests and on pushes to `main`, with these jobs:
   - **lint**: `cargo fmt --all -- --check` and `cargo clippy --all-targets -- -D warnings`. Optionally tighten the program crates' library targets with `-W clippy::arithmetic_side_effects -W clippy::unwrap_used -W clippy::expect_used`, scoped to `--lib` so tests can still unwrap.
   - **build**: `anchor build` (Anchor) or `cargo build-sbf` (native/Pinocchio). Install toolchains at the versions pinned in `Anchor.toml` `[toolchain]` or `rust-toolchain.toml` instead of hardcoding them: the Solana CLI from `https://release.anza.xyz/<version>/install` (not the old release.solana.com), Anchor through `avm`. Cache `~/.cargo` and `target/`.
   - **test**, after the build, since LiteSVM and Mollusk tests load the `.so` from `target/deploy/`: `cargo test` for the Rust tests. `anchor test` defaults to Surfpool in Anchor 1.x, so either install the `surfpool` CLI on the runner or run `anchor test --validator legacy` to use `solana-test-validator`. If `trident-tests/` exists, add a time-boxed, non-blocking Trident fuzz job.
   - **audit**: `cargo audit` for RustSec advisories, or `cargo deny check` for advisories plus licenses and banned crates. License policy belongs in cargo-deny's `deny.toml`; `audit.toml` has no license settings.
   - **verifiable build**, on pushes to `main` and release tags: `anchor build` for the IDL, then `solana-verify build --library-name <lib>` last, uploading `target/deploy/<lib>.so`, its `solana-verify get-executable-hash` and `target/idl/*.json` as artifacts. Use `solana-verify build` for Anchor programs too: `anchor build --verifiable` uses a different Docker image than the verifier, so `target/verifiable/` output will not verify.
2. Add `.github/dependabot.yml` with weekly `cargo` and `github-actions` updates (plus `npm` when there is a client), and a short `.github/PULL_REQUEST_TEMPLATE.md` checklist that points at `/diff-review`, `/audit-solana`, `/profile-cu` and the verifiable build instead of copying the house rules. A local `.git/hooks/pre-commit` for human contributors is optional.
3. Deploy jobs are optional. Keep them to devnet, behind a GitHub environment with required reviewers. Store the deployer keypair JSON as an environment secret, write it to a temp file at runtime, and never echo it or upload it as an artifact. Mainnet upgrades stay out of automatic CI (buffer plus multisig; see deployment.md).

## Output

Files created, each job with its trigger, the secrets and variables the user must add, and the manual step: protect `main` in the repository settings (required PR review, required lint/build/test/audit checks, branches up to date before merging).
