//! Compile-time constants mirroring the C `constants.h` / build flags.

pub const PROCESS_NAME_MAX_LEN: usize = 257;

pub const PATH_MODULES_DIR: &str = "/data/adb/modules";
/* INFO: Kept for C-parity (TMP_PATH is baked into CONTROLLER_SOCKET /
         CP_SOCKET_PATH below). */
#[allow(dead_code)]
pub const TMP_PATH: &str = "/data/adb/rezygisk";
pub const CONTROLLER_SOCKET: &str = "/data/adb/rezygisk/init_monitor";

/* INFO: LP_SELECT("a", "b") -> "b" on 64-bit, "a" on 32-bit */
#[cfg(target_pointer_width = "64")]
#[allow(dead_code)]
pub const CP_SOCKET_NAME: &str = "cp64.sock";
#[cfg(target_pointer_width = "32")]
#[allow(dead_code)]
pub const CP_SOCKET_NAME: &str = "cp32.sock";
#[cfg(target_pointer_width = "64")]
pub const ZYGISKD_PATH: &str = "/data/adb/modules/rezygisk/bin/zygiskd64";
#[cfg(target_pointer_width = "32")]
pub const ZYGISKD_PATH: &str = "/data/adb/modules/rezygisk/bin/zygiskd32";

/* INFO: PATH_CP_NAME = TMP_PATH "/" LP_SELECT("cp32.sock", "cp64.sock") */
#[cfg(target_pointer_width = "64")]
pub const CP_SOCKET_PATH: &str = "/data/adb/rezygisk/cp64.sock";
#[cfg(target_pointer_width = "32")]
pub const CP_SOCKET_PATH: &str = "/data/adb/rezygisk/cp32.sock";
#[cfg(target_pointer_width = "64")]
pub const BIN_SUFFIX: &str = "64";
#[cfg(target_pointer_width = "32")]
pub const BIN_SUFFIX: &str = "32";

#[cfg(target_arch = "aarch64")]
pub const ARCH_STR: &str = "arm64-v8a";
#[cfg(target_arch = "arm")]
pub const ARCH_STR: &str = "armeabi-v7a";
#[cfg(target_arch = "x86_64")]
pub const ARCH_STR: &str = "x86_64";
#[cfg(target_arch = "x86")]
pub const ARCH_STR: &str = "x86";

/* INFO: Message bytes sent to the controller (init_monitor) socket.
         LP_SELECT(5, 4) -> 4 on 64-bit, 5 on 32-bit. */
#[cfg(target_pointer_width = "64")]
pub const ZYGOTE_INJECTED: u8 = 4;
#[cfg(target_pointer_width = "32")]
pub const ZYGOTE_INJECTED: u8 = 5;
/* INFO: LP_SELECT(7, 6) -> 6 on 64-bit, 7 on 32-bit. */
#[cfg(target_pointer_width = "64")]
pub const DAEMON_SET_INFO: u8 = 6;
#[cfg(target_pointer_width = "32")]
pub const DAEMON_SET_INFO: u8 = 7;

/* INFO: Wire protocol actions between the loader and the daemon socket. */
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DaemonSocketAction {
    ZygoteInjected = 0,
    GetProcessFlags = 1,
    GetInfo = 2,
    ReadModules = 3,
    RequestCompanionSocket = 4,
    GetModuleDir = 5,
    ZygoteRestart = 6,
    UpdateMountNamespace = 7,
    RemoveModule = 8,
}

impl DaemonSocketAction {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::ZygoteInjected,
            1 => Self::GetProcessFlags,
            2 => Self::GetInfo,
            3 => Self::ReadModules,
            4 => Self::RequestCompanionSocket,
            5 => Self::GetModuleDir,
            6 => Self::ZygoteRestart,
            7 => Self::UpdateMountNamespace,
            8 => Self::RemoveModule,
            _ => return None,
        })
    }
}

pub const PROCESS_GRANTED_ROOT: u32 = 1 << 0;
pub const PROCESS_ON_DENYLIST: u32 = 1 << 1;
pub const PROCESS_IS_MANAGER: u32 = 1 << 27;
pub const PROCESS_ROOT_IS_APATCH: u32 = 1 << 28;
pub const PROCESS_IS_FIRST_STARTED: u32 = 1 << 31;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RootImplState {
    Supported,
    TooOld,
    Inexistent,
    Abnormal,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MountNamespaceState {
    Clean = 0,
    Mounted = 1,
}

impl MountNamespaceState {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(Self::Clean),
            1 => Some(Self::Mounted),
            _ => None,
        }
    }
}

/* INFO: sizeof("APatch"); kept for C-parity. */
#[allow(dead_code)]
pub const LONGEST_ROOT_IMPL_NAME: usize = 7;

pub fn min_apatch_version() -> i32 {
    option_env!("MIN_APATCH_VERSION")
        .and_then(|s| s.parse::<i32>().ok())
        .unwrap_or(10655)
}

pub fn zksu_version() -> &'static str {
    option_env!("ZKSU_VERSION").unwrap_or("v1.0.0")
}
