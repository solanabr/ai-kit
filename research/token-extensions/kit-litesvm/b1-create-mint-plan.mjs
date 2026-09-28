// B1: getCreateMintInstructionPlan with TransferFeeConfig + MetadataPointer + TokenMetadata (+additionalMetadata),
// then the updateAuthority=None gotcha.
import { generateKeyPairSigner, none, some, unwrapOption } from '@solana/kit';
import {
  extension,
  fetchMint,
  getCreateMintInstructionPlan,
  getUpdateTokenMetadataFieldInstruction,
  tokenMetadataField,
} from '@solana-program/token-2022';
import { setup, send, check, fmtErr } from './lib.mjs';

const { svm, rpc, client, payer } = await setup({ token2022So: process.env.T22_SO });

async function createMint(meta) {
  const mint = await generateKeyPairSigner();
  const plan = await getCreateMintInstructionPlan(client, {
    payer,
    newMint: mint,
    decimals: 6,
    mintAuthority: payer,
    extensions: [
      extension('TransferFeeConfig', {
        transferFeeConfigAuthority: payer.address,
        withdrawWithheldAuthority: payer.address,
        withheldAmount: 0n,
        olderTransferFee: { epoch: 0n, maximumFee: 1_000_000n, transferFeeBasisPoints: 50 },
        newerTransferFee: { epoch: 0n, maximumFee: 1_000_000n, transferFeeBasisPoints: 50 },
      }),
      extension('MetadataPointer', { authority: some(payer.address), metadataAddress: some(mint.address) }),
      extension('TokenMetadata', {
        updateAuthority: meta.updateAuthority,
        mint: mint.address,
        name: 'Test Token',
        symbol: 'TST',
        uri: 'https://example.com/t.json',
        additionalMetadata: new Map([['issuer', 'acme']]),
      }),
    ],
  });
  const r = await send(svm, payer, plan);
  return { mint, r };
}

// 1. updateAuthority = Some(payer)
{
  const { mint, r } = await createMint({ updateAuthority: some(payer.address) });
  check('B1 create mint with fee+pointer+metadata', r.ok, r.ok ? `CU=${r.cu}` : fmtErr(r));
  const m = await fetchMint(rpc, mint.address);
  const exts = unwrapOption(m.data.extensions) ?? [];
  console.log('  extensions:', exts.map((e) => e.__kind).join(', '));
  const md = exts.find((e) => e.__kind === 'TokenMetadata');
  check('B1 TokenMetadata present', !!md, md ? `${md.name}/${md.symbol}/${md.uri}` : '');
  const addl = md ? [...md.additionalMetadata.entries()] : [];
  check('B1 additionalMetadata written by plan (expected NOT)', addl.length === 0, `additionalMetadata=${JSON.stringify(addl)}`);
  const acct = svm.getAccount(mint.address);
  console.log(`  account data len=${acct.data.length}, lamports=${acct.lamports}, rent-min for len=${svm.minimumBalanceForRentExemption(BigInt(acct.data.length))}`);

  // Add the extra field with a follow-up instruction.
  const r2 = await send(svm, payer, [
    getUpdateTokenMetadataFieldInstruction({
      metadata: mint.address,
      updateAuthority: payer,
      field: tokenMetadataField('Key', ['issuer']),
      value: 'acme',
    }),
  ]);
  check('B1 updateTokenMetadataField(Key issuer) after create', r2.ok, r2.ok ? `CU=${r2.cu}` : fmtErr(r2));
  const m2 = await fetchMint(rpc, mint.address);
  const md2 = unwrapOption(m2.data.extensions).find((e) => e.__kind === 'TokenMetadata');
  check('B1 additionalMetadata now present', md2.additionalMetadata.get('issuer') === 'acme', JSON.stringify([...md2.additionalMetadata]));
}

// 2. updateAuthority = None -> TokenMetadata silently skipped?
{
  const { mint, r } = await createMint({ updateAuthority: none() });
  check('B1 create mint with updateAuthority=None succeeds', r.ok, r.ok ? '' : fmtErr(r));
  const m = await fetchMint(rpc, mint.address);
  const kinds = (unwrapOption(m.data.extensions) ?? []).map((e) => e.__kind);
  console.log('  extensions:', kinds.join(', '));
  check('B1 gotcha: TokenMetadata silently skipped when updateAuthority=None', !kinds.includes('TokenMetadata'));
}
