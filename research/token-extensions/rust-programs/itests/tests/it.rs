use anchor_lang::{
    prelude::Pubkey, solana_program::instruction::Instruction, AccountDeserialize, InstructionData,
    ToAccountMetas,
};
use litesvm::LiteSVM;
use solana_keypair::Keypair;
use solana_signer::Signer;
use solana_transaction::Transaction;
use spl_associated_token_account_interface::{
    address::get_associated_token_address_with_program_id as ata,
    instruction::create_associated_token_account,
};
use t22v3::{
    extension::{
        pausable::PausableConfig, BaseStateWithExtensions, ExtensionType, StateWithExtensions,
    },
    instruction as t22ix,
    state::Mint,
};

const T22: Pubkey = t22v3::ID;
const PINO: Pubkey = anchor_lang::pubkey!("sA5q8yjqxwhBsvZ6AWkWMbfWxEgrSRuJhd7g32ECkV5");
const DEPLOY: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../target/deploy/");

fn svm() -> (LiteSVM, Keypair) {
    let mut svm = LiteSVM::new();
    for (id, name) in [
        (vault::ID, "vault.so"),
        (hook::ID, "hook.so"),
        (pburn::ID, "pburn.so"),
        (onchain_xfer::ID, "onchain_xfer.so"),
        (PINO, "pino_hook.so"),
    ] {
        svm.add_program_from_file(id, format!("{DEPLOY}{name}"))
            .unwrap();
    }
    let payer = Keypair::new();
    svm.airdrop(&payer.pubkey(), 100_000_000_000).unwrap();
    (svm, payer)
}

fn send(
    svm: &mut LiteSVM,
    payer: &Keypair,
    ixs: &[Instruction],
    extra: &[&Keypair],
) -> Result<(), String> {
    let mut signers: Vec<&Keypair> = vec![payer];
    signers.extend_from_slice(extra);
    let tx = Transaction::new_signed_with_payer(
        ixs,
        Some(&payer.pubkey()),
        &signers,
        svm.latest_blockhash(),
    );
    svm.send_transaction(tx)
        .map(|_| ())
        .map_err(|e| format!("{:?} logs={:#?}", e.err, e.meta.logs))
}

/// create_account + extension inits (pre-InitializeMint) + InitializeMint2
fn create_mint(
    svm: &mut LiteSVM,
    payer: &Keypair,
    exts: &[ExtensionType],
    pre: Vec<Instruction>,
) -> Keypair {
    let mint = Keypair::new();
    let len = ExtensionType::try_calculate_account_len::<Mint>(exts).unwrap();
    let mut ixs = vec![solana_system_interface::instruction::create_account(
        &payer.pubkey(),
        &mint.pubkey(),
        svm.minimum_balance_for_rent_exemption(len),
        len as u64,
        &T22,
    )];
    ixs.extend(pre);
    ixs.push(t22ix::initialize_mint2(&T22, &mint.pubkey(), &payer.pubkey(), None, 6).unwrap());
    // pre-ixs were built before we knew the key: rewrite placeholder
    for ix in ixs.iter_mut() {
        for m in ix.accounts.iter_mut() {
            if m.pubkey == Pubkey::default() {
                m.pubkey = mint.pubkey();
            }
        }
    }
    send(svm, payer, &ixs, &[&mint]).unwrap();
    mint
}

fn fund(svm: &mut LiteSVM, payer: &Keypair, mint: &Pubkey, owner: &Pubkey, amount: u64) -> Pubkey {
    let a = ata(owner, mint, &T22);
    send(
        svm,
        payer,
        &[
            create_associated_token_account(&payer.pubkey(), owner, mint, &T22),
            t22ix::mint_to_checked(&T22, mint, &a, &payer.pubkey(), &[], amount, 6).unwrap(),
        ],
        &[],
    )
    .unwrap();
    a
}

fn deposit_ix(user: &Pubkey, mint: &Pubkey, amount: u64) -> Instruction {
    let (vault_authority, _) = Pubkey::find_program_address(&[b"vault", mint.as_ref()], &vault::ID);
    let (position, _) =
        Pubkey::find_program_address(&[b"pos", mint.as_ref(), user.as_ref()], &vault::ID);
    Instruction {
        program_id: vault::ID,
        accounts: vault::accounts::Deposit {
            user: *user,
            mint: *mint,
            user_ata: ata(user, mint, &T22),
            vault_authority,
            vault_ata: ata(&vault_authority, mint, &T22),
            position,
            token_program: T22,
            associated_token_program: spl_associated_token_account_interface::program::ID,
            system_program: anchor_lang::system_program::ID,
        }
        .to_account_metas(None),
        data: vault::instruction::Deposit { amount }.data(),
    }
}

