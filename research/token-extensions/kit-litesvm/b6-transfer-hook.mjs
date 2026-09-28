// B6: transfer hook extra-account resolution against LiteSVM, bridged with createRpcFromSvm.
// Hook: Andy00L allowlist example (fail-closed, extra meta = PDA ["allow", mint, destination]).
import fs from 'node:fs';
import {
  AccountRole,
  generateKeyPairSigner,
  getAddressDecoder,
  getAddressEncoder,
  getProgramDerivedAddress,
  getUtf8Encoder,
} from '@solana/kit';
import {
  extension,
  findAssociatedTokenPda,
  findExtraAccountMetaListPda,
  getCreateAssociatedTokenIdempotentInstructionAsync,
  getCreateMintInstructionPlan,
  getDefaultInitializeExtraAccountMetaListInstructionAsync,
  getMintToCheckedInstruction,
  getTransferCheckedInstruction,
  getTransferCheckedWithTransferHookInstructionAsync,
  resolveExtraAccountMetasForExecute,
  TOKEN_2022_PROGRAM_ADDRESS,
} from '@solana-program/token-2022';
import { SYSTEM_PROGRAM_ADDRESS } from '@solana-program/system';
import { setup, send, check, fmtErr, newFundedSigner } from './lib.mjs';

const HOOK_DIR = process.env.HOOK_DIR ?? new URL('./hook/', import.meta.url).pathname;
const kp = JSON.parse(fs.readFileSync(HOOK_DIR + 'transfer_hook_allowlist-keypair.json'));
const hookProgram = getAddressDecoder().decode(Uint8Array.from(kp.slice(32)));

const { svm, rpc, client, payer } = await setup({ token2022So: process.env.T22_SO });
svm.addProgramFromFile(hookProgram, HOOK_DIR + 'transfer_hook_allowlist.so');
const alice = await newFundedSigner(svm);
const bob = (await generateKeyPairSigner()).address;
const mint = await generateKeyPairSigner();

let r = await send(svm, payer, await getCreateMintInstructionPlan(client, {
  payer, newMint: mint, decimals: 6, mintAuthority: payer,
  extensions: [extension('TransferHook', { authority: payer.address, programId: hookProgram })],
}));
check('B6 create TransferHook mint', r.ok, r.ok ? '' : fmtErr(r));

const ata = async (owner) => (await findAssociatedTokenPda({ owner, mint: mint.address, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS }))[0];
const [aliceAta, bobAta] = [await ata(alice.address), await ata(bob)];
r = await send(svm, payer, [
  await getCreateAssociatedTokenIdempotentInstructionAsync({ payer, owner: alice.address, mint: mint.address, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS }),
  await getCreateAssociatedTokenIdempotentInstructionAsync({ payer, owner: bob, mint: mint.address, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS }),
  getMintToCheckedInstruction({ mint: mint.address, token: aliceAta, mintAuthority: payer, amount: 1_000_000n, decimals: 6 }),
]);
check('B6 ATAs + mintTo', r.ok, r.ok ? '' : fmtErr(r));

// Interface-standard InitializeExtraAccountMetaList with the same meta the program writes.
const allowMeta = {
  config: { __kind: 'ProgramPda', seeds: [
    { __kind: 'Literal', bytes: getUtf8Encoder().encode('allow') },
    { __kind: 'AccountKey', index: 1 }, // mint
    { __kind: 'AccountKey', index: 2 }, // destination token account
  ] },
  isSigner: false,
  isWritable: false,
};
r = await send(svm, payer, [await getDefaultInitializeExtraAccountMetaListInstructionAsync({
  mint: mint.address, authority: payer, extraAccountMetas: [allowMeta], transferHookProgram: hookProgram,
})]);
check('B6 getDefaultInitializeExtraAccountMetaListInstructionAsync', r.ok, r.ok ? `CU=${r.cu}` : fmtErr(r));

// Resolution via the LiteSVM-backed rpc
const [validation] = await findExtraAccountMetaListPda({ mint: mint.address }, { programAddress: hookProgram });
const [expectedAllow] = await getProgramDerivedAddress({
  programAddress: hookProgram,
  seeds: ['allow', getAddressEncoder().encode(mint.address), getAddressEncoder().encode(bobAta)],
});
const extra = await resolveExtraAccountMetasForExecute({
  rpc, transferHookProgramAddress: hookProgram, source: aliceAta, mint: mint.address, destination: bobAta, owner: alice.address, amount: 1000n,
});
console.log('  resolved extras:', extra.map((m) => `${m.address}:${AccountRole[m.role]}`).join(' , '));
check('B6 resolveExtraAccountMetasForExecute order = [allow PDA, hook program, validation PDA]',
  extra.length === 3 && extra[0].address === expectedAllow && extra[1].address === hookProgram && extra[2].address === validation);

const hookTransfer = () => getTransferCheckedWithTransferHookInstructionAsync({ rpc }, {
  source: aliceAta, mint: mint.address, destination: bobAta, authority: alice, amount: 1000n, decimals: 6,
});

r = await send(svm, payer, [getTransferCheckedInstruction({ source: aliceAta, mint: mint.address, destination: bobAta, authority: alice, amount: 1000n, decimals: 6 })]);
check('B6 plain transferChecked (no extra accounts) fails', !r.ok, r.ok ? 'succeeded' : fmtErr(r));

const ix = await hookTransfer();
console.log(`  hook transfer ix has ${ix.accounts.length} accounts (4 base + ${ix.accounts.length - 4} extra)`);
r = await send(svm, payer, [ix]);
check('B6 hook transfer to non-allowlisted dest fails with hook DestinationNotAllowed (custom 1)', !r.ok && r.customCode === 1, r.ok ? 'succeeded' : fmtErr(r));

// Program-specific AddToAllowlist: [authority(s,w), mint, allow(w), destination, system]
r = await send(svm, payer, [{
  programAddress: hookProgram,
  accounts: [
    { address: payer.address, role: AccountRole.WRITABLE_SIGNER, signer: payer },
    { address: mint.address, role: AccountRole.READONLY },
    { address: expectedAllow, role: AccountRole.WRITABLE },
    { address: bobAta, role: AccountRole.READONLY },
    { address: SYSTEM_PROGRAM_ADDRESS, role: AccountRole.READONLY },
  ],
  data: Uint8Array.from([240, 1, 2, 3, 4, 5, 6, 7]),
}]);
check('B6 AddToAllowlist(bob ATA)', r.ok, r.ok ? '' : fmtErr(r));

r = await send(svm, payer, [await hookTransfer()]);
check('B6 getTransferCheckedWithTransferHookInstructionAsync transfer succeeds once allowlisted', r.ok, r.ok ? `CU=${r.cu}` : fmtErr(r));
