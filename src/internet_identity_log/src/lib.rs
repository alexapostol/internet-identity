use candid::{CandidType, Deserialize, Principal};
use ic_cdk::{caller, trap};
use ic_cdk_macros::{query, update};
use internet_identity_interface::*;
use serde_bytes::ByteBuf;
use stable_structures::memory_manager::{ManagedMemory, MemoryId, MemoryManager};
use stable_structures::{
    cell::Cell as StableCell, log::Log, DefaultMemoryImpl, RestrictedMemory, StableBTreeMap,
    Storable, WASM_PAGE_SIZE,
};
use std::borrow::Cow;
use std::cell::RefCell;

type Memory = RestrictedMemory<DefaultMemoryImpl>;
type StableLog = Log<ManagedMemory<Memory>, ManagedMemory<Memory>>;
type ConfigCell = StableCell<LogConfig, Memory>;
type UserIndex = StableBTreeMap<ManagedMemory<Memory>, UserIndexKey, Vec<u8>>;

const GIB: u64 = 1 << 30;
/// The maximum number of Wasm pages that we allow to use for the stable storage.
const MAX_WASM_PAGES: u64 = 4 * GIB / WASM_PAGE_SIZE;

/// The maximum number of entries returned in a single read canister call.
const MAX_ENTRIES_PER_CALL: usize = 1000;

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
    static MEMORY_MANAGER: RefCell<MemoryManager<Memory>> = RefCell::new(MemoryManager::init(log_memory()));

    /// Append-only list of encoded blocks stored in stable memory.
    static LOG: RefCell<StableLog> = with_memory_manager(|memory_manager| {
        RefCell::new(Log::init(memory_manager.get(LOG_INDEX_MEMORY_ID), memory_manager.get(LOG_DATA_MEMORY_ID)).expect("failed to initialize stable log"))
    });

    /// Index to efficiently filter entries by user number.
    static USER_INDEX: RefCell<UserIndex> = with_memory_manager(|memory_manager| {
        RefCell::new(StableBTreeMap::new(memory_manager.get(USER_INDEX_MEMORY_ID), 5, 5))
    });
}

/// Creates a memory region for the configuration stable cell.
fn config_memory() -> Memory {
    RestrictedMemory::new(DefaultMemoryImpl::default(), 0..1)
}

/// Creates a memory region for the append-only block list.
fn log_memory() -> Memory {
    RestrictedMemory::new(DefaultMemoryImpl::default(), 1..MAX_WASM_PAGES)
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

/// A helper function to access the user index.
fn with_user_index<R>(f: impl FnOnce(&mut UserIndex) -> R) -> R {
    USER_INDEX.with(|cell| f(&mut *cell.borrow_mut()))
}

/// Configuration of the II log canister.
#[derive(CandidType, Deserialize)]
struct LogConfig {
    /// This canister will accept entries only from this principal.
    ii_canister: Principal,
}

impl Storable for LogConfig {
    fn to_bytes(&self) -> Cow<[u8]> {
        let buf = candid::encode_one(&self).expect("failed to encode log config");
        Cow::Owned(buf)
    }

    fn from_bytes(bytes: Vec<u8>) -> Self {
        candid::decode_one::<LogConfig>(&bytes).expect("failed to decode log options")
    }
}

impl Default for LogConfig {
    fn default() -> Self {
        Self {
            ii_canister: Principal::from_text("rdmx6-jaaaa-aaaaa-aaadq-cai").unwrap(),
        }
    }
}

/// Configuration of the II log canister.
#[derive(Debug)]
struct UserIndexKey {
    user_number: UserNumber,
    timestamp: Timestamp,
    log_index: u64,
}

impl Storable for UserIndexKey {
    fn to_bytes(&self) -> Cow<[u8]> {
        let mut buf = Vec::with_capacity(10);
        buf.extend(&self.user_number.to_le_bytes());
        buf.extend(&self.timestamp.to_le_bytes());
        buf.extend(&self.log_index.to_le_bytes());
        Cow::Owned(buf)
    }

    fn from_bytes(bytes: Vec<u8>) -> Self {
        UserIndexKey {
            user_number: u64::from_le_bytes(
                TryFrom::try_from(&bytes[0..8]).expect("failed to read user_number"),
            ),
            timestamp: u64::from_le_bytes(
                TryFrom::try_from(&bytes[8..16]).expect("failed to read timestamp"),
            ),
            log_index: u64::from_le_bytes(
                TryFrom::try_from(&bytes[16..]).expect("failed to read log_index"),
            ),
        }
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

    with_user_index(|index| {
        let key = UserIndexKey {
            user_number,
            timestamp,
            log_index: idx as u64,
        };
        index.insert(key, vec![]).expect("failed"); // TODO: handle failure correctly
    })
}

#[query]
fn get_logs(index: Option<u64>) -> Logs {
    let entries = with_log(|log| {
        let start_idx = match index {
            None => log.len().saturating_sub(MAX_ENTRIES_PER_CALL),
            Some(idx) => idx as usize,
        };

        let mut entries = Vec::with_capacity(log.len().min(MAX_ENTRIES_PER_CALL));
        for idx in start_idx..start_idx + MAX_ENTRIES_PER_CALL {
            let entry = match log.get(idx) {
                None => break,
                Some(entry) => entry,
            };
            entries.push(Some(
                candid::decode_one(&entry).expect("failed to decode log entry"),
            ))
        }
        entries
    });
    Logs { entries }
}