#[test]
fn vault_credits_post_fee_delta() {
    let (mut svm, payer) = svm();
    let fee_ix = t22v3::extension::transfer_fee::instruction::initialize_transfer_fee_config(
        &T22,
        &Pubkey::default(),
        None,
        None,
        100,
        1_000_000,
    )
    .unwrap();
    let mint = create_mint(
        &mut svm,
        &payer,
        &[ExtensionType::TransferFeeConfig],
        vec![fee_ix],
    );
    fund(&mut svm, &payer, &mint.pubkey(), &payer.pubkey(), 1_000_000);
    send(
        &mut svm,
        &payer,
        &[deposit_ix(&payer.pubkey(), &mint.pubkey(), 100_000)],
        &[],
    )
    .unwrap();
    let (position, _) = Pubkey::find_program_address(
        &[b"pos", mint.pubkey().as_ref(), payer.pubkey().as_ref()],
        &vault::ID,
    );
    let acc = svm.get_account(&position).unwrap();
    let pos = vault::Position::try_deserialize(&mut &acc.data[..]).unwrap();
    assert_eq!(pos.amount, 99_000, "1% fee withheld on destination");
}

#[test]
fn vault_rejects_paused_mint() {
    let (mut svm, payer) = svm();
    let init = t22v3::extension::pausable::instruction::initialize(
        &T22,
        &Pubkey::default(),
        &payer.pubkey(),
    )
    .unwrap();
    let mint = create_mint(&mut svm, &payer, &[ExtensionType::Pausable], vec![init]);
    fund(&mut svm, &payer, &mint.pubkey(), &payer.pubkey(), 1_000);
    send(
        &mut svm,
        &payer,
        &[t22v3::extension::pausable::instruction::pause(
            &T22,
            &mint.pubkey(),
            &payer.pubkey(),
            &[],
        )
        .unwrap()],
        &[],
    )
    .unwrap();
    let err = send(
        &mut svm,
        &payer,
        &[deposit_ix(&payer.pubkey(), &mint.pubkey(), 10)],
        &[],
    )
    .unwrap_err();
    assert!(err.contains("Custom(6002)"), "{err}");
}

#[test]
fn vault_create_mint_with_extension_constraints() {
    let (mut svm, payer) = svm();
    let mint = Keypair::new();
    let ix = Instruction {
        program_id: vault::ID,
        accounts: vault::accounts::CreateMint {
            payer: payer.pubkey(),
            authority: payer.pubkey(),
            mint: mint.pubkey(),
            token_program: T22,
            system_program: anchor_lang::system_program::ID,
        }
        .to_account_metas(None),
        data: vault::instruction::CreateMint {}.data(),
    };
    send(&mut svm, &payer, &[ix], &[&mint]).unwrap();
    let acc = svm.get_account(&mint.pubkey()).unwrap();
    let st = StateWithExtensions::<Mint>::unpack(&acc.data).unwrap();
    println!("extensions: {:?}", st.get_extension_types().unwrap());
    assert_eq!(
        st.get_extension::<PausableConfig>()
            .unwrap()
            .authority
            .get(),
        Some(payer.pubkey())
    );
    // Hook points at vault::ID, so the vault's own deposit rejects it (6001).
    fund(&mut svm, &payer, &mint.pubkey(), &payer.pubkey(), 1_000);
    let err = send(
        &mut svm,
        &payer,
        &[deposit_ix(&payer.pubkey(), &mint.pubkey(), 10)],
        &[],
    )
    .unwrap_err();
    assert!(err.contains("Custom(6001)"), "{err}");
}

