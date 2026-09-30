# Metadata and groups

MetadataPointer, TokenMetadata, GroupPointer, TokenGroup, GroupMemberPointer and TokenGroupMember all live on the mint. A pointer says which account holds the data. Token-2022 itself stores metadata, group and member data only inside the mint, so the usual setup points each pointer at the mint.

## Metadata

- **MetadataPointer** `{ authority, metadata_address }`, initialized before `InitializeMint`. The program doesn't check the target; point it at the mint unless another program holds the metadata. Update it with the pointer authority (SetAuthority type `MetadataPointer`, CLI `metadata-pointer`).
- **TokenMetadata** `{ update_authority, mint, name, symbol, uri, additional_metadata }`, variable length. Initialize it after `InitializeMint`:
  - The metadata account must be the mint itself (`MintMismatch`), and the mint needs a MetadataPointer (`InvalidExtensionCombination`).
  - The mint authority signs initialize. The update authority is just an address there; it signs everything after.
- **Updates** (update authority signs; the mint authority has no say): `UpdateField` with `Name`, `Symbol`, `Uri` or `Key(custom)`; `RemoveKey` for custom keys (optionally idempotent); `UpdateAuthority`, where None makes the metadata permanently immutable (`ImmutableMetadata` afterwards); `Emit` returns the Borsh-encoded metadata as return data. Rotate the update authority with `UpdateAuthority` (CLI `spl-token authorize <MINT> metadata <NEW>`), not SetAuthority.
- **Rent:** initialize and every update resize the mint but move no lamports, and the mint must stay rent-exempt at its new size. Send the lamports before the instruction that grows it, or from a program top up in the same instruction. Shrinking leaves the extra lamports in the mint (the mint authority can reclaim them with `WithdrawExcessLamports`).
- Readers should check that the pointer and `metadata.mint` both refer to this mint, since pointers can name any account.

### CLI

```sh
spl-token --program-2022 create-token --enable-metadata      # pointer at the mint, authority = mint authority
spl-token initialize-metadata <MINT> <NAME> <SYMBOL> <URI> [--update-authority <ADDRESS>]
spl-token update-metadata <MINT> <name|symbol|uri|CUSTOM_KEY> <VALUE>   # --remove deletes a custom key
spl-token update-metadata-address <MINT> <ADDRESS>            # or --disable
```

The CLI's metadata commands fund the extra rent themselves.

### Kit

- Create: `extension('MetadataPointer', { authority, metadataAddress: mint })` plus `extension('TokenMetadata', { updateAuthority, mint, name, symbol, uri, additionalMetadata: new Map() })` in `createMint` (see SKILL.md). It funds rent for the full metadata but initializes only name, symbol and URI; set extra fields with update instructions afterwards. With `updateAuthority: null` it skips the metadata initialize entirely.
- Update: `getUpdateTokenMetadataFieldInstruction({ metadata: mint, updateAuthority, field: tokenMetadataField('Key', ['tier']), value: 'gold' })` (or `tokenMetadataField('Name' | 'Symbol' | 'Uri')`). No Kit helper tops up rent for a growing field: before the update, transfer the difference between `getMinimumBalance(getMintSize(updatedExtensions))` and the mint's current lamports.
- Also: `getRemoveTokenMetadataKeyInstruction({ metadata, updateAuthority, key, idempotent })`, `getUpdateTokenMetadataUpdateAuthorityInstruction({ metadata, updateAuthority, newUpdateAuthority })`, `getEmitTokenMetadataInstruction({ metadata })`, `getUpdateMetadataPointerInstruction({ mint, metadataPointerAuthority, metadataAddress })`.

web3.js 1.x: `tokenMetadataInitializeWithRentTransfer` and `tokenMetadataUpdateFieldWithRentTransfer` add the rent; `getTokenMetadata(connection, mint)` reads the mint's own metadata and doesn't follow the pointer.

### Anchor 1.2.0

`init` takes `extensions::metadata_pointer::{authority, metadata_address}`; TokenMetadata is a CPI after that. anchor-spl's metadata helpers never move lamports, so top up in the same instruction (Anchor's own tests do it right after the CPI):

