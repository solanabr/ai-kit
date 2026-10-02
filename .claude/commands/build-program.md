---
description: "Build Solana programs (Anchor, Pinocchio, native), incl. verifiable builds"
---

Build the program(s) in this workspace ($ARGUMENTS: optional program name) so `target/deploy/*.so`, and for Anchor `target/idl/*.json`, are ready for tests and deploys. Toolchain errors not covered below: [common-errors.md](../skills/ext/solana-dev/skills/solana-dev/references/common-errors.md).

## Steps

1. Build:
   - Anchor: `anchor build` (`-p <name>` for one program). For a new, never-deployed program, run `anchor keys sync` after the first build and rebuild, so `declare_id!` and `Anchor.toml` match `target/deploy/<name>-keypair.json`. Skip it for a deployed program whose keypair is not in `target/deploy/`: it would rewrite `declare_id!` to a fresh address.
   - Pinocchio or native: `cargo build-sbf`.
   - Anything headed to mainnet, Anchor or not: `solana-verify build --library-name <lib>` last. It needs Docker, rebuilds `target/deploy/<lib>.so`, and that file is both what you deploy and what `anchor verify` reproduces. `anchor build --verifiable` builds in a different Docker image, so its `target/verifiable/` output will not verify.
2. Check the output: each `.so` and its size (deploy rent scales with it: `solana rent <bytes>`), the IDL for Anchor programs, and the program IDs (`solana address -k target/deploy/<name>-keypair.json`).
3. `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings`.

## Failure fixes

- Platform-tools corrupted or half-downloaded: `cargo build-sbf --force-tools-install`.
- `feature edition2024 is required` or "requires rustc 1.xx": `cargo build-sbf` uses the Rust/Cargo bundled in platform-tools, not your rustup toolchain. Pin the offending crate (`cargo update -p <crate> --precise <older version>`) or move to newer platform-tools (`agave-install update`, or `--tools-version`).
- `overflow-checks must be specified`: set `overflow-checks = true` under `[profile.release]` in the workspace `Cargo.toml`. It also makes unchecked arithmetic panic instead of silently wrapping.
- Binary too large: `lto = "fat"` and `codegen-units = 1` in `[profile.release]`; `opt-level = "s"` or `"z"` trades CU for size; drop heavy dependencies.

## Output

Programs built, `.so` sizes, program IDs, IDL status, fmt and clippy results.
