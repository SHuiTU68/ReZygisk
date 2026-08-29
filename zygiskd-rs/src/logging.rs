//! Logging: mirror of the C `LOGI/LOGW/LOGE` macros, which write to both
//! logcat (via `__android_log_print`) and stdout (via `printf`).

use std::ffi::CString;
use std::os::raw::{c_char, c_int};

pub const ANDROID_LOG_INFO: c_int = 4;
pub const ANDROID_LOG_WARN: c_int = 5;
pub const ANDROID_LOG_ERROR: c_int = 6;

/* INFO: LOG_TAG = "zygiskd" LP_SELECT("32", "64") */
#[cfg(target_pointer_width = "64")]
pub const LOG_TAG: &str = "zygiskd64";
#[cfg(target_pointer_width = "32")]
pub const LOG_TAG: &str = "zygiskd32";

extern "C" {
    fn __android_log_print(prio: c_int, tag: *const c_char, fmt: *const c_char, ...) -> c_int;
}

fn log_impl(prio: c_int, msg: &str) {
    let cmsg = CString::new(msg).unwrap_or_else(|_| CString::new("<invalid utf8>").unwrap());
    let ctag = CString::new(LOG_TAG).unwrap();
    unsafe {
        __android_log_print(prio, ctag.as_ptr(), c"%s".as_ptr(), cmsg.as_ptr());
        let _ = libc::write(
            libc::STDOUT_FILENO,
            msg.as_ptr() as *const libc::c_void,
            msg.len(),
        );
    }
}

#[macro_export]
macro_rules! logi {
    ($($arg:tt)*) => {
        $crate::logging::log($crate::logging::ANDROID_LOG_INFO, &format!($($arg)*))
    };
}

#[macro_export]
macro_rules! logw {
    ($($arg:tt)*) => {
        $crate::logging::log($crate::logging::ANDROID_LOG_WARN, &format!($($arg)*))
    };
}

#[macro_export]
macro_rules! loge {
    ($($arg:tt)*) => {
        $crate::logging::log($crate::logging::ANDROID_LOG_ERROR, &format!($($arg)*))
    };
}

pub fn log(prio: c_int, msg: &str) {
    log_impl(prio, msg);
}
