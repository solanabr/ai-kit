# Metadata and groups (extensions 18–23), and the Kit mint plan

Creating mints with on-mint metadata and group/member relationships. Official guides: [metadata](https://solana.com/docs/tokens/extensions/metadata), [group-member](https://solana.com/docs/tokens/extensions/group-member), [dynamic-metadata-nft](https://solana.com/docs/tokens/extensions/dynamic-metadata-nft). Kit behavior verified 2026-09-28 with `@solana-program/token-2022` 0.19 in LiteSVM.

## Creating a mint with the Kit plan

`getCreateMintInstructionPlan` builds the whole mint (account creation, sizing that excludes variable-length extensions, rent for the final size, pre- and post-initialize instructions). It returns an instruction plan for your executor:

```ts
import { createClientWithGetMinimumBalanceFromRpc, some } from '@solana/kit';
import { extension, getCreateMintInstructionPlan } from '@solana-program/token-2022';

const client = createClientWithGetMinimumBalanceFromRpc(rpc); // only getMinimumBalance is needed
const plan = await getCreateMintInstructionPlan(client, {
  payer, newMint: mint, decimals: 6, mintAuthority: payer, // mintAuthority must be a signer, not an address
  extensions: [
    extension('TransferFeeConfig', {
      transferFeeConfigAuthority: payer.address, withdrawWithheldAuthority: payer.address, withheldAmount: 0n,
      olderTransferFee: { epoch: 0n, maximumFee: 1_000_000n, transferFeeBasisPoints: 50 },
      newerTransferFee: { epoch: 0n, maximumFee: 1_000_000n, transferFeeBasisPoints: 50 }, // the plan reads this one
    }),
    extension('MetadataPointer', { authority: some(payer.address), metadataAddress: some(mint.address) }),
    extension('TokenMetadata', {
      updateAuthority: some(payer.address), mint: mint.address,
      name: 'Token', symbol: 'TKN', uri: 'https://example.com/t.json',
      additionalMetadata: new Map([['issuer', 'acme']]),
    }),
  ],
});
```

- Kit kind names are the state names, and three differ from the Rust `ExtensionType` names: `PausableConfig` (`{ authority, paused }`), `ScaledUiAmountConfig` and `ConfidentialTransferFee`. Args are the full on-chain state, but the plan uses only the fields that initialization takes.
- A TransferHook kept dormant for later uses `programId: '11111111111111111111111111111111'` (it's a plain address, not an option).
- Pass `extensions: undefined` for a plain mint. An empty array sizes the account for extensions and fails with `InvalidAccountData`.

What the plan silently leaves out (each case creates the mint without error):

- `additionalMetadata` is never written, though its rent is paid. Add each field afterwards with `getUpdateTokenMetadataFieldInstruction({ metadata, updateAuthority, field: tokenMetadataField('Key', ['issuer']), value })`. It needs no extra rent when the key and value match what you passed; anything longer needs a top-up first.
- With `updateAuthority: none()`, TokenMetadata is not initialized at all. Set an authority, then remove it later if the metadata must be immutable.
- `TokenGroupMember` is not initialized. Call `getInitializeTokenGroupMemberInstruction` afterwards; the plan already funded its rent.
- The plan uses `InitializeMint` (v1), not `InitializeMint2`.

## Metadata rules

- The metadata pointer must point at the mint itself for TokenMetadata to live on the mint; readers must check the pointer ([security.md, metadata spoofing](../ext/solana-dev/skills/solana-dev/references/security.md#metadata-spoofing-and-memo-requirements)).
- Initialize, `UpdateField` and `RemoveKey` resize the mint but never move lamports: fund the new rent first (web3.js `tokenMetadataUpdateFieldWithRentTransfer`; in Anchor top up to `Rent::minimum_balance(new_len)` before `token_metadata_update_field`).
- Readers: DAS providers (Metaplex `digital-asset-rpc-infrastructure`, which Helius runs) parse the TokenMetadata extension on the mint as well as the Metaplex metadata PDA, and Solana Explorer shows both. Jupiter's token verification reportedly reads Token-2022 metadata through the metadata pointer; confirm against Jupiter's docs before relying on it.
- Choose Metaplex Token Metadata (it also works on Token-2022 mints) when you need creators, royalties, editions or marketplace tooling built on the Metaplex PDA. Choose the extension for a simple fungible where one account and one rent payment matter.
- Classic SPL Token mints have no extensions and need Metaplex Token Metadata.

## Groups and members

- Group mint: GroupPointer (to itself), initialize the mint, then `InitializeGroup { update_authority, max_size }`. Member mint: GroupMemberPointer, initialize the mint, then `InitializeMember`, signed by the member mint's authority and the group's update authority. Past `max_size` it fails.
- Support is thin: Orca Whirlpools rejects group and member mints, and wallets rarely display them. The Foundation docs don't recommend groups over Metaplex Core or the reverse; for NFT collections with royalties, plugins and marketplace support, Core is the practical default ([metaplex](../ext/metaplex/skills/metaplex/SKILL.md)).
