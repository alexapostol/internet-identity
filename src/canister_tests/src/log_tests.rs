use crate::framework;
use crate::framework::principal_1;
use ic_state_machine_tests::StateMachine;
use internet_identity_interface::LogInit;

#[test]
fn ii_canister_can_be_installed() {
    let env = StateMachine::new();

    let config = LogInit {
        ii_canister: principal_1().0,
    };
    let arg = candid::encode_one(config).expect("error encoding II installation arg as candid");
    let canister_id = env
        .install_canister(framework::II_LOG_WASM.clone(), arg, None)
        .unwrap();
}
