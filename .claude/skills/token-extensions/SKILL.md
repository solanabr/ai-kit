---
name: token-extensions
description: Token-2022 (Token Extensions) on Solana. Pick, combine and create mint and account extensions with the spl-token CLI, @solana/kit or Anchor, and integrate extension mints. Use for transfer fees, hooks, metadata, groups, pausable, permanent delegate, soulbound, interest-bearing, scaled UI or confidential tokens.
user-invocable: true
---

# Token Extensions (Token-2022)

Program `TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb`. Checked on 2026-09-30 against the mainnet program (spl-token-2022 v11.0.0, per its verified build), spl-token-2022-interface 3.1.2, spl-token-cli 5.6.1, `@solana-program/token-2022` 0.19.0 on `@solana/kit` 8, and anchor-lang / anchor-spl 1.2.0. Newer releases may rename things; check before relying on a name from memory.

Links into the kit's `ext/` directory, here and in the references, need its full install; in a plugin install, read the same paths in solana-foundation/solana-dev-skill.

## Pick the extensions

Fixed-size mint extensions can only be set before `InitializeMint`, so pick them up front. TokenMetadata, TokenGroup and TokenGroupMember can be initialized later, but only if their pointer was set at creation. Venues accept different sets; Orca's rules are in [programs](references/programs.md).

| Extension (mint) | Use it for | Authority | Token accounts get | Read |
|---|---|---|---|---|
| TransferFeeConfig | A fee withheld on every transfer | fee config, withdraw withheld | TransferFeeAmount | [fees](references/fees.md) |
| TransferHook | Your program runs on every transfer | hook authority (sets the program id) | TransferHookAccount | [transfer-hooks](references/transfer-hooks.md) |
| MetadataPointer + TokenMetadata | Name, symbol, URI and fields stored on the mint | pointer authority, metadata update authority | | [metadata-groups](references/metadata-groups.md) |
| GroupPointer + TokenGroup | A collection parent mint | pointer authority, group update authority | | [metadata-groups](references/metadata-groups.md) |
| GroupMemberPointer + TokenGroupMember | A mint inside a collection | pointer authority; group update authority co-signs | | [metadata-groups](references/metadata-groups.md) |
| PermanentDelegate | Issuer can transfer or burn from any account | permanent delegate | | [issuer-controls](references/issuer-controls.md) |
| DefaultAccountState | New accounts start frozen (KYC gating) | freeze authority | | [issuer-controls](references/issuer-controls.md) |
| Pausable | Stop transfers, mints and burns | pause authority | PausableAccount | [issuer-controls](references/issuer-controls.md) |
| PermissionedBurn | Burning needs an extra authority | permissioned-burn authority | | [issuer-controls](references/issuer-controls.md) |
| NonTransferable | Soulbound: holders can't transfer | none | NonTransferableAccount, ImmutableOwner | [issuer-controls](references/issuer-controls.md) |
| MintCloseAuthority | Close the mint once supply is 0 | close authority | | [issuer-controls](references/issuer-controls.md) |
| InterestBearingConfig | Displayed amount accrues interest | rate authority | | [display-amounts](references/display-amounts.md) |
| ScaledUiAmount | Displayed amount = raw × multiplier | multiplier authority | | [display-amounts](references/display-amounts.md) |
| ConfidentialTransferMint (+ ConfidentialTransferFeeConfig, ConfidentialMintBurn) | Encrypted balances and amounts | confidential authority, auditor key | ConfidentialTransferAccount, opt-in per account | [confidential](references/confidential.md) |

Holder-side account extensions (ImmutableOwner, MemoTransfer, CpiGuard), account sizing and Reallocate: [account-extensions](references/account-extensions.md). Accepting any Token-2022 mint in a program, and CPIs from Anchor: [programs](references/programs.md).

## Combinations

| Combination | Result |
|---|---|
| ConfidentialTransferFeeConfig without both TransferFeeConfig and ConfidentialTransferMint | Rejected at `InitializeMint`: `InvalidExtensionCombination` |
| TransferFeeConfig + ConfidentialTransferMint without ConfidentialTransferFeeConfig | Rejected: `InvalidExtensionCombination` |
| ConfidentialMintBurn without ConfidentialTransferMint | Rejected: `InvalidExtensionCombination` |
| NonTransferable + ConfidentialTransferMint without ConfidentialMintBurn | Rejected: `InvalidExtensionCombination` |
| InterestBearingConfig + ScaledUiAmount | Rejected: `InvalidExtensionCombination` |
| DefaultAccountState `Frozen` without a freeze authority | Rejected: `MintCannotFreeze` |
| NonTransferable + TransferFeeConfig or TransferHook | Accepted, but pointless: every transfer fails with `NonTransferable` |
| NonTransferable + PermanentDelegate | The delegate can burn but not transfer |
| TransferHook + ConfidentialTransferMint | Confidential transfers call the hook with `amount = u64::MAX` |
| Pausable, while paused | `TransferChecked`, `MintTo` and burns fail with `MintPaused` |

