# Metadata and groups (extensions 18–23)

Creating mints with on-mint metadata and group/member relationships. Official guides: [metadata](https://solana.com/docs/tokens/extensions/metadata), [group-member](https://solana.com/docs/tokens/extensions/group-member), [dynamic-metadata-nft](https://solana.com/docs/tokens/extensions/dynamic-metadata-nft). Kit behavior verified 2026-09-28 with `@solana-program/token-2022` 0.19 in LiteSVM.

## Creating a mint with the Kit plan

`getCreateMintInstructionPlan` builds the whole mint (account creation, sizing that excludes variable-length extensions, rent for the final size, pre- and post-initialize instructions):

```ts
import { some } from "@solana/kit";
import {
  extension,
  getCreateMintInstructionPlan,
} from "@solana-program/token-2022";

const plan = await getCreateMintInstructionPlan(client, {
  // client: { rpc, getMinimumBalance }
  payer,
  newMint: mint,
  decimals: 6,
  mintAuthority: payer,
  extensions: [
    extension("MetadataPointer", {
      authority: some(payer.address),
      metadataAddress: some(mint.address),
    }),
    extension("TokenMetadata", {
      updateAuthority: some(payer.address),
      mint: mint.address,
      name: "Token",
      symbol: "TKN",
      uri: "https://example.com/t.json",
      additionalMetadata: new Map([["issuer", "acme"]]),
    }),
  ],
});
```

What the plan silently leaves out (each case creates the mint without error):

- `additionalMetadata` is never written, though its rent is paid. Add each field afterwards with `getUpdateTokenMetadataFieldInstruction({ field: tokenMetadataField('Key', ['issuer']), value })`; no top-up is needed.
- With `updateAuthority: none()`, TokenMetadata is not initialized at all. Set an authority, then remove it later if the metadata must be immutable.
- `TokenGroupMember` is not initialized. Call `getInitializeTokenGroupMemberInstruction` afterwards; the plan already funded its rent.
- The plan uses `InitializeMint` (v1), not `InitializeMint2`.

## Metadata rules

- The metadata pointer must point at the mint itself for TokenMetadata to live on the mint, and readers verify that pointer and `metadata.mint` reference each other.
- Initialize, `UpdateField` and `RemoveKey` resize the mint but never move lamports: fund the new rent first (web3.js `tokenMetadataUpdateFieldWithRentTransfer`; in Anchor top up to `Rent::minimum_balance(new_len)` before `token_metadata_update_field`).
- Readers: DAS providers (Metaplex `digital-asset-rpc-infrastructure`, which Helius runs) parse the TokenMetadata extension on the mint as well as the Metaplex metadata PDA, and Solana Explorer shows both. Jupiter's token verification reportedly reads Token-2022 metadata through the metadata pointer; confirm against Jupiter's docs before relying on it.
- Choose Metaplex Token Metadata (it also works on Token-2022 mints) when you need creators, royalties, editions or marketplace tooling built on the Metaplex PDA. Choose the extension for a simple fungible where one account and one rent payment matter.
- Classic SPL Token mints have no extensions and need Metaplex Token Metadata.

## Groups and members

- Group mint: GroupPointer (to itself), initialize the mint, then `InitializeGroup { update_authority, max_size }`. Member mint: GroupMemberPointer, initialize the mint, then `InitializeMember`, signed by the member mint's authority and the group's update authority. Past `max_size` it fails.
- Support is thin: Orca Whirlpools rejects group and member mints, and wallets rarely display them. The Foundation docs don't recommend groups over Metaplex Core or the reverse; for NFT collections with royalties, plugins and marketplace support, Core is the practical default ([metaplex](../ext/metaplex/skills/metaplex/SKILL.md)).