```rust
use anchor_lang::prelude::*;
use anchor_lang::system_program::{transfer, Transfer};
use anchor_spl::token_interface::{token_metadata_initialize, Mint, Token2022, TokenMetadataInitialize};

#[derive(Accounts)]
pub struct CreateMint<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(
        init,
        signer,
        payer = payer,
        mint::decimals = 6,
        mint::authority = payer,
        mint::token_program = token_program,
        extensions::metadata_pointer::authority = payer,
        extensions::metadata_pointer::metadata_address = mint,
    )]
    pub mint: InterfaceAccount<'info, Mint>,
    pub token_program: Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}

pub fn create_mint(ctx: Context<CreateMint>, name: String, symbol: String, uri: String) -> Result<()> {
    let accounts = TokenMetadataInitialize {
        program_id: ctx.accounts.token_program.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        metadata: ctx.accounts.mint.to_account_info(), // the metadata lives in the mint
        mint_authority: ctx.accounts.payer.to_account_info(),
        update_authority: ctx.accounts.payer.to_account_info(),
    };
    token_metadata_initialize(CpiContext::new(ctx.accounts.token_program.key(), accounts), name, symbol, uri)?;

    // Token-2022 grew the mint but moved no lamports: top it up to rent-exempt
    let mint = ctx.accounts.mint.to_account_info();
    let shortfall = Rent::get()?.minimum_balance(mint.data_len()).saturating_sub(mint.lamports());
    if shortfall > 0 {
        let from = ctx.accounts.payer.to_account_info();
        transfer(CpiContext::new(ctx.accounts.system_program.key(), Transfer { from, to: mint }), shortfall)?;
    }
    Ok(())
}
```

Other helpers: `token_metadata_update_field(ctx, Field::Key("tier".into()), value)`, `token_metadata_remove_key(ctx, key, idempotent)`, `token_metadata_update_authority(ctx, new_authority)` (an `OptionalNonZeroPubkey`). `Field` comes from `anchor_spl::token_interface::spl_token_metadata_interface::state`. anchor-spl 1.2.0 has no `metadata_pointer_update`. Read metadata with `StateWithExtensions::<Mint>::unpack(&data)?.get_variable_len_extension::<TokenMetadata>()`.

## Groups (collections)

- The collection mint carries **GroupPointer** `{ authority, group_address }` and **TokenGroup** `{ update_authority, mint, size, max_size }`. Each member mint carries **GroupMemberPointer** `{ authority, member_address }` and **TokenGroupMember** `{ mint, group, member_number }`. As with metadata, the group and member data must sit in their own mints and need their pointer.
- `InitializeGroup`: the collection's mint authority signs and sets the update authority (may be None) and `max_size`.
- `InitializeMember`: both the member mint's authority and the group update authority sign, and the group must be a Token-2022 mint. `member_number` becomes the new size, so the first member is 1. A mint can join one group, and can't be a member of itself.
- A group whose update authority is None can never add members (`ImmutableGroup`). Past `max_size`, adding fails with `SizeExceedsMaxSize`. `UpdateGroupMaxSize` can't go below the current size (`SizeExceedsNewMaxSize`). Rotate the group update authority with `UpdateGroupAuthority` (CLI `spl-token authorize <MINT> group <NEW>`); the pointers use SetAuthority `GroupPointer` / `GroupMemberPointer`.
- Group and member initializers grow the mint like metadata does and move no lamports either.

| | Collection mint | Member mint |
|---|---|---|
| CLI | `create-token --enable-group`, then `initialize-group <MINT> <MAX_SIZE>`; `update-group-max-size`, `update-group-address` | `create-token --enable-member`, then `initialize-member <MEMBER_MINT> <GROUP_MINT> [--group-update-authority <KEYPAIR>]`; `update-member-address` |
| Kit | `extension('GroupPointer', { authority, groupAddress: mint })`, `extension('TokenGroup', { updateAuthority, mint, size: 0n, maxSize })` in `createMint` | `extension('GroupMemberPointer', { authority, memberAddress: mint })`; `createMint` funds `extension('TokenGroupMember', ...)` but doesn't initialize it, so add `getInitializeTokenGroupMemberInstruction({ member: mint, memberMint: mint, memberMintAuthority, group, groupUpdateAuthority })` |
| Anchor 1.2.0 | `extensions::group_pointer::{authority, group_address}` on `init`; `token_group_initialize(ctx, update_authority, max_size)`; `group_pointer_update` | `extensions::group_member_pointer::{authority, member_address}` on `init`; `token_member_initialize(ctx)`; `group_member_pointer_update` |

Kit also has `getUpdateTokenGroupMaxSizeInstruction` and `getUpdateTokenGroupUpdateAuthorityInstruction`; anchor-spl 1.2.0 has neither.

Wallet, marketplace and DEX support for Token-2022 groups is thin (Orca's pools reject group and member mints). For NFT collections, Metaplex Core is usually the better fit; the skills hub routes to the Metaplex skill.
