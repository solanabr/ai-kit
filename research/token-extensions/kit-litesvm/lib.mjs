// Shared LiteSVM + Kit harness for the Token-2022 verification scripts.
import { LiteSVM } from 'litesvm';
import { createRpcFromSvm } from '@solana/kit-plugin-litesvm';
import {
  appendTransactionMessageInstructions,
  createTransactionMessage,
  flattenInstructionPlan,
  generateKeyPairSigner,
  lamports,
  pipe,
  setTransactionMessageFeePayerSigner,
  setTransactionMessageLifetimeUsingBlockhash,
  signTransactionMessageWithSigners,
} from '@solana/kit';

export async function setup({ token2022So } = {}) {
  const svm = new LiteSVM();
  if (token2022So) svm.addProgramFromFile('TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb', token2022So);
  const rpc = createRpcFromSvm(svm);
  // ClientWithGetMinimumBalance: `space` excludes the 128-byte header unless withoutHeader.
  // svm.minimumBalanceForRentExemption(dataLen) already adds the header itself.
  const client = {
    rpc,
    getMinimumBalance: async (space, cfg) =>
      lamports(svm.minimumBalanceForRentExemption(BigInt(cfg?.withoutHeader ? Math.max(0, space - 128) : space))),
  };
  const payer = await generateKeyPairSigner();
  svm.airdrop(payer.address, lamports(100_000_000_000n));
  return { svm, rpc, client, payer };
}

export async function newFundedSigner(svm) {
  const s = await generateKeyPairSigner();
  svm.airdrop(s.address, lamports(10_000_000_000n));
  return s;
}

// Send instructions (or an InstructionPlan, flattened into one tx) and return
// { ok, cu, logs, err, customCode }.
export async function send(svm, payer, ixsOrPlan) {
  const ixs = Array.isArray(ixsOrPlan)
    ? ixsOrPlan
    : flattenInstructionPlan(ixsOrPlan).map((p) => {
        if (p.kind !== 'single') throw new Error(`plan contains ${p.kind}, not flattenable`);
        return p.instruction;
      });
  const msg = pipe(
    createTransactionMessage({ version: 0 }),
    (m) => setTransactionMessageFeePayerSigner(payer, m),
    (m) => setTransactionMessageLifetimeUsingBlockhash({ blockhash: svm.latestBlockhash(), lastValidBlockHeight: 0n }, m),
    (m) => appendTransactionMessageInstructions(ixs, m),
  );
  const tx = await signTransactionMessageWithSigners(msg);
  const res = svm.sendTransaction(tx);
  svm.expireBlockhash();
  if (typeof res.err === 'function') {
    const err = res.err();
    const meta = res.meta();
    return { ok: false, err, customCode: extractCustom(err), logs: meta.logs(), cu: meta.computeUnitsConsumed() };
  }
  return { ok: true, logs: res.logs(), cu: res.computeUnitsConsumed() };
}

// litesvm errors are napi classes: TransactionErrorInstructionError.err() -> InstructionErrorCustom { code }.
function extractCustom(err) {
  const inner = typeof err?.err === 'function' ? err.err() : undefined;
  return typeof inner?.code === 'number' ? inner.code : undefined;
}

export function errString(err) {
  if (typeof err?.err === 'function') {
    const inner = err.err();
    const innerStr = typeof inner === 'object' ? inner.toString() : `InstructionErrorFieldless(${inner})`;
    return `InstructionError(ix ${err.index}, ${innerStr})`;
  }
  return typeof err === 'object' ? err.toString() : `TransactionErrorFieldless(${err})`;
}

export function fmtErr(r) {
  const s = errString(r.err);
  const programLine = (r.logs || []).filter((l) => /Error|error|failed/.test(l)).slice(-3).join(' | ');
  return `${s} :: ${programLine}`;
}

export function check(label, cond, extra = '') {
  console.log(`${cond ? 'PASS' : 'FAIL'} ${label}${extra ? ' — ' + extra : ''}`);
  if (!cond) process.exitCode = 1;
}

export const TOKEN_2022 = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
