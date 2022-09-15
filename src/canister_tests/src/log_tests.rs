use crate::framework::{principal_1, principal_2, CallError, PUBKEY_2};
use crate::{framework, log_api};
use candid::Principal;
use ic_state_machine_tests::StateMachine;
use internet_identity_interface::{
    DeviceDataWithoutAlias, DeviceProtection, KeyType, LogEntry, LogInit, OperationType, Purpose,
};
use serde_bytes::ByteBuf;

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
fn should_return_previously_written_entry() -> Result<(), CallError> {
    let env = StateMachine::new();

    let canister_id = env
        .install_canister(
            framework::II_LOG_WASM.clone(),
            encoded_log_config(principal_1().0),
            None,
        )
        .unwrap();

    let entry = LogEntry {
        timestamp: 1234,
        user_number: 5678,
        caller: principal_2().0,
        operation: OperationType::RegisterAnchor {
            initial_device: DeviceDataWithoutAlias {
                pubkey: ByteBuf::from(PUBKEY_2),
                credential_id: None,
                purpose: Purpose::Authentication,
                key_type: KeyType::Unknown,
                protection: DeviceProtection::Unprotected,
            },
        },
    };

    log_api::add_entry(
        &env,
        canister_id,
        principal_1(),
        candid::encode_one(entry).expect("failed to encode entry"),
    )?;
    let logs = log_api::get_logs(&env, canister_id, principal_1(), None, None)?;
    assert_eq!(logs.entries.len(), 1);
    Ok(())
}

fn encoded_log_config(ii_canister: Principal) -> Vec<u8> {
    let config = LogInit { ii_canister };
    candid::encode_one(config).expect("error encoding II installation arg as candid")
}
