use crate::framework;
use crate::framework::CallError;
use ic_state_machine_tests::StateMachine;
use ic_types::{CanisterId, PrincipalId};
use internet_identity_interface as types;

pub fn add_entry(
    env: &StateMachine,
    canister_id: CanisterId,
    sender: PrincipalId,
    user_number: types::UserNumber,
) -> Result<(), CallError> {
    framework::call_candid_as(
        env,
        canister_id,
        sender,
        "write_entry",
        (user_number, device_key),
    )
}
