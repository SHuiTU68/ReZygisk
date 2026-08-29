//! Companion process, mirroring the C `zygiskd/src/companion.c`.
//!
//! The daemon spawns one companion per module that ships a
//! `zygisk_companion_entry` symbol. The companion process:
//!   1. receives the module name and library fd over the control socket,
//!   2. dlopens the module library and resolves `zygisk_companion_entry`,
//!   3. acknowledges the daemon, then loops relaying client fds to the entry
//!      on detached threads.

use std::ffi::{CStr, CString};
use std::os::raw::c_void;
use std::ptr;

use crate::loge;
use crate::logi;
use crate::utils::{check_unix_socket, strerror};
use crate::wire;

type ZygiskCompanionEntry = unsafe extern "C" fn(i32);

struct CompanionThreadArgs {
    fd: i32,
    entry: ZygiskCompanionEntry,
}

/* INFO: dlerror() returns a static NUL-terminated string; never free it. */
unsafe fn dlerror_string() -> String {
    let err = libc::dlerror();
    if err.is_null() {
        "unknown error".to_string()
    } else {
        CStr::from_ptr(err).to_string_lossy().into_owned()
    }
}

/* INFO: Mirrors C `load_module`: dlopen /proc/self/fd/<fd>, dlsym
         zygisk_companion_entry. Returns the entry pointer or null. */
unsafe fn load_module(fd: i32) -> *mut c_void {
    let path = format!("/proc/self/fd/{fd}");
    let cpath = CString::new(path).unwrap();
    let handle = libc::dlopen(cpath.as_ptr(), libc::RTLD_NOW);
    if handle.is_null() {
        let msg = dlerror_string();
        loge!("Failed to dlopen module: {msg}");
        return ptr::null_mut();
    }

    let symbol = CString::new("zygisk_companion_entry").unwrap();
    let entry = libc::dlsym(handle, symbol.as_ptr());
    if entry.is_null() {
        let msg = dlerror_string();
        loge!("Failed to dlsym zygisk_companion_entry: {msg}");
        libc::dlclose(handle);
        return ptr::null_mut();
    }

    entry
}

/* INFO: Mirrors C `entry_thread`: runs the module entry, then closes the
         client fd only if it is still the same file (avoids double-close if
         the module already closed it). */
extern "C" fn entry_thread(arg: *mut c_void) -> *mut c_void {
    unsafe {
        let args = Box::from_raw(arg as *mut CompanionThreadArgs);
        let fd = args.fd;
        let module_entry = args.entry;

        let mut st0: libc::stat = std::mem::zeroed();
        if libc::fstat(fd, &mut st0) == -1 {
            loge!(" - Failed to get initial client fd stats: {}", strerror());
            return ptr::null_mut();
        }

        module_entry(fd);

        let mut st1: libc::stat = std::mem::zeroed();
        if libc::fstat(fd, &mut st1) != -1 && st0.st_ino == st1.st_ino {
            logi!(" - Client fd changed after module entry");
            libc::close(fd);
        }

        ptr::null_mut()
    }
}

pub fn companion_entry(fd: i32) {
    logi!("New companion entry.\n - Client fd: {fd}\n");

    /* INFO: read_string with a 256-byte name (plus NUL), like the C
             `char name[256 + 1]`. */
    let name = match wire::read_string(fd, 256 + 1) {
        Ok(n) => n,
        Err(_) => {
            loge!("Failed to read module name");
            unsafe { libc::close(fd) };
            loge!("Companion thread exited");
            unsafe { libc::exit(0) };
        }
    };

    logi!(" - Module name: \"{name}\"");

    let library_fd = wire::read_fd(fd);
    if library_fd == -1 {
        loge!("Failed to receive library fd");
        unsafe { libc::close(fd) };
        loge!("Companion thread exited");
        unsafe { libc::exit(0) };
    }

    logi!(" - Library fd: {library_fd}");

    let entry = unsafe { load_module(library_fd) };
    unsafe { libc::close(library_fd) };

    let Some(module_entry) = (if entry.is_null() {
        loge!(" - No companion module entry for module: {name}");
        let ret = wire::write_u8(fd, 0);
        if ret != 1 {
            loge!("Failed to send module_entry in ZygiskdCompanion: Expected 1, got {ret}");
        }
        None
    } else {
        logi!(" - Module entry found");
        let ret = wire::write_u8(fd, 1);
        if ret != 1 {
            loge!("Failed to send module_entry in ZygiskdCompanion: Expected 1, got {ret}");
        }
        Some(unsafe {
            std::mem::transmute::<*mut c_void, ZygiskCompanionEntry>(entry)
        })
    }) else {
        unsafe { libc::close(fd) };
        loge!("Companion thread exited");
        unsafe { libc::exit(0) };
    };

    let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
    sa.sa_sigaction = libc::SIG_IGN as usize;
    unsafe {
        libc::sigaction(libc::SIGPIPE, &sa, ptr::null_mut());
    }

    loop {
        if !check_unix_socket(fd, true) {
            loge!("Something went wrong in companion. Bye!");
            break;
        }

        let client_fd = wire::read_fd(fd);
        if client_fd == -1 {
            loge!("Failed to receive client fd");
            break;
        }

        logi!("New companion request.\n - Module name: {name}\n - Client fd: {client_fd}\n");

        let ret = wire::write_u8(client_fd, 1);
        if ret != 1 {
            loge!("Failed to send client_fd in ZygiskdCompanion: Expected 1, got {ret}");
            unsafe { libc::close(client_fd) };
            break;
        }

        let args = Box::new(CompanionThreadArgs {
            fd: client_fd,
            entry: module_entry,
        });

        let mut thread: libc::pthread_t = 0;
        let raw = Box::into_raw(args) as *mut c_void;
        if unsafe { libc::pthread_create(&mut thread, ptr::null(), entry_thread, raw) } != 0 {
            loge!(" - Failed to create thread for companion module");
            unsafe { libc::close(client_fd) };
            let _ = unsafe { Box::from_raw(raw as *mut CompanionThreadArgs) };
            break;
        }

        unsafe { libc::pthread_detach(thread) };
    }

    unsafe { libc::close(fd) };
    loge!("Companion thread exited");
    unsafe { libc::exit(0) };
}
