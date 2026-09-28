// B1b: getCreateMintInstructionPlan with TokenGroup (group mint) and TokenGroupMember (member mint).
// Code reading says TokenGroupMember is dropped from the plan (listed as post-init, no case emits it).
import { generateKeyPairSigner, some, unwrapOption } from '@solana/kit';
import { extension, fetchMint, getCreateMintInstructionPlan, getInitializeTokenGroupMemberInstruction } from '@solana-program/token-2022';
import { setup, send, check, fmtErr } from './lib.mjs';

const { svm, rpc, client, payer } = await setup({ token2022So: process.env.T22_SO });
const group = await generateKeyPairSigner();
const member = await generateKeyPairSigner();
const kinds = async (m) => (unwrapOption((await fetchMint(rpc, m)).data.extensions) ?? []).map((e) => e.__kind);

let r = await send(svm, payer, await getCreateMintInstructionPlan(client, {
  payer, newMint: group, decimals: 0, mintAuthority: payer,
  extensions: [
    extension('GroupPointer', { authority: some(payer.address), groupAddress: some(group.address) }),
    extension('TokenGroup', { updateAuthority: some(payer.address), mint: group.address, size: 0n, maxSize: 10n }),
  ],
}));
check('B1b group mint (GroupPointer + TokenGroup)', r.ok && (await kinds(group.address)).includes('TokenGroup'), r.ok ? (await kinds(group.address)).join(',') : fmtErr(r));

r = await send(svm, payer, await getCreateMintInstructionPlan(client, {
  payer, newMint: member, decimals: 0, mintAuthority: payer,
  extensions: [
    extension('GroupMemberPointer', { authority: some(payer.address), memberAddress: some(member.address) }),
    extension('TokenGroupMember', { mint: member.address, group: group.address, memberNumber: 1n }),
  ],
}));
const mk = r.ok ? await kinds(member.address) : [];
check('B1b gotcha: TokenGroupMember silently not initialized by the plan', r.ok && !mk.includes('TokenGroupMember'), r.ok ? mk.join(',') : fmtErr(r));

r = await send(svm, payer, [getInitializeTokenGroupMemberInstruction({
  member: member.address, memberMint: member.address, memberMintAuthority: payer, group: group.address, groupUpdateAuthority: payer,
})]);
const mk2 = r.ok ? await kinds(member.address) : [];
check('B1b explicit initializeTokenGroupMember afterwards works (plan pre-funded the rent)', r.ok && mk2.includes('TokenGroupMember'), r.ok ? mk2.join(',') : fmtErr(r));
