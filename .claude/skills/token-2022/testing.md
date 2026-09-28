# Testing Token-2022 code

Which token-2022 build each harness runs, and how to read its errors. General test guidance: [testing.md](../ext/solana-dev/skills/solana-dev/references/testing.md), [surfpool/cheatcodes.md](../ext/solana-dev/skills/solana-dev/references/surfpool/cheatcodes.md). Checked 2026-09-28.

## Bundled program versions

| Harness | Token-2022 bundled | PermissionedBurn | ZK proof program | Load a newer build |
|---|---|---|---|---|
| LiteSVM (Rust 0.17, npm 1.5) | 11.0.0 | yes | enabled (mainnet feature set) | `svm.addProgramFromFile(TOKEN_2022_ID, path)` after `new LiteSVM()` |
| Surfpool 1.6 (`anchor test` default in 1.2) | 11.0.0 (LiteSVM internals) | yes | enabled; `--disable-feature zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN` for the off state | forks fetch accounts, not the program |
| `solana-test-validator` (Agave 3.1 and 4.3) | 10.0.0 | no (`InvalidInstruction`) | enabled at genesis | `--bpf-program TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb token_2022.so` |
| Mollusk `mollusk-svm-programs-token-2022` 0.15.1 | mid-2025 dump | no | only with the `all-builtins` feature | `add_program_with_loader_and_elf` |

- Mainnet most likely runs 11.0.0 (the 11.1.0 release notes list devnet and testnet only); confirm with `solana program show TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb -u mainnet-beta` and test against that, not whatever a harness bundles. Build a newer program from `solana-program/token-2022` with `cargo build-sbf` if you need 11.1.
- On Agave 3.1's test validator, proofs from `@solana/zk-sdk` 0.5.3 fail to verify (that validator uses an older zk-sdk); LiteSVM verifies them. Agave 3.1 and 4.x also use different feature IDs for the proof-program re-enable gate.
- LiteSVM 0.17 (Rust) needs rustc 1.97; LiteSVM 0.16 works on older toolchains and bundles the same 11.0.0.
- LiteSVM's clock starts at `unixTimestamp` 0; set it (`svm.setClock`) before testing scheduled ScaledUiAmount multipliers or interest.
- Surfpool: `surfnet_setTokenAccount(owner, mint, update, tokenProgram)` takes the Token-2022 ID last and can build funded confidential accounts; `surfnet_timeTravel` with `absoluteEpoch` crosses the two-epoch transfer-fee delay.

## Error codes

Kit's generated error map in `@solana-program/token-2022` 0.19 names codes 0–19 only, so Token-2022-specific failures surface as bare numbers:

| Code | Error | Typical cause |
|---|---|---|
| 12 | `InvalidInstruction` | plain `Burn` on a PermissionedBurn mint; an instruction the bundled program doesn't know |
| 15 | `AuthorityTypeNotSupported` | re-setting an extension authority that was renounced; pausing with no pause authority |
| 16 | `MintCannotFreeze` | DefaultAccountState(Frozen) without a freeze authority |
| 30 | `TransferFeeExceedsMaximum` | a fee above 10,000 bps |
| 31 | `MintRequiredForTransfer` | plain `transfer` on a fee, hook or pausable mint |
| 32 | `FeeMismatch` | `transfer_checked_with_fee` with a fee the program computes differently |
| 35 | `AccountHasWithheldTransferFees` | closing an account that still holds withheld fees |
| 36 | `NoMemo` | transfer into a required-memo account without a memo right before it |
| 38 | `NonTransferableNeedsImmutableOwnership` | minting a non-transferable token to an account without ImmutableOwner |
| 39 | `MaximumPendingBalanceCreditCounterExceeded` | too many incoming confidential credits before `ApplyPendingBalance` |
| 51 | `InvalidExtensionCombination` | see [invalid combinations](../token-2022.md#invalid-combinations) |
| 56 | `HarvestToMintDisabled` | confidential fee harvest while harvesting is disabled |
| 65 | `IllegalMintBurnConversion` | public mint or burn on a ConfidentialMintBurn mint |
| 67 | `MintPaused` | transfer, mint or burn on a paused mint |

- `MissingAccount` (a runtime error, not a token error) on a hooked mint: the extras were not resolved. `PrivilegeEscalation`: a writable hook extra was passed read-only.
- In npm `litesvm`, errors are native classes and `JSON.stringify(err)` prints `{}`; read `result.err().err().code` for the custom code.
- Test the combinations your mint actually uses: pause then transfer, burn with and without the burn authority, a hooked transfer through your own program's CPI, and fee accounting via balance deltas.
