// Part A probe against a local solana-test-validator (Agave 3.1.14): ZK gates, ZK proof verify, bundled token-2022 ELF.
import crypto from 'node:crypto';
import fs from 'node:fs';
import {
  address, airdropFactory, appendTransactionMessageInstructions, createSolanaRpc, createSolanaRpcSubscriptions,
  createTransactionMessage, generateKeyPairSigner, getAddressDecoder, getBase64Encoder, getSignatureFromTransaction, lamports, pipe,
  sendAndConfirmTransactionFactory, setTransactionMessageFeePayerSigner, setTransactionMessageLifetimeUsingBlockhash,
  signTransactionMessageWithSigners,
} from '@solana/kit';
import { ElGamalKeypair, PubkeyValidityProofData } from '@solana/zk-sdk';
import { verifyPubkeyValidity } from '@solana-program/zk-elgamal-proof';

const url = process.env.RPC ?? 'http://127.0.0.1:18899';
const rpc = createSolanaRpc(url);
const rpcSubscriptions = createSolanaRpcSubscriptions(url.replace('http', 'ws').replace('18899', '18900'));

for (const [name, id] of [['zk_elgamal_proof_program_enabled', 'zkhiy5oLowR7HY4zogXjCjeMXyruLqBwSWH21qcFtnv'], ['disable_zk_elgamal_proof_program', 'zkdoVwnSFnSLtGJG7irJPEYUpmb4i7sGMGcnN6T9rnC'], ['reenable_zk_elgamal_proof_program (Agave >=4.0 id)', 'zkexuyPRdyTVbZqEAREueqL2xvvoBhRgth9xGSc1tMN'], ['reenable_zk_elgamal_proof_program (Agave 3.1.x id)', 'zkesAyFB19sTkX8i9ReoKaMNDA4YNTPYJpZKPDt7FMW']]) {
  const { value } = await rpc.getAccountInfo(address(id), { encoding: 'base64' }).send();
  console.log(`  feature ${name}: ${value ? 'ACTIVE (account exists)' : 'inactive'}`);
}

const payer = await generateKeyPairSigner();
await airdropFactory({ rpc, rpcSubscriptions })({ recipientAddress: payer.address, lamports: lamports(2_000_000_000n), commitment: 'confirmed' });
const ixs = await verifyPubkeyValidity({ rpc, payer, proofData: new PubkeyValidityProofData(new ElGamalKeypair()).toBytes() });
const { value: bh } = await rpc.getLatestBlockhash().send();
const tx = await signTransactionMessageWithSigners(pipe(createTransactionMessage({ version: 0 }), (m) => setTransactionMessageFeePayerSigner(payer, m), (m) => setTransactionMessageLifetimeUsingBlockhash(bh, m), (m) => appendTransactionMessageInstructions(ixs, m)));
try {
  await sendAndConfirmTransactionFactory({ rpc, rpcSubscriptions })(tx, { commitment: 'confirmed' });
  console.log('PASS ZK PubkeyValidity proof verified on solana-test-validator', getSignatureFromTransaction(tx));
} catch (e) {
  console.log('FAIL ZK proof on test-validator:', e.message, JSON.stringify(e.context ?? {}, (_, v) => (typeof v === 'bigint' ? v.toString() : v)).slice(0, 600));
}

// Which token-2022 ELF does the validator ship?
const { value: prog } = await rpc.getAccountInfo(address('TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb'), { encoding: 'base64' }).send();
console.log('  token-2022 owner:', prog.owner);
const progBytes = new Uint8Array(getBase64Encoder().encode(prog.data[0]));
const pdAddr = getAddressDecoder().decode(progBytes.slice(4, 36));
const { value: pd } = await rpc.getAccountInfo(pdAddr, { encoding: 'base64' }).send();
const elf = new Uint8Array(getBase64Encoder().encode(pd.data[0])).slice(45);
let end = elf.length; while (end > 0 && elf[end - 1] === 0) end--;
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const known = {
  'litesvm 0.17 spl_token_2022-11.0.0.so': './litesvm-src/crates/litesvm/src/programs/elf/spl_token_2022-11.0.0.so',
  'mollusk 0.15.1 token_2022.so (slot 347196212)': './mollusk-src/programs/token-2022/src/elf/token_2022.so',
};
console.log(`  validator token-2022 ELF: ${end} bytes sha256=${sha(elf.slice(0, end))}`);
for (const [k, p] of Object.entries(known)) {
  const b = fs.readFileSync(p);
  console.log(`  ${k}: ${b.length} bytes sha256=${sha(b)} ${sha(b) === sha(elf.slice(0, b.length)) && b.length <= end ? 'MATCH' : ''}`);
}
process.exit(0);
