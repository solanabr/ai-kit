// B3: PermissionedBurn: plain burnChecked fails; permissionedBurnChecked with the burn-authority co-signer succeeds.
import { generateKeyPairSigner, some } from '@solana/kit';
import {
  extension,
  fetchToken,
  findAssociatedTokenPda,
  getBurnCheckedInstruction,
  getCreateAssociatedTokenIdempotentInstructionAsync,
  getCreateMintInstructionPlan,
  getMintToCheckedInstruction,
  getPermissionedBurnCheckedInstruction,
  TOKEN_2022_PROGRAM_ADDRESS,
} from '@solana-program/token-2022';
import { setup, send, check, fmtErr, newFundedSigner } from './lib.mjs';

const { svm, rpc, client, payer } = await setup({ token2022So: process.env.T22_SO });
const burnAuthority = await newFundedSigner(svm);
const alice = await newFundedSigner(svm);
const mint = await generateKeyPairSigner();

let r = await send(svm, payer, await getCreateMintInstructionPlan(client, {
  payer, newMint: mint, decimals: 6, mintAuthority: payer,
  extensions: [extension('PermissionedBurn', { authority: some(burnAuthority.address) })],
}));
check('B3 create PermissionedBurn mint', r.ok, r.ok ? '' : fmtErr(r));

const [aliceAta] = await findAssociatedTokenPda({ owner: alice.address, mint: mint.address, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS });
r = await send(svm, payer, [
  await getCreateAssociatedTokenIdempotentInstructionAsync({ payer, owner: alice.address, mint: mint.address, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS }),
  getMintToCheckedInstruction({ mint: mint.address, token: aliceAta, mintAuthority: payer, amount: 1_000_000n, decimals: 6 }),
]);
check('B3 ATA + mintTo', r.ok, r.ok ? '' : fmtErr(r));

r = await send(svm, payer, [getBurnCheckedInstruction({ account: aliceAta, mint: mint.address, authority: alice, amount: 100n, decimals: 6 })]);
check('B3 plain burnChecked by owner fails', !r.ok, r.ok ? 'unexpectedly succeeded' : `code=${r.customCode} ${fmtErr(r)}`);

// Permissioned variant signed by owner only (burn authority passed as non-signer is impossible via the typed builder,
// so use a wrong signer in that slot).
const wrong = await newFundedSigner(svm);
r = await send(svm, payer, [getPermissionedBurnCheckedInstruction({ account: aliceAta, mint: mint.address, permissionedBurnAuthority: wrong, authority: alice, amount: 100n, decimals: 6 })]);
check('B3 permissionedBurnChecked with wrong burn authority fails', !r.ok, r.ok ? 'unexpectedly succeeded' : `code=${r.customCode} ${fmtErr(r)}`);

r = await send(svm, payer, [getPermissionedBurnCheckedInstruction({ account: aliceAta, mint: mint.address, permissionedBurnAuthority: burnAuthority, authority: alice, amount: 100n, decimals: 6 })]);
check('B3 permissionedBurnChecked (owner + burn authority) succeeds', r.ok, r.ok ? `CU=${r.cu}` : fmtErr(r));
const t = await fetchToken(rpc, aliceAta);
check('B3 balance reduced', t.data.amount === 999_900n, `amount=${t.data.amount}`);
