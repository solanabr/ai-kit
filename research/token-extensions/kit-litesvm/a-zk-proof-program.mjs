// Part A probe: is the ZK ElGamal proof program usable in LiteSVM's default (mainnet) feature set?
// Real PubkeyValidity proof from @solana/zk-sdk, verified by ZkE1Gama1Proof11111111111111111111111111111.
import { address } from '@solana/kit';
import { ElGamalKeypair, PubkeyValidityProofData } from '@solana/zk-sdk';
import { verifyPubkeyValidity } from '@solana-program/zk-elgamal-proof';
import { FeatureSet, LiteSVM } from 'litesvm';
import { getAddressEncoder } from '@solana/kit';
import { setup, send, check, fmtErr } from './lib.mjs';

const proof = new PubkeyValidityProofData(new ElGamalKeypair()).toBytes();

async function run(label, svmOverride) {
  const ctx = await setup();
  const svm = svmOverride ?? ctx.svm;
  if (svmOverride) svm.airdrop(ctx.payer.address, 10_000_000_000n);
  const ixs = await verifyPubkeyValidity({ rpc: ctx.rpc, payer: ctx.payer, proofData: proof });
  const r = await send(svm, ctx.payer, ixs);
  const disabled = (r.logs || []).some((l) => l.includes('temporarily disabled'));
  console.log(`  ${label}: ok=${r.ok} cu=${r.cu} disabledMsg=${disabled}${r.ok ? '' : ' ' + fmtErr(r)}`);
  return { r, disabled };
}

const a = await run('default new LiteSVM()');
check('A4 ZK ElGamal proof program verifies a real PubkeyValidity proof in default LiteSVM', a.r.ok);

// Simulate the 2025 outage state: disable active, reenable NOT active.
const enc = getAddressEncoder();
const fsOutage = FeatureSet.allEnabled();
fsOutage.deactivate(enc.encode(address('zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN')));
const outageSvm = new LiteSVM().withFeatureSet(fsOutage).withBuiltins().withSysvars().withDefaultPrograms();
const b = await run('allEnabled minus reenable_zk_elgamal_proof_program', outageSvm);
check('A4 with reenable gate deactivated the program refuses ("temporarily disabled")', !b.r.ok && b.disabled);