fn hook_setup(svm: &mut LiteSVM, payer: &Keypair) -> (Pubkey, Pubkey, Pubkey, Pubkey, Pubkey) {
    let init = t22v3::extension::transfer_hook::instruction::initialize(
        &T22,
        &Pubkey::default(),
        Some(payer.pubkey()),
        Some(hook::ID),
    )
    .unwrap();
    let mint = create_mint(svm, payer, &[ExtensionType::TransferHook], vec![init]).pubkey();
    let (metas, _) =
        Pubkey::find_program_address(&[b"extra-account-metas", mint.as_ref()], &hook::ID);
    let (counter, _) = Pubkey::find_program_address(&[b"counter", mint.as_ref()], &hook::ID);
    assert_eq!(
        metas,
        spl_transfer_hook_interface::get_extra_account_metas_address(&mint, &hook::ID)
    );
    send(
        svm,
        payer,
        &[
            Instruction {
                program_id: hook::ID,
                accounts: hook::accounts::InitCounter {
                    counter,
                    mint,
                    payer: payer.pubkey(),
                    system_program: anchor_lang::system_program::ID,
                }
                .to_account_metas(None),
                data: hook::instruction::InitCounter {}.data(),
            },
            Instruction {
                program_id: hook::ID,
                accounts: hook::accounts::InitializeExtraAccountMetaList {
                    extra_account_meta_list: metas,
                    mint,
                    payer: payer.pubkey(),
                    system_program: anchor_lang::system_program::ID,
                }
                .to_account_metas(None),
                data: hook::instruction::InitializeExtraAccountMetaList {}.data(),
            },
        ],
        &[],
    )
    .unwrap();
    let src = fund(svm, payer, &mint, &payer.pubkey(), 1_000);
    let dest_owner = Pubkey::new_unique();
    let dst = ata(&dest_owner, &mint, &T22);
    send(
        svm,
        payer,
        &[create_associated_token_account(
            &payer.pubkey(),
            &dest_owner,
            &mint,
            &T22,
        )],
        &[],
    )
    .unwrap();
    (mint, metas, counter, src, dst)
}

#[test]
fn hook_counts_transfers_and_rejects_direct_calls() {
    let (mut svm, payer) = svm();
    let (mint, metas, counter, src, dst) = hook_setup(&mut svm, &payer);
    let mut ix =
        t22ix::transfer_checked(&T22, &src, &mint, &dst, &payer.pubkey(), &[], 10, 6).unwrap();
    ix.accounts
        .push(anchor_lang::solana_program::instruction::AccountMeta::new(
            counter, false,
        ));
    ix.accounts
        .push(anchor_lang::solana_program::instruction::AccountMeta::new_readonly(hook::ID, false));
    ix.accounts
        .push(anchor_lang::solana_program::instruction::AccountMeta::new_readonly(metas, false));
    send(&mut svm, &payer, &[ix], &[]).unwrap();
    let c =
        hook::Counter::try_deserialize(&mut &svm.get_account(&counter).unwrap().data[..]).unwrap();
    assert_eq!((c.transfers, c.volume), (1, 10));

    // Direct Execute outside a transfer -> NotTransferring (6000)
    let direct = Instruction {
        program_id: hook::ID,
        accounts: hook::accounts::Execute {
            source: src,
            mint,
            destination: dst,
            owner: payer.pubkey(),
            extra_account_meta_list: metas,
            counter,
        }
        .to_account_metas(None),
        data: hook::instruction::Execute { amount: 1 }.data(),
    };
    let err = send(&mut svm, &payer, &[direct], &[]).unwrap_err();
    assert!(err.contains("Custom(6000)"), "{err}");
}

#[test]
fn pburn_transfer_hooked_forwards_extra_accounts() {
    let (mut svm, payer) = svm();
    let (mint, metas, counter, src, dst) = hook_setup(&mut svm, &payer);
    let mut accounts = pburn::accounts::TransferHooked {
        authority: payer.pubkey(),
        mint,
        from: src,
        to: dst,
        token_program: T22,
    }
    .to_account_metas(None);
    accounts
        .push(anchor_lang::solana_program::instruction::AccountMeta::new_readonly(hook::ID, false));
    accounts
        .push(anchor_lang::solana_program::instruction::AccountMeta::new_readonly(metas, false));
    accounts.push(anchor_lang::solana_program::instruction::AccountMeta::new(
        counter, false,
    ));
    let ix = Instruction {
        program_id: pburn::ID,
        accounts,
        data: pburn::instruction::TransferHooked { amount: 7 }.data(),
    };
    send(&mut svm, &payer, &[ix], &[]).unwrap();
    let c =
        hook::Counter::try_deserialize(&mut &svm.get_account(&counter).unwrap().data[..]).unwrap();
    assert_eq!((c.transfers, c.volume), (1, 7));
}

