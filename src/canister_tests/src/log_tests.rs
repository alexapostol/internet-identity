use crate::framework::{principal_1, CallError};
use crate::{framework, log_api};
use candid::types::Type::Principal;
use ic_state_machine_tests::StateMachine;
use internet_identity_interface::LogInit;
use serde::__private::de::Content::ByteBuf;

#[test]
fn ii_canister_can_be_installed() -> Result<(), CallError> {
    let env = StateMachine::new();

    let config = LogInit {
        ii_canister: principal_1().0,
    };
    let arg = candid::encode_one(config).expect("error encoding II installation arg as candid");
    let canister_id = env
        .install_canister(framework::II_LOG_WASM.clone(), arg, None)
        .unwrap();

    log_api::add_entry(
        &env,
        canister_id,
        principal_1(),
        ByteBuf::from(vec![1, 2, 3, 4]),
    )?;
    log_api::get_logs(&env, canister_id, principal_1(), None, None)?;
}
