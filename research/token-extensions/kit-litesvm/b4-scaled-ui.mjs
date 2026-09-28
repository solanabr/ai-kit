// B4: ScaledUiAmount: Kit amount->UI helpers vs raw amount vs on-chain AmountToUiAmount return data.
import { generateKeyPairSigner } from '@solana/kit';
import {
  amountToUiAmountForMintWithoutSimulation,
  amountToUiAmountForScaledUiAmountMintWithoutSimulation,
  uiAmountToAmountForMintWithoutSimulation,
  extension,
  fetchMint,
  getAmountToUiAmountInstruction,
  getCreateMintInstructionPlan,
  getUpdateMultiplierScaledUiMintInstruction,
} from '@solana-program/token-2022';
import { unwrapOption } from '@solana/kit';
import { setup, send, check, fmtErr } from './lib.mjs';

const { svm, rpc, client, payer } = await setup({ token2022So: process.env.T22_SO });
const mint = await generateKeyPairSigner();
let r = await send(svm, payer, await getCreateMintInstructionPlan(client, {
  payer, newMint: mint, decimals: 6, mintAuthority: payer,
  extensions: [extension('ScaledUiAmountConfig', { authority: payer.address, multiplier: 1.5, newMultiplierEffectiveTimestamp: 0n, newMultiplier: 1.5 })],
}));
check('B4 create ScaledUiAmount mint (multiplier 1.5)', r.ok, r.ok ? '' : fmtErr(r));

const onChain = async (amount) => {
  const res = await send(svm, payer, [getAmountToUiAmountInstruction({ mint: mint.address, amount })]);
  // return data is the UI amount string; LiteSVM exposes it via the success metadata logs ("Program return: <id> <base64>")
  const line = res.logs.find((l) => l.startsWith('Program return:'));
  return Buffer.from(line.split(' ').pop(), 'base64').toString();
};

const raw = 1_234_567n;
const pure = amountToUiAmountForScaledUiAmountMintWithoutSimulation(raw, 6, 1.5);
const viaRpc = await amountToUiAmountForMintWithoutSimulation(rpc, mint.address, raw);
const chain = await onChain(raw);
console.log(`  raw=${raw} decimals=6 multiplier=1.5 -> pure=${pure} viaRpc=${viaRpc} onChain=${chain}`);
check('B4 FINDING: Kit helper rounds, on-chain truncates (1234567 * 1.5 = 1851850.5 base units)', pure === '1.851851' && chain === '1.85185', `helper=${pure} chain=${chain}`);
const back = await uiAmountToAmountForMintWithoutSimulation(rpc, mint.address, viaRpc);
console.log(`  uiAmountToAmount(${viaRpc}) = ${back} (raw was ${raw})`);

// Schedule a new multiplier in the future, then warp the clock past it.
const now = svm.getClock().unixTimestamp;
r = await send(svm, payer, [getUpdateMultiplierScaledUiMintInstruction({ mint: mint.address, authority: payer, multiplier: 2, effectiveTimestamp: now + 3600n })]);
check('B4 schedule multiplier 2.0 in +1h', r.ok, r.ok ? '' : fmtErr(r));
const before = await amountToUiAmountForMintWithoutSimulation(rpc, mint.address, raw);
const chainBefore = await onChain(raw);
const clock = svm.getClock();
clock.unixTimestamp = now + 3601n;
svm.setClock(clock);
const after = await amountToUiAmountForMintWithoutSimulation(rpc, mint.address, raw);
const chainAfter = await onChain(raw);
console.log(`  before effective: helper=${before} chain=${chainBefore}; after warp: helper=${after} chain=${chainAfter}`);
check('B4 helper and chain both switch to newMultiplier after clock passes effectiveTimestamp', after === chainAfter && after === '2.469134' && before === '1.851851');
const cfg = unwrapOption((await fetchMint(rpc, mint.address)).data.extensions).find((e) => e.__kind === 'ScaledUiAmountConfig');
console.log('  stored config:', { multiplier: cfg.multiplier, newMultiplier: cfg.newMultiplier, effective: cfg.newMultiplierEffectiveTimestamp });
// Edge: rounding/truncation for non-representable results
// Edge cases against the chain at multiplier 2.0 (now active) and a fresh 0.99 multiplier.
let mismatches = 0;
for (const a of [1n, 3n, 5n, 7n, 999_999_999n]) {
  const p = await amountToUiAmountForMintWithoutSimulation(rpc, mint.address, a);
  const c = await onChain(a);
  if (p !== c) mismatches++;
}
r = await send(svm, payer, [getUpdateMultiplierScaledUiMintInstruction({ mint: mint.address, authority: payer, multiplier: 0.99, effectiveTimestamp: 0n })]);
for (const a of [1n, 101n, 12_345n, 1_000_001n]) {
  const p = await amountToUiAmountForMintWithoutSimulation(rpc, mint.address, a);
  const c = await onChain(a);
  console.log(`  multiplier 0.99 amount=${a}: helper=${p} chain=${c}${p === c ? '' : '  <-- MISMATCH'}`);
  if (p !== c) mismatches++;
}
console.log(`  total helper/chain mismatches in edge set: ${mismatches}`);
