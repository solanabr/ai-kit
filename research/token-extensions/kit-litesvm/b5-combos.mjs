// B5: extension combination rules enforced at InitializeMint.
import { generateKeyPairSigner, some } from '@solana/kit';
import { AccountState, extension, getCreateMintInstructionPlan } from '@solana-program/token-2022';
import { setup, send, check, fmtErr } from './lib.mjs';

const { svm, client, payer } = await setup({ token2022So: process.env.T22_SO });
const fee = { epoch: 0n, maximumFee: 10n, transferFeeBasisPoints: 100 };
const exts = {
  scaled: extension('ScaledUiAmountConfig', { authority: payer.address, multiplier: 1, newMultiplierEffectiveTimestamp: 0n, newMultiplier: 1 }),
  interest: extension('InterestBearingConfig', { rateAuthority: payer.address, initializationTimestamp: 0n, preUpdateAverageRate: 500, lastUpdateTimestamp: 0n, currentRate: 500 }),
  nonTransferable: extension('NonTransferable'),
  transferFee: extension('TransferFeeConfig', { transferFeeConfigAuthority: payer.address, withdrawWithheldAuthority: payer.address, withheldAmount: 0n, olderTransferFee: fee, newerTransferFee: fee }),
  frozenDefault: extension('DefaultAccountState', { state: AccountState.Frozen }),
};

async function tryMint(label, extensions, freezeAuthority) {
  const mint = await generateKeyPairSigner();
  const plan = await getCreateMintInstructionPlan(client, { payer, newMint: mint, decimals: 6, mintAuthority: payer, freezeAuthority, extensions });
  return send(svm, payer, plan);
}

let r = await tryMint('scaled+interest', [exts.scaled, exts.interest]);
check('B5 ScaledUiAmount + InterestBearing rejected with InvalidExtensionCombination (0x33 = 51)', !r.ok && r.customCode === 51, r.ok ? 'succeeded' : fmtErr(r));

r = await tryMint('nontransferable+fee', [exts.nonTransferable, exts.transferFee]);
check('B5 NonTransferable + TransferFee accepted', r.ok, r.ok ? `CU=${r.cu}` : fmtErr(r));

r = await tryMint('frozen default, no freeze authority', [exts.frozenDefault]);
check('B5 DefaultAccountState(Frozen) without freeze authority rejected (MintCannotFreeze 0x10 = 16)', !r.ok && r.customCode === 16, r.ok ? 'succeeded' : fmtErr(r));

r = await tryMint('frozen default + freeze authority', [exts.frozenDefault], some(payer.address));
check('B5 DefaultAccountState(Frozen) with freeze authority accepted', r.ok, r.ok ? '' : fmtErr(r));
