//! APatch root implementation detection and per-app permission lookup,
//! mirroring the C `root_impl/apatch.c` and `root_impl/common.c`.

use std::ffi::{CString, OsStr};
use std::io::{BufRead, BufReader};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use crate::constants::{min_apatch_version, RootImplState};
use crate::loge;
use crate::logi;
use crate::utils::exec_command;

const APD_PATH: &str = "/data/adb/apd";
const PACKAGE_CONFIG_PATH: &str = "/data/adb/ap/package_config";
const APATCH_MANAGER_DIR: &str = "/data/user_de/0/me.bmax.apatch";

/* INFO: Only APatch is supported; the C enum `root_impls { APatch }` makes
         APatch == 0, so the zero-initialised impl always selects APatch. */
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RootImpls {
    APatch,
}

/* INFO: Mirrors `atoi`: parse leading ASCII digits, ignore the rest. */
fn atoi(s: &str) -> i32 {
    let s = s.trim_start();
    let digits: String = s
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse::<i32>().unwrap_or(0)
}

pub fn apatch_get_existence() -> RootImplState {
    if !Path::new(APD_PATH).exists() {
        return RootImplState::Inexistent;
    }

    let c_apd = CString::new(APD_PATH).unwrap();
    let argv = [c"-V".as_ptr(), std::ptr::null()];
    let out = match exec_command(&c_apd, &argv, 32) {
        Some(o) => o,
        None => {
            loge!("Failed to execute apd binary");
            return RootImplState::Inexistent;
        }
    };

    let out_str = String::from_utf8_lossy(&out);
    let version = atoi(out_str.strip_prefix("apd ").unwrap_or(""));

    let min = min_apatch_version();
    if version == 0 {
        RootImplState::Abnormal
    } else if version >= min && version <= 999999 {
        RootImplState::Supported
    } else if version >= 1 && version <= min - 1 {
        RootImplState::TooOld
    } else {
        RootImplState::Abnormal
    }
}

pub fn root_impls_setup() {
    let _ = apatch_get_existence();
    /* INFO: C parity: `enum root_impls { APatch }` makes APatch == 0, and the
             static impl is zero-initialised, so `switch (impl.impl)` always
             logs the found message regardless of the existence state. */
    logi!("APatch root implementation found.");
}

pub fn get_impl() -> RootImpls {
    RootImpls::APatch
}

pub fn stringify_root_impl_name() -> &'static str {
    "APatch"
}

pub fn root_impl_cleanup() {
    /* INFO: APatch has no cleanup needed */
}

#[derive(Debug)]
struct PackageConfig {
    process: Vec<u8>,
    uid: u32,
    root_granted: bool,
    umount_needed: bool,
}

fn get_package_config() -> Option<Vec<PackageConfig>> {
    let file = std::fs::File::open(PACKAGE_CONFIG_PATH).ok()?;
    let mut reader = BufReader::new(file);
    let mut configs = Vec::new();

    let mut header = String::new();
    if reader.read_line(&mut header).unwrap_or(0) == 0 {
        return None;
    }

    loop {
        let mut line = String::new();
        let n = reader.read_line(&mut line).ok()?;
        if n == 0 {
            break;
        }

        /* INFO: Like strtok_r: fields are non-empty comma-separated tokens. */
        let fields: Vec<&str> = line.split(',').filter(|s| !s.is_empty()).collect();
        if fields.len() < 4 {
            continue;
        }

        let process = fields[0].trim().as_bytes().to_vec();
        let uid = atoi(fields[3].trim()) as u32;
        configs.push(PackageConfig {
            process,
            uid,
            root_granted: fields[2].trim() == "1",
            umount_needed: fields[1].trim() == "1",
        });
    }

    Some(configs)
}

pub fn uid_granted_root(uid: u32) -> bool {
    let Some(config) = get_package_config() else {
        return false;
    };
    for c in &config {
        if c.uid == uid {
            return c.root_granted;
        }
    }
    false
}

/* INFO: uid >= 90000 && uid < 1000000 (isolated services) */
fn is_isolated_service(uid: u32) -> bool {
    uid >= 90000 && uid < 1000000
}

pub fn uid_should_umount(uid: u32, process: &[u8]) -> bool {
    let Some(config) = get_package_config() else {
        return false;
    };

    for c in &config {
        if c.uid == uid {
            return c.umount_needed;
        }
    }

    /* INFO: Isolated services have different UIDs than the main app; fall
             back to prefix matching against the saved process names. */
    if is_isolated_service(uid) {
        for c in &config {
            let smallest = process.len().min(c.process.len());
            if c.process[..smallest] != process[..smallest] {
                continue;
            }
            return c.umount_needed;
        }
    }

    false
}

pub fn uid_is_manager(uid: u32) -> bool {
    let path = OsStr::new(APATCH_MANAGER_DIR);
    let cpath = CString::new(path.as_bytes()).unwrap();
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    let ret = unsafe { libc::stat(cpath.as_ptr(), &mut st) };
    if ret == -1 {
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() != Some(libc::ENOENT) {
            loge!(
                "Failed to stat APatch manager data directory: {}",
                err
            );
        }
        return false;
    }
    st.st_uid == uid as libc::uid_t
}
