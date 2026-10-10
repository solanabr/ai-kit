---
name: address-lookup-tables
description: "Address lookup tables for the v0 fallback path: when to build one, create and extend it with @solana/kit, attach it to a v0 message, freeze or deactivate and close it."
---

# Address lookup tables on the v0 fallback path

New code sends v1 transactions, which take 4,096 bytes and 64 inline accounts and do not support lookup tables ([transactions-v1.md](ext/solana-dev/skills/solana-dev/references/transactions-v1.md)). A lookup table is for the other path: a wallet whose `supportedTransactionVersions` lacks `1` gets a `version: 0` transaction, capped at 1,232 bytes, and a composed transaction (a swap route plus a fee transfer plus an ATA create) only fits there with a table. Checked 2026-10-09 against `@solana/kit` 8.4 and `@solana-program/address-lookup-table` 0.15.

## Decide

- Wallet reports v1: send v1, no table.
- Wallet reports only `0` (or `legacy`) and the transaction is over 1,232 bytes: v0 with a table built ahead of time. Creating one on the user's first click costs extra transactions and at least a slot of waiting.
- A table buys size, not accounts: each lookup replaces a 32-byte key with a 1-byte index, but the 64-account lock limit is unchanged.
- Signers and invoked program IDs are never loaded from a table; they stay in the static keys. Kit's compression skips them for you.
- Tables a protocol already publishes (a Jupiter route returns its own `addressLookupTableAddresses`) are fetched and passed in the same way; don't copy their addresses into yours.

## Create and extend

The table address is a PDA of the authority and a recent slot, so create needs that slot: one still in the SlotHashes sysvar (the last 512 slots), usually `getSlot` at `finalized` or `confirmed`.

```ts
import {
  findAddressLookupTablePda,
  getCreateLookupTableInstructionAsync,
  getExtendLookupTableInstruction,
} from '@solana-program/address-lookup-table';

const recentSlot = await rpc.getSlot({ commitment: 'finalized' }).send();
const createIx = await getCreateLookupTableInstructionAsync({
  authority: authority.address, payer, recentSlot, // authority need not sign create; payer does
});
const [table] = await findAddressLookupTablePda({ authority: authority.address, recentSlot });

const extendIx = getExtendLookupTableInstruction({
  address: table, authority, payer, addresses: chunk, // payer funds the extra rent
});
```

- `extend` is a transaction too, and its size bounds the chunk: roughly 20 to 30 addresses per legacy or v0 transaction, several times that per v1 transaction. Create and extend are operator transactions, so send them as v1 from your own backend. A table holds at most 256 addresses; the authority signs every extend.
- Addresses added in a slot are not usable by transactions in that same slot. Wait for the next slot, or confirm the extend, before the first transaction that relies on them.
- Rent grows by 32 bytes per address; `close` returns it.
- The CLI does the same: `solana address-lookup-table create | extend | get | freeze | deactivate | close`.

## Attach to a v0 message

Plugin clients (`solanaRpc` from `@solana/kit-plugin-rpc`) do not compress against lookup tables as of 2026-10, so the v0 fallback is a message you build with `pipe()`:

```ts
import {
  appendTransactionMessageInstructions, compressTransactionMessageUsingAddressLookupTables,
  createTransactionMessage, fetchAddressesForLookupTables, pipe,
  setTransactionMessageComputeUnitLimit, setTransactionMessageComputeUnitPrice,
  setTransactionMessageFeePayerSigner, setTransactionMessageLifetimeUsingBlockhash,
  signTransactionMessageWithSigners,
} from '@solana/kit';

const addressesByTable = await fetchAddressesForLookupTables([table], rpc);
const message = pipe(
  createTransactionMessage({ version: 0 }),
  m => setTransactionMessageFeePayerSigner(payer, m),
  m => setTransactionMessageLifetimeUsingBlockhash(latestBlockhash, m),
  m => appendTransactionMessageInstructions(instructions, m),
  m => setTransactionMessageComputeUnitPrice(microLamports, m),
  m => setTransactionMessageComputeUnitLimit(units, m),
  m => compressTransactionMessageUsingAddressLookupTables(m, addressesByTable),
);
const signed = await signTransactionMessageWithSigners(message);
```

Compress before signing: the signature covers the compiled message, lookups included. Then check the size (`assertIsTransactionWithinSizeLimit`) and send as in [frontend.md](ext/solana-dev/skills/solana-dev/references/frontend.md). If it is still too large, the instructions reference addresses the table doesn't hold; extend it or split the transaction.

## Freeze, or keep the authority

- A live authority can append addresses to a table your transactions trust, and an instruction that reads accounts by position then receives whatever the index now points to. Auditor vector [103-address-lookup-table-manipulation.md](ext/auditor-skill/known-vectors/103-address-lookup-table-manipulation.md) covers the attack.
- `freeze` removes the authority for good: the table can never be extended, deactivated or closed, so its rent is locked permanently. Freeze a table that is complete and long-lived; keep the authority on a protected key for one that still grows.
- An empty or deactivated table cannot be frozen.

## Retire a table

1. `deactivate` (authority signs). Transactions can still use the table while it is deactivating.
2. Wait until the deactivation slot leaves SlotHashes: 512 slots, a few minutes. Before then `close` fails with "Table cannot be closed until it's fully deactivated in N blocks".
3. `close` with a recipient for the rent.

The same authority and slot can't recreate the table at that address afterwards; derive a new one from a new recent slot. Point clients at the new table before deactivating the old one, because a transaction that loads a closed table fails.
