use crate::framework::{principal_1, CallError, PUBKEY_1};
use crate::{framework, log_api};
use candid::Principal;
use ic_state_machine_tests::StateMachine;
use internet_identity_interface::{
    DeviceDataWithoutAlias, DeviceProtection, KeyType, LogEntry, LogInit, OperationType, Purpose,
    UserNumber,
};
use serde_bytes::ByteBuf;

const USER_NUMBER_1: UserNumber = 100001;
//const USER_NUMBER_2: UserNumber = 100002;

const TIMESTAMP_1: UserNumber = 999991;
//const TIMESTAMP_2: UserNumber = 999992;

#[test]
fn should_install() -> Result<(), CallError> {
    let env = StateMachine::new();

    let canister_id = env
        .install_canister(
            framework::II_LOG_WASM.clone(),
            encoded_log_config(principal_1().0),
            None,
        )
        .unwrap();

    let logs = log_api::get_logs(&env, canister_id, principal_1(), None, None)?;
    assert_eq!(logs.entries.len(), 0);
    Ok(())
}

#[test]
fn should_write_entry() -> Result<(), CallError> {
    let env = StateMachine::new();

    let canister_id = env
        .install_canister(
            framework::II_LOG_WASM.clone(),
            encoded_log_config(principal_1().0),
            None,
        )
        .unwrap();

    log_api::add_entry(
        &env,
        canister_id,
        principal_1(),
        USER_NUMBER_1,
        TIMESTAMP_1,
        candid::encode_one(log_entry_1()).expect("failed to encode entry"),
    )?;
    Ok(())
}

#[test]
fn should_return_previously_written_entry() -> Result<(), CallError> {
    let env = StateMachine::new();

    let canister_id = env
        .install_canister(
            framework::II_LOG_WASM.clone(),
            encoded_log_config(principal_1().0),
            None,
        )
        .unwrap();

    log_api::add_entry(
        &env,
        canister_id,
        principal_1(),
        USER_NUMBER_1,
        TIMESTAMP_1,
        candid::encode_one(log_entry_1()).expect("failed to encode entry"),
    )?;
    let logs = log_api::get_logs(&env, canister_id, principal_1(), None, None)?;
    assert_eq!(logs.entries.len(), 1);
    Ok(())
}

fn encoded_log_config(authorized_principal: Principal) -> Vec<u8> {
    let config = LogInit {
        ii_canister: authorized_principal,
    };
    candid::encode_one(Some(config)).expect("error encoding II installation arg as candid")
}

fn log_entry_1() -> LogEntry {
    LogEntry {
        timestamp: TIMESTAMP_1,
        user_number: USER_NUMBER_1,
        caller: principal_1().0,
        operation: OperationType::RegisterAnchor {
            initial_device: DeviceDataWithoutAlias {
                pubkey: ByteBuf::from(PUBKEY_1),
                credential_id: None,
                purpose: Purpose::Authentication,
                key_type: KeyType::Unknown,
                protection: DeviceProtection::Unprotected,
            },
        },
    }
}