Tooling gaps: anchor-spl 1.2.0 has no helpers for ScaledUiAmount, PermissionedBurn or the confidential extensions (it builds on spl-token-2022-interface 2.x, which has no PermissionedBurn), and spl-token-cli 5.6.1 can't initialize ConfidentialMintBurn.

spl-token-cli 5.6.1 can't act for a multisig extension authority. `set-interest-rate`, `set-transfer-fee`, `set-transfer-hook`, `initialize-metadata`, `update-metadata`, `initialize-group`, `update-group-max-size`, `initialize-member` and `update-confidential-transfer-settings` reject `--multisig-signer`. `pause`, `resume` and `update-ui-amount-multiplier` accept it but ignore it and send an under-signed transaction. Build those instructions with Kit or Rust instead.

Confidential transfers need the ZK ElGamal Proof program enabled on the cluster (on mainnet since epoch 982, and on devnet), a per-account opt-in (Reallocate, then ConfigureAccount with a proof), and an owner who applies pending balances. Decisions and what is out of date in the linked Rust walkthrough: [confidential](references/confidential.md).

## Create a mint

One transaction, in this order:

1. Create the account, owned by Token-2022, with space for the fixed-size extensions only: `ExtensionType::try_calculate_account_len::<Mint>(&types)` (Rust), `getMintLen(types)` (web3.js 1.x), or Kit's `getMintSize` over the list without TokenMetadata, TokenGroup and TokenGroupMember (it counts whatever it is given), with rent from `getMintSize` over the full list. `InitializeMint` rejects any other length (`InvalidAccountData`) and a mint below the rent-exempt minimum (`NotRentExempt`).
2. Each extension's initialize instruction. On an initialized mint these fail with `AlreadyInUse`, so fixed-size extensions can't be added later.
3. `InitializeMint2` (or `InitializeMint`).
4. TokenMetadata, TokenGroup and TokenGroupMember. They grow the mint but move no lamports, so fund the mint for its final size in step 1 (Kit's `createMint` does), or transfer the difference to the mint before the initialize, in an earlier instruction of the same transaction (the CLI does) or in your program before the CPI.

Kit: the plugin's `createMint` does the sizing, funding and ordering. It doesn't initialize TokenGroupMember, doesn't write `additionalMetadata` (it only pays rent for it), and skips TokenMetadata when `updateAuthority` is null ([metadata-groups](references/metadata-groups.md)). `client` is a Kit 8 client with an RPC, a payer and transaction planning and sending ([Kit plugins](../ext/solana-dev/skills/solana-dev/references/kit/plugins.md)).

```ts
import { generateKeyPairSigner } from '@solana/kit';
import { extension, token2022Program } from '@solana-program/token-2022';

const token = client.use(token2022Program());
const mint = await generateKeyPairSigner();
const authority = client.payer.address;
await token.token2022.instructions
  .createMint({
    newMint: mint,
    decimals: 6,
    mintAuthority: client.payer,
    extensions: [
      extension('MetadataPointer', { authority, metadataAddress: mint.address }),
      extension('TokenMetadata', {
        updateAuthority: authority, mint: mint.address,
        name: 'Example', symbol: 'EXM', uri: 'https://example.com/exm.json',
        additionalMetadata: new Map(),
      }),
    ],
  })
  .sendTransaction();
```

Without the plugin, compose the same steps (space from the filtered list, rent from the full one, as `createMint` does) with `getMintSize`, `getPreInitializeInstructionsForMintExtensions`, `getInitializeMintInstruction` and `getPostInitializeInstructionsForMintExtensions`, or call `getCreateMintInstructionPlan(client, input)`.

CLI: `spl-token --program-2022 create-token --decimals 6 --enable-metadata` then `spl-token initialize-metadata <MINT> Example EXM https://example.com/exm.json`. After creation the CLI infers the program from the account's owner, so later commands don't need `--program-2022`, except with `--sign-only`, where it can't look the account up and defaults to classic Token.

Anchor 1.2.0: `init` on an `InterfaceAccount<'info, Mint>` accepts `extensions::metadata_pointer::{authority, metadata_address}`, `extensions::group_pointer::{authority, group_address}`, `extensions::group_member_pointer::{authority, member_address}`, `extensions::transfer_hook::{authority, program_id}`, `extensions::close_authority::authority`, `extensions::permanent_delegate::delegate` and `extensions::pausable::authority`. The same constraints on an existing mint check the extension's values. TokenMetadata, TokenGroup and TokenGroupMember are CPIs after `init` ([metadata-groups](references/metadata-groups.md)); the other extensions need a manual create-and-initialize sequence ([programs](references/programs.md)).

## Token accounts and transfers

- Associated token accounts derive from the token program id. Pass the Token-2022 id (`findAssociatedTokenPda({ owner, mint, tokenProgram })`, `getAssociatedTokenAddressSync(mint, owner, false, TOKEN_2022_PROGRAM_ID)`), or you get the address of an account that doesn't exist. web3.js's `createAssociatedTokenAccountIdempotentInstructionWithDerivation` derives with the classic program id even when you pass Token-2022; derive the address yourself.
- Token accounts need the extensions their mint requires (table above). Associated token accounts and Anchor's `init` get them. For an account you create yourself, Kit's `getTokenSize` counts only the extensions you pass it: [account-extensions](references/account-extensions.md).
- Transfer with `TransferChecked`. Plain `Transfer` fails with `MintRequiredForTransfer` when the source account has TransferFeeAmount, TransferHookAccount or PausableAccount, because the program needs the mint to charge the fee, call the hook or check the pause.
- With a fee, the recipient gets `amount - fee`: credit the balance delta, not the argument. The fee stays withheld in the recipient's account until anyone harvests it to the mint or the withdraw authority withdraws it; an account holding withheld fees can't close ([fees](references/fees.md)).
- With a hook, the hook program's ExtraAccountMetaList PDA (seeds `["extra-account-metas", mint]`) must exist before the first transfer, and every transfer appends the hook program, that PDA and the extra accounts it lists (Kit: `getTransferCheckedWithTransferHookInstructionAsync`).
- A `TransferChecked` to the same account moves nothing, charges no fee and skips the hook. Confidential transfers have no such shortcut and call the hook.
- In a program, `anchor_spl::token_interface::transfer_checked` passes only the four base accounts, so it can't move a hook mint: [transfer-hooks](references/transfer-hooks.md#cpi-a-transfer-of-a-hook-mint).
- Destinations with MemoTransfer enabled need a memo instruction right before the transfer. Owners with CpiGuard enabled can't sign transfers inside a CPI.

## Reading an unknown mint

- Kit: `fetchMint(rpc, address)` then `mint.data.extensions`, an `Option` of an array tagged by `__kind`. web3.js 1.x: `getExtensionTypes(mint.tlvData)` on the result of `getMint(connection, address, undefined, TOKEN_2022_PROGRAM_ID)`. Rust: `StateWithExtensions::<Mint>::unpack(&data)?` then `get_extension_types()` or `get_extension::<T>()`; Anchor: `anchor_spl::token_interface::get_mint_extension_data::<T>(&account_info)`.
- Match on each tool's own names. Kit's `__kind` is `ScaledUiAmountConfig`, `PausableConfig` and `ConfidentialTransferFee` where Rust says ScaledUiAmount, Pausable and ConfidentialTransferFeeConfig; web3.js uses `ScaledUiAmountConfig` and `PausableConfig`. Under anchor-spl 1.2.0 (interface 2.x), `get_extension_types()` fails with `InvalidAccountData` on a PermissionedBurn mint, while `get_extension::<T>()` still works.
- Allow-list the extensions you support. PermanentDelegate, TransferHook, Pausable, DefaultAccountState, NonTransferable and TransferFeeConfig each change what your program or UI can rely on; the attack side is in [security.md, Token-2022 section](../ext/solana-dev/skills/solana-dev/references/security.md#token-2022-extension-security).
- Show balances with the mint's UI conversion when InterestBearingConfig or ScaledUiAmount is present: [display-amounts](references/display-amounts.md).

## Related

- [kit/programs/token-2022.md](../ext/solana-dev/skills/solana-dev/references/kit/programs/token-2022.md): the Kit client basics. Its "Extension Initialization Order" puts every extension before the mint initialize; TokenMetadata, TokenGroup and TokenGroupMember go after it, as in [Create a mint](#create-a-mint). [confidential-transfers.md](../ext/solana-dev/skills/solana-dev/references/confidential-transfers.md): the Rust confidential flow; [confidential](references/confidential.md) lists what in it is out of date. [testing.md](../ext/solana-dev/skills/solana-dev/references/testing.md): LiteSVM and Mollusk.
- NFTs and collections: the skills hub also routes to the Metaplex skill (install first: `bash .claude/bin/skills.sh add metaplex`).
- Official guides: https://solana.com/docs/tokens/extensions
