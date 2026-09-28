# Token Extensions research (issue #12)

Working material for the Token-2022 skill suite. Not shipped by `install.sh` or the plugin; delete or move once the suite lands.

- [BRIEF.md](BRIEF.md): findings, stale upstream claims, baseline gaps, SDK and venue support, open questions.
- [notes/](notes/): per-topic notes with sources and confidence labels, dated 2026-09-28.
- [kit-litesvm/](kit-litesvm/): Kit 0.19 checks run offline in LiteSVM (create-mint plan, Pausable, PermissionedBurn, Scaled UI rounding, invalid combos, transfer hook, ZK proof program).
- [rust-programs/](rust-programs/): Anchor 1.2 vault and hook, Pinocchio hook, PermissionedBurn CPI via `spl-token-2022-interface` 3.x, `onchain::invoke_transfer_checked`, with LiteSVM tests.

Unverified from the research environment (network-blocked); a person can close these:

```bash
solana program show TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb -u mainnet-beta   # upgrade authority, last deploy
solana account TwRapQCDhWkZRrDaHfZGuHxkZ91gHDRkyuzNqeU5MgR -u mainnet-beta        # token-wrap on mainnet?
```

## Run the Kit checks

```bash
cd kit-litesvm && npm ci && bash run-all.sh
T22_SO=path/to/spl_token_2022.so bash run-all.sh   # test another token-2022 build
```

`b6-transfer-hook.mjs` needs a compiled allowlist hook: put `transfer_hook_allowlist.so` and `transfer_hook_allowlist-keypair.json` in `kit-litesvm/hook/` or set `HOOK_DIR` (the research used the example from Andy00L/solana-token-extensions-skill). `a-test-validator.mjs` expects a local validator at `RPC` (default `http://127.0.0.1:18899`) and is not part of `run-all.sh`.

## Run the Rust programs

Needs `cargo-build-sbf` (Agave 3.1.x was used).

```bash
cd rust-programs
for p in programs/*; do (cd "$p" && cargo build-sbf); done
cargo test -p itests
```
