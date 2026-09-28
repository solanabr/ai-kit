// B2: Pausable mint: pause -> transferChecked fails (MintPaused) -> resume -> succeeds.
import { generateKeyPairSigner, some } from '@solana/kit';
import {
  extension,
  findAssociatedTokenPda,
  getCreateAssociatedTokenIdempotentInstructionAsync,
  getCreateMintInstructionPlan,
  getMintToCheckedInstruction,
  getPauseInstruction,
  getResumeInstruction,
  getTransferCheckedInstruction,
  TOKEN_2022_PROGRAM_ADDRESS,
} from '@solana-program/token-2022';
import { setup, send, check, fmtErr, newFundedSigner } from './lib.mjs';

const { svm, client, payer } = await setup({ token2022So: process.env.T22_SO });
const pauseAuthority = await newFundedSigner(svm);
const alice = await newFundedSigner(svm);
const bob = (await generateKeyPairSigner()).address;
const mint = await generateKeyPairSigner();

const plan = await getCreateMintInstructionPlan(client, {
  payer, newMint: mint, decimals: 6, mintAuthority: payer,
  extensions: [extension('PausableConfig', { authority: some(pauseAuthority.address), paused: false })],
});
let r = await send(svm, payer, plan);
check('B2 create pausable mint', r.ok, r.ok ? '' : fmtErr(r));

const ata = async (owner) => (await findAssociatedTokenPda({ owner, mint: mint.address, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS }))[0];
const [aliceAta, bobAta] = [await ata(alice.address), await ata(bob)];
r = await send(svm, payer, [
  await getCreateAssociatedTokenIdempotentInstructionAsync({ payer, owner: alice.address, mint: mint.address, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS }),
  await getCreateAssociatedTokenIdempotentInstructionAsync({ payer, owner: bob, mint: mint.address, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS }),
  getMintToCheckedInstruction({ mint: mint.address, token: aliceAta, mintAuthority: payer, amount: 1_000_000n, decimals: 6 }),
]);
check('B2 create ATAs + mint', r.ok, r.ok ? '' : fmtErr(r));

const transfer = () => getTransferCheckedInstruction({ source: aliceAta, mint: mint.address, destination: bobAta, authority: alice, amount: 1000n, decimals: 6 });

r = await send(svm, payer, [getPauseInstruction({ mint: mint.address, authority: pauseAuthority })]);
check('B2 pause', r.ok, r.ok ? `CU=${r.cu}` : fmtErr(r));

r = await send(svm, payer, [transfer()]);
check('B2 transferChecked while paused fails with MintPaused (0x43 = 67)', !r.ok && r.customCode === 67, fmtErr(r));

r = await send(svm, payer, [getMintToCheckedInstruction({ mint: mint.address, token: aliceAta, mintAuthority: payer, amount: 1n, decimals: 6 })]);
check('B2 mintTo while paused also fails with MintPaused', !r.ok && r.customCode === 67, r.ok ? 'succeeded' : fmtErr(r));

r = await send(svm, payer, [getResumeInstruction({ mint: mint.address, authority: pauseAuthority })]);
check('B2 resume', r.ok, r.ok ? `CU=${r.cu}` : fmtErr(r));

r = await send(svm, payer, [transfer()]);
check('B2 transferChecked after resume succeeds', r.ok, r.ok ? `CU=${r.cu}` : fmtErr(r));
