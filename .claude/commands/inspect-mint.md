---
description: "Decode a token mint's extensions and live authorities, and flag integration risks"
---

Inspect the mint in $ARGUMENTS: what it takes to integrate, and who can still change it. Read-only. Meanings, venue matrix and checks: [integrating-mints.md](../skills/token-2022/integrating-mints.md); per-extension rules: [token-2022.md](../skills/token-2022.md).

## Inputs

| Input | Notes |
|---|---|
| `mint` | Required. |
| `rpc` or `cluster` | Default mainnet. Prefer the project's provider (`HELIUS_API_KEY` in `.env`: `https://mainnet.helius-rpc.com/?api-key=<key>`); public RPCs rate-limit. |
| `for` | `integrate` (default: a program, frontend or venue accepting the mint) or `issue` (an issuer reviewing their own mint before launch). |

## 1. Decode from raw bytes

Don't read extensions from RPC `jsonParsed` or `spl-token display`. Agave RPC nodes before 4.2 decode with `spl-token-2022-interface` 2.x, and for a mint that carries PermissionedBurn they return no `extensions` field at all, hiding a permanent delegate or hook on the same mint. `spl-token` 5.5.0 and a `--locked` 5.6.1 build use the same decoder. Decode with Kit 0.19 instead: from the project root if it already depends on `@solana/kit` ^8.3 and `@solana-program/token-2022` ^0.19, otherwise from a temp dir:

```bash
D=$(mktemp -d) && cd "$D" && npm init -y >/dev/null && npm i -q @solana/kit@^8.3 @solana-program/token-2022@^0.19
node inspect-mint.mjs <mint> <rpc-url>
```

```js
// node inspect-mint.mjs <mint> [rpc-url]: decode a mint from raw bytes (RPC jsonParsed can drop extensions)
import { address, createSolanaRpc, fetchEncodedAccount, unwrapOption } from '@solana/kit';
import { decodeMint, findExtraAccountMetaListPda, TOKEN_PROGRAM_ADDRESS, TOKEN_2022_PROGRAM_ADDRESS } from '@solana-program/token-2022';

const [mintArg, url = 'https://api.mainnet-beta.solana.com'] = process.argv.slice(2);
const rpc = createSolanaRpc(url);
const mint = address(mintArg);
const account = await fetchEncodedAccount(rpc, mint);
if (!account.exists) throw new Error('account not found on this cluster');
const is2022 = account.programAddress === TOKEN_2022_PROGRAM_ADDRESS;
if (!is2022 && account.programAddress !== TOKEN_PROGRAM_ADDRESS) throw new Error(`owned by ${account.programAddress}, not a token program`);
const len = account.data.length; // 82 = classic mint; extended mints carry account type 1 at byte 165 and are never 355 (multisig) bytes
if (len !== 82 && (len <= 165 || len === 355 || account.data[165] !== 1)) throw new Error('not a mint (token account or multisig)');
const { data } = decodeMint(account);
const extensions = unwrapOption(data.extensions) ?? [];
const hook = extensions.find((e) => e.__kind === 'TransferHook');
let hookMetaList = null;
if (hook && hook.programId !== '11111111111111111111111111111111') {
  const [pda] = await findExtraAccountMetaListPda({ mint }, { programAddress: hook.programId });
  hookMetaList = { address: pda, exists: (await fetchEncodedAccount(rpc, pda)).exists };
}
const { epoch } = await rpc.getEpochInfo().send();
const plain = (_, v) => typeof v === 'bigint' ? v.toString() : v instanceof Map ? Object.fromEntries(v)
  : v?.__option ? (v.__option === 'Some' ? v.value : null) : v;
console.log(JSON.stringify({ mint, program: is2022 ? 'Token-2022' : 'SPL Token', epoch, ...data, extensions, hookMetaList }, plain, 2));
```

## 2. Follow up

- **Hook program set** (not `1111...`): `solana program show <hook> -u <rpc>` for its upgrade authority (none means immutable). `hookMetaList.exists: false` means clients resolve no extra accounts, so the hook must work without them or every transfer fails.
- **Transfer fee:** the active fee is `newerTransferFee` once `epoch >= newerTransferFee.epoch`, else `olderTransferFee`. A newer fee with a future epoch is a scheduled change.
- **ScaledUiAmount** with a future `newMultiplierEffectiveTimestamp`, or InterestBearing: the displayed amount will move; say by how much.
- **MetadataPointer** to another address: the metadata lives there (possibly another program); fetch it only if the report needs name or symbol.
- **SPL Token mint:** no extensions; report mint and freeze authority only.

## 3. Report

Print it in chat; write a file only if asked.

```
## Mint <address> (<cluster>, epoch <n>)
Program: <Token-2022 | SPL Token> | decimals <d> | supply <raw> | mint authority <addr|none> | freeze authority <addr|none>
### Extensions
| extension | state | authority | what it means for you |
### Who can still change this mint
- <authority address>: <what it can do, and when it takes effect>
### To integrate
- <transfer_checked, hook-aware path, fee netting from balance deltas, pause check, ...>
### Venues (integrating-mints.md matrix, dated)
| Orca | Raydium CPMM / CLMM | Meteora DAMM v2 | Kamino | marginfi |
### Flags
- high: <e.g. live permanent delegate, live hook with an upgradeable program, live pause authority>
- watch: <dormant extensions with live authorities, scheduled fee or multiplier changes, live mint or freeze authority>
```

For `issue`, add the checks from [token-2022.md, Before launch](../skills/token-2022.md#before-launch): authorities to revoke or move to a multisig, and venues the extension set rules out.

## Guardrails

- Never ask for a private key; this command reads and never signs or sends.
- Venue support comes from source read on the matrix's date; say so, and mark a devnet mint's venue column as not applicable.
- Report authorities as addresses and don't guess who controls one. Say whether it is a program (`getAccountInfo` shows `executable`); beyond that, "unknown" unless the user says.
