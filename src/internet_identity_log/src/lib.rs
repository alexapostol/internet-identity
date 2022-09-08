use candid::Principal;
use ic_cdk::{api, caller, trap};
use ic_cdk_macros::query;
use internet_identity_interface::*;
use serde_bytes::ByteBuf;
use stable_structures::memory_manager::{ManagedMemory, MemoryId, MemoryManager};
use stable_structures::{
    cell::Cell as StableCell, log::Log, DefaultMemoryImpl, RestrictedMemory, StableBTreeMap,
    Storable, WASM_PAGE_SIZE,
};
use std::borrow::{Borrow, Cow};
use std::cell::RefCell;
use std::collections::BTreeMap;

type Memory = RestrictedMemory<DefaultMemoryImpl>;
type StableLog = Log<ManagedMemory<Memory>, ManagedMemory<Memory>>;
type ConfigCell = StableCell<LogConfig, Memory>;

const GIB: u64 = 1 << 30;
/// The maximum number of Wasm pages that we allow to use for the stable storage.
const NUM_WASM_PAGES: u64 = 4 * GIB / WASM_PAGE_SIZE;

const LOG_INDEX_MEMORY_ID: MemoryId = MemoryId::new(0);
const LOG_DATA_MEMORY_ID: MemoryId = MemoryId::new(1);
const USER_INDEX_MEMORY_ID: MemoryId = MemoryId::new(2);

thread_local! {
    /// Static configuration of the archive that init() sets once.
    static CONFIG: RefCell<ConfigCell> = RefCell::new(ConfigCell::init(
        config_memory(),
        LogConfig::default(),
    ).expect("failed to initialize stable cell"));

    /// Static memory manager to manage the memory available for blocks.
    static MEMORY_MANAGER: RefCell<MemoryManager<Memory>> = RefCell::new(MemoryManager::init(blocks_memory()));

    /// Append-only list of encoded blocks stored in stable memory.
    static LOG: RefCell<StableLog> = with_memory_manager(|memory_manager| {
        RefCell::new(Log::init(memory_manager.get(LOG_INDEX_MEMORY_ID), memory_manager.get(LOG_DATA_MEMORY_ID)).expect("failed to initialize stable log"))
    });

    /// Index to efficiently filter entries by user number.
    static USER_INDEX: RefCell<StableBTreeMap<ManagedMemory<Memory>, UserIndexKey, () >> = with_memory_manager(|memory_manager| {
        RefCell::new(StableBTreeMap::new(memory_manager.get(USER_INDEX_MEMORY_ID), 5, 5))
    });
}

/// Creates a memory region for the configuration stable cell.
fn config_memory() -> Memory {
    RestrictedMemory::new(DefaultMemoryImpl::default(), 0..1)
}

/// Creates a memory region for the append-only block list.
fn blocks_memory() -> Memory {
    RestrictedMemory::new(DefaultMemoryImpl::default(), 1..NUM_WASM_PAGES)
}

/// A helper function to access the configuration.
fn with_config<R>(f: impl FnOnce(&LogConfig) -> R) -> R {
    CONFIG.with(|cell| f(cell.borrow().get()))
}

/// A helper function to access the memory manager.
fn with_memory_manager<R>(f: impl FnOnce(&MemoryManager<Memory>) -> R) -> R {
    MEMORY_MANAGER.with(|cell| f(&*cell.borrow()))
}

/// A helper function to access the log.
fn with_log<R>(f: impl FnOnce(&StableLog) -> R) -> R {
    LOG.with(|cell| f(&*cell.borrow()))
}

/// Configuration of the II log canister.
#[derive(Serialize, Deserialize)]
struct LogConfig {
    /// This canister will accept entries only from this principal.
    ii_canister: Principal,
}

impl Default for LogConfig {
    fn default() -> Self {
        Self {
            ii_canister: Principal::from_text("rdmx6-jaaaa-aaaaa-aaadq-cai").unwrap(),
        }
    }
}

/// Configuration of the II log canister.
#[derive(Serialize, Deserialize)]
struct UserIndexKey {
    user_number: UserNumber,
    timestamp: Timestamp,
    log_index: u64,
}

impl Storable for UserIndexKey {
    fn to_bytes(&self) -> Cow<[u8]> {
        let mut buf = vec![];
        ciborium::ser::into_writer(self, &mut buf).expect("failed to encode log config");
        Cow::Owned(buf)
    }

    fn from_bytes(bytes: Vec<u8>) -> Self {
        ciborium::de::from_reader(&bytes[..]).expect("failed to decode log options")
    }
}

#[update]
fn write_entry(user_number: UserNumber, timestamp: Timestamp, entry: ByteBuf) {
    with_config(|config| {
        if config.ii_canister != caller() {
            trap(&format!(
                "Only {} is allowed to write entries.",
                config.ii_canister
            ))
        }
    });
    let idx = with_log(|log| {
        log.append(entry.as_ref()).expect("failed") // TODO: handle failure correctly
    });
}