#[test]
fn permissioned_burn_cpi() {
    let (mut svm, payer) = svm();
    let burn_auth = Keypair::new();
    let init = t22v3::extension::permissioned_burn::instruction::initialize(
        &T22,
        &Pubkey::default(),
        &burn_auth.pubkey(),
    )
    .unwrap();
    let mint = create_mint(
        &mut svm,
        &payer,
        &[ExtensionType::PermissionedBurn],
        vec![init],
    )
    .pubkey();
    let acct = fund(&mut svm, &payer, &mint, &payer.pubkey(), 1_000);

    // Plain BurnChecked is refused by Token-2022 on a PermissionedBurn mint.
    let plain = t22ix::burn_checked(&T22, &acct, &mint, &payer.pubkey(), &[], 1, 6).unwrap();
    let err = send(&mut svm, &payer, &[plain], &[]).unwrap_err();
    println!(
        "plain burn_checked on PermissionedBurn mint: {}",
        err.lines().next().unwrap()
    );

    let ix = Instruction {
        program_id: pburn::ID,
        accounts: pburn::accounts::PermissionedBurn {
            owner: payer.pubkey(),
            burn_authority: burn_auth.pubkey(),
            mint,
            token_account: acct,
            token_program: T22,
        }
        .to_account_metas(None),
        data: pburn::instruction::PermissionedBurn { amount: 100 }.data(),
    };
    send(&mut svm, &payer, &[ix], &[&burn_auth]).unwrap();
    let st = StateWithExtensions::<Mint>::unpack(&svm.get_account(&mint).unwrap().data)
        .unwrap()
        .base;
    assert_eq!(st.supply, 900);
}

#[test]
fn program_crate_invoke_transfer_checked() {
    use anchor_lang::solana_program::instruction::AccountMeta;
    let (mut svm, payer) = svm();
    let (mint, metas, counter, src, dst) = hook_setup(&mut svm, &payer);
    let mut accounts = onchain_xfer::accounts::Xfer { authority: payer.pubkey(), mint, from: src, to: dst, token_program: T22 }.to_account_metas(None);
    accounts.extend([
        AccountMeta::new_readonly(hook::ID, false),
        AccountMeta::new_readonly(metas, false),
        AccountMeta::new(counter, false),
    ]);
    let ix = Instruction { program_id: onchain_xfer::ID, accounts, data: onchain_xfer::instruction::Xfer { amount: 5 }.data() };
    send(&mut svm, &payer, &[ix], &[]).unwrap();
    let c = hook::Counter::try_deserialize(&mut &svm.get_account(&counter).unwrap().data[..]).unwrap();
    assert_eq!((c.transfers, c.volume), (1, 5));
}

#[test]
fn pinocchio_deposit_and_hook() {
    use anchor_lang::solana_program::instruction::AccountMeta;
    let (mut svm, payer) = svm();
    // 1. deposit via pinocchio-token-2022 TransferChecked on a plain T22 mint
    let mint = create_mint(&mut svm, &payer, &[], vec![]).pubkey();
    let src = fund(&mut svm, &payer, &mint, &payer.pubkey(), 1_000);
    let other = Pubkey::new_unique();
    let dst = ata(&other, &mint, &T22);
    send(&mut svm, &payer, &[create_associated_token_account(&payer.pubkey(), &other, &mint, &T22)], &[]).unwrap();
    let mut data = vec![0u8];
    data.extend(40u64.to_le_bytes());
    let ix = Instruction {
        program_id: PINO,
        accounts: vec![
            AccountMeta::new(src, false), AccountMeta::new_readonly(mint, false), AccountMeta::new(dst, false),
            AccountMeta::new_readonly(payer.pubkey(), true), AccountMeta::new_readonly(T22, false),
        ],
        data,
    };
    send(&mut svm, &payer, &[ix], &[]).unwrap();

    // 2. pinocchio program as the mint's transfer hook (no extra-account-metas account created)
    let init = t22v3::extension::transfer_hook::instruction::initialize(&T22, &Pubkey::default(), None, Some(PINO)).unwrap();
    let hmint = create_mint(&mut svm, &payer, &[ExtensionType::TransferHook], vec![init]).pubkey();
    let hsrc = fund(&mut svm, &payer, &hmint, &payer.pubkey(), 1_000);
    let hdst = ata(&other, &hmint, &T22);
    send(&mut svm, &payer, &[create_associated_token_account(&payer.pubkey(), &other, &hmint, &T22)], &[]).unwrap();
    let (metas, _) = Pubkey::find_program_address(&[b"extra-account-metas", hmint.as_ref()], &PINO);
    let mut ix = t22ix::transfer_checked(&T22, &hsrc, &hmint, &hdst, &payer.pubkey(), &[], 10, 6).unwrap();
    ix.accounts.push(AccountMeta::new_readonly(PINO, false));
    let mut with_metas = ix.clone();
    with_metas.accounts.push(AccountMeta::new_readonly(metas, false));
    // Passing an uninitialized extra-account-metas PDA makes Token-2022 fail to parse it.
    let r = send(&mut svm, &payer, &[with_metas], &[]);
    println!("with uninitialized metas PDA: {:?}", r.as_ref().map_err(|e| e.lines().next().unwrap().to_string()));
    assert!(r.is_err());
    // A hook with no extra accounts: pass only the hook program id.
    send(&mut svm, &payer, &[ix], &[]).unwrap();
}
