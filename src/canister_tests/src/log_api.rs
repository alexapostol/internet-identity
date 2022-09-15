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
    timestamp: types::Timestamp,
    entry: Vec<u8>,
) -> Result<(), CallError> {
    framework::call_candid_as(
        env,
        canister_id,
        sender,
        "write_entry",
        (user_number, timestamp, entry),
    )
}

pub fn get_logs(
    env: &StateMachine,
    canister_id: CanisterId,
    sender: PrincipalId,
    idx: Option<u64>,
    limit: Option<u16>,
) -> Result<types::Logs, CallError> {
    framework::call_candid_as(env, canister_id, sender, "get_logs", (idx, limit)).map(|(x,)| x)
}
