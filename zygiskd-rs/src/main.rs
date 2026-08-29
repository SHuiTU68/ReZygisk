//! ReZygisk daemon entry point, mirroring the C `zygiskd/src/main.c` and the
//! request loop in `zygiskd/src/zygiskd.c`.

mod companion;
mod constants;
mod logging;
mod modules;
mod root_impl;
mod utils;
mod wire;

use std::ffi::CString;
use std::os::raw::c_char;
use std::ptr;

use constants::{
    BIN_SUFFIX, CONTROLLER_SOCKET, CP_SOCKET_PATH, DaemonSocketAction, DAEMON_SET_INFO,
    MountNamespaceState, PROCESS_GRANTED_ROOT, PROCESS_IS_FIRST_STARTED, PROCESS_IS_MANAGER,
    PROCESS_NAME_MAX_LEN, PROCESS_ON_DENYLIST, PROCESS_ROOT_IS_APATCH, ZYGOTE_INJECTED,
    ZYGISKD_PATH, zksu_version,
};
use modules::{load_modules, Context};
use root_impl::{
    get_impl, root_impl_cleanup, root_impls_setup, stringify_root_impl_name, uid_granted_root,
    uid_is_manager, uid_should_umount,
};
use utils::{
    check_unix_socket, non_blocking_execv, save_mns_fd, set_socket_create_context, strerror,
    switch_mount_namespace, unix_datagram_sendto, unix_listener_from_path,
};
use wire::{read_size, read_string, read_u32, read_u8, write_fd, write_size, write_string, write_u32, write_u8};

/* INFO: PATH_CP_NAME, with the socket created under the zygote SELinux
         context so the forked zygote can connect to it. */
fn create_daemon_socket() -> i32 {
    set_socket_create_context("u:r:zygote:s0");
    unix_listener_from_path(CP_SOCKET_PATH)
}

/* INFO: Mirrors C `spawn_companion`: forks a companion process that execs
         `zygiskd companion <fd>`, waits for it to load the module, then hands
         it the client fd on later requests. Returns the control fd to the
         companion, -1 on failure, -2 if the module has no companion entry. */
fn spawn_companion(argv0: &str, name: &str, lib_fd: i32) -> i32 {
    let mut sockets = [0i32; 2];
    if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, sockets.as_mut_ptr()) } == -1
    {
        loge!("Failed creating socket pair.");
        return -1;
    }
    let daemon_fd = sockets[0];
    let companion_fd = sockets[1];

    let pid = unsafe { libc::fork() };
    if pid < 0 {
        loge!("Failed forking companion: {}", strerror());
        unsafe {
            libc::close(companion_fd);
            libc::close(daemon_fd);
        }
        return -1;
    }

    if pid > 0 {
        unsafe { libc::close(companion_fd) };

        let mut status = 0;
        unsafe { libc::waitpid(pid, &mut status, 0) };

        if !libc::WIFEXITED(status) || libc::WEXITSTATUS(status) != 0 {
            loge!("Exited with status {status}");
            unsafe { libc::close(daemon_fd) };
            return -1;
        }

        if write_string(daemon_fd, name) == -1 {
            loge!("Failed writing module name.");
            unsafe { libc::close(daemon_fd) };
            return -1;
        }

        if write_fd(daemon_fd, lib_fd) == -1 {
            loge!("Failed sending library fd.");
            unsafe { libc::close(daemon_fd) };
            return -1;
        }

        let response = read_u8(daemon_fd);
        if response <= 0 {
            loge!("Failed reading companion response.");
            unsafe { libc::close(daemon_fd) };
            return -1;
        }

        match response as u8 {
            /* INFO: Even without any entry, we should still just deal with it */
            0 => {
                unsafe { libc::close(daemon_fd) };
                -2
            }
            1 => daemon_fd,
            _ => {
                unsafe { libc::close(daemon_fd) };
                -1
            }
        }
    } else {
        unsafe { libc::close(daemon_fd) };

        /* INFO: There is no case where this will fail with a valid fd. */
        if unsafe { libc::fcntl(companion_fd, libc::F_SETFD, 0) } == -1 {
            loge!("Failed removing FD_CLOEXEC flag: {}", strerror());
            unsafe {
                libc::close(companion_fd);
                libc::exit(1);
            }
        }

        let nice_name = argv0.rsplit('/').next().unwrap_or(argv0);
        let process_name = format!("{nice_name}-{name}");
        let companion_fd_str = format!("{companion_fd}");

        let cpath = CString::new(ZYGISKD_PATH).unwrap();
        let cproc = CString::new(process_name).unwrap();
        let ccompanion = CString::new("companion").unwrap();
        let cfd = CString::new(companion_fd_str).unwrap();
        let eargv: [*const c_char; 4] = [cproc.as_ptr(), ccompanion.as_ptr(), cfd.as_ptr(), ptr::null()];

        if non_blocking_execv(&cpath, &eargv) == -1 {
            loge!("Failed executing companion: {}", strerror());
            unsafe {
                libc::close(companion_fd);
                libc::exit(1);
            }
        }

        unsafe { libc::exit(0) };
    }
}

fn zygiskd_start(argv0: &str) {
    let _ = get_impl();
    let mut context: Context = load_modules();

    unix_datagram_sendto(CONTROLLER_SOCKET, &[DAEMON_SET_INFO]);

    {
        let impl_name = stringify_root_impl_name();
        let root_impl_len = impl_name.len() as u32;
        unix_datagram_sendto(CONTROLLER_SOCKET, &root_impl_len.to_ne_bytes());
        unix_datagram_sendto(CONTROLLER_SOCKET, impl_name.as_bytes());

        let modules_len = context.modules.len() as u32;
        unix_datagram_sendto(CONTROLLER_SOCKET, &modules_len.to_ne_bytes());

        for module in &context.modules {
            let module_name_len = module.name.len() as u32;
            unix_datagram_sendto(CONTROLLER_SOCKET, &module_name_len.to_ne_bytes());
            unix_datagram_sendto(CONTROLLER_SOCKET, module.name.as_bytes());
        }
    }

    logi!("Sent root implementation and modules information to controller socket");

    let socket_fd = create_daemon_socket();
    if socket_fd == -1 {
        loge!("Failed creating daemon socket");
        root_impl_cleanup();
        return;
    }

    let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
    sa.sa_sigaction = libc::SIG_IGN as usize;
    unsafe {
        libc::sigaction(libc::SIGPIPE, &sa, ptr::null_mut());
    }

    let mut first_process = true;
    'daemon: loop {
        let client_fd = unsafe { libc::accept(socket_fd, ptr::null_mut(), ptr::null_mut()) };
        if client_fd == -1 {
            loge!("accept: {}", strerror());
            break;
        }

        let action8 = read_u8(client_fd);
        if action8 == -1 {
            loge!("read: {}", strerror());
            unsafe { libc::close(client_fd) };
            break;
        } else if action8 == 0 {
            logi!("Client disconnected");
            unsafe { libc::close(client_fd) };
            break;
        }

        let Some(action) = DaemonSocketAction::from_u8(action8 as u8) else {
            unsafe { libc::close(client_fd) };
            continue;
        };

        match action {
            DaemonSocketAction::ZygoteInjected => {
                unix_datagram_sendto(CONTROLLER_SOCKET, &[ZYGOTE_INJECTED]);
            }
            DaemonSocketAction::ZygoteRestart => {
                for module in &mut context.modules {
                    if module.companion <= -1 {
                        continue;
                    }
                    unsafe { libc::close(module.companion) };
                    module.companion = -1;
                }
            }
            DaemonSocketAction::GetProcessFlags => {
                let mut uid: u32 = 0;
                let ret = read_u32(client_fd, &mut uid);
                if ret != 4 {
                    loge!("Failed to read uid in GetProcessFlags: Expected 4, got {ret}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                /* INFO: Used for APatch's isolated services, as it saves
                         process names. */
                let process = match read_string(client_fd, PROCESS_NAME_MAX_LEN) {
                    Ok(p) => p,
                    Err(_) => {
                        loge!("Failed reading process name.");
                        unsafe { libc::close(client_fd) };
                        continue 'daemon;
                    }
                };

                let mut flags: u32 = 0;
                if first_process {
                    flags |= PROCESS_IS_FIRST_STARTED;
                    first_process = false;
                }

                if uid_is_manager(uid) {
                    flags |= PROCESS_IS_MANAGER;
                } else {
                    if uid_granted_root(uid) {
                        flags |= PROCESS_GRANTED_ROOT;
                    }
                    if uid_should_umount(uid, process.as_bytes()) {
                        flags |= PROCESS_ON_DENYLIST;
                    }
                }

                /* INFO: impl is always APatch in this build */
                flags |= PROCESS_ROOT_IS_APATCH;

                let ret = write_u32(client_fd, flags);
                if ret != 4 {
                    loge!("Failed to send flags in GetProcessFlags: Expected 4, got {ret}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }
            }
            DaemonSocketAction::GetInfo => {
                let flags = PROCESS_ROOT_IS_APATCH;

                let ret = write_u32(client_fd, flags);
                if ret != 4 {
                    loge!("Failed to send flags in GetInfo: Expected 4, got {ret}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                let pid = unsafe { libc::getpid() } as u32;
                let ret = write_u32(client_fd, pid);
                if ret != 4 {
                    loge!("Failed to send pid in GetInfo: Expected 4, got {ret}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                let modules_len = context.modules.len();
                let ret = write_size(client_fd, modules_len);
                if ret != std::mem::size_of::<usize>() as isize {
                    loge!("Failed to send modules_len in GetInfo: Expected {}, got {ret}",
                          std::mem::size_of::<usize>());
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                for module in &context.modules {
                    if write_string(client_fd, &module.name) == -1 {
                        loge!("Failed writing module name.");
                        break;
                    }
                }
            }
            DaemonSocketAction::ReadModules => {
                let clen = context.modules.len();
                let ret = write_size(client_fd, clen);
                if ret != std::mem::size_of::<usize>() as isize {
                    loge!("Failed to send len in ReadModules: Expected {}, got {ret}",
                          std::mem::size_of::<usize>());
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                for module in &context.modules {
                    let lib_path =
                        format!("/data/adb/modules/{}/zygisk/{}.so", module.name, constants::ARCH_STR);
                    if write_string(client_fd, &lib_path) == -1 {
                        loge!("Failed writing module path.");
                        break;
                    }
                }
            }
            DaemonSocketAction::RequestCompanionSocket => {
                let mut index: usize = 0;
                let ret = read_size(client_fd, &mut index);
                if ret != std::mem::size_of::<usize>() as isize {
                    loge!("Failed to read index in RequestCompanionSocket: Expected {}, got {ret}",
                          std::mem::size_of::<usize>());
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                if index >= context.modules.len() {
                    loge!("Invalid module index: {index}");
                    let ret = write_u8(client_fd, 0);
                    if ret != 1 {
                        loge!("Failed to send response in RequestCompanionSocket: Expected 1, got {ret}");
                        unsafe { libc::close(client_fd) };
                        continue 'daemon;
                    }
                    break; /* INFO: C falls through and closes the client */
                }

                let module = &mut context.modules[index];
                if module.companion >= 0 {
                    if !check_unix_socket(module.companion, false) {
                        loge!(" - Companion for module \"{}\" crashed", module.name);
                        unsafe { libc::close(module.companion) };
                        module.companion = -1;
                    }
                }

                if module.companion <= -1 {
                    module.companion =
                        spawn_companion(argv0, &module.name, module.companion_lib_fd);

                    if module.companion >= 0 {
                        logi!(" - Spawned companion for \"{}\": {}", module.name, module.companion);
                    } else if module.companion == -2 {
                        loge!(" - No companion spawned for \"{}\" because it has no entry.",
                              module.name);
                    } else {
                        loge!(" - Failed to spawn companion for \"{}\": {}", module.name, strerror());
                    }
                }

                if module.companion >= 0 {
                    logi!(" - Sending companion fd socket of module \"{}\"", module.name);

                    if write_fd(module.companion, client_fd) == -1 {
                        loge!(" - Failed to send companion fd socket of module \"{}\"", module.name);
                        let ret = write_u8(client_fd, 0);
                        if ret != 1 {
                            loge!("Failed to send response in RequestCompanionSocket: Expected 1, got {ret}");
                            unsafe { libc::close(client_fd) };
                            continue 'daemon;
                        }
                        unsafe { libc::close(module.companion) };
                        module.companion = -1;
                    }
                } else {
                    loge!(" - Failed to spawn companion for module \"{}\"", module.name);
                    let ret = write_u8(client_fd, 0);
                    if ret != 1 {
                        loge!("Failed to send response in RequestCompanionSocket: Expected 1, got {ret}");
                        unsafe { libc::close(client_fd) };
                        continue 'daemon;
                    }
                }
            }
            DaemonSocketAction::GetModuleDir => {
                let mut index: usize = 0;
                let ret = read_size(client_fd, &mut index);
                if ret != std::mem::size_of::<usize>() as isize {
                    loge!("Failed to read index in GetModuleDir: Expected {}, got {ret}",
                          std::mem::size_of::<usize>());
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                if index >= context.modules.len() {
                    loge!("Invalid module index: {index}");
                    let ret = write_u8(client_fd, 0);
                    if ret != 1 {
                        loge!("Failed to send response in GetModuleDir: Expected 1, got {ret}");
                        unsafe { libc::close(client_fd) };
                        continue 'daemon;
                    }
                    break; /* INFO: C falls through and closes the client */
                }

                let module_dir = format!("{}/{}", constants::PATH_MODULES_DIR, context.modules[index].name);
                let cpath = CString::new(module_dir.as_str()).unwrap();
                let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDONLY) };
                if fd == -1 {
                    loge!("Failed opening module directory \"{}\": {}", module_dir, strerror());
                    break; /* INFO: C breaks the switch and closes the client */
                }

                if write_fd(client_fd, fd) == -1 {
                    loge!("Failed sending module directory \"{}\" fd: {}", module_dir, strerror());
                    unsafe { libc::close(fd) };
                    break; /* INFO: C breaks the switch and closes the client */
                }
            }
            DaemonSocketAction::UpdateMountNamespace => {
                let mut pid_u32: u32 = 0;
                let ret = read_u32(client_fd, &mut pid_u32);
                if ret != 4 {
                    loge!("Failed to read pid in UpdateMountNamespace: Expected 4, got {ret}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }
                let pid = pid_u32 as i32;

                let mns_state_raw = read_u8(client_fd);
                if mns_state_raw == -1 {
                    loge!("Failed to read mns_state in UpdateMountNamespace: got {mns_state_raw}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }
                let Some(mns_state) = MountNamespaceState::from_u8(mns_state_raw as u8) else {
                    loge!("Invalid mount namespace state: {mns_state_raw}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                };

                let our_pid = unsafe { libc::getpid() } as u32;
                let ret = write_u32(client_fd, our_pid);
                if ret != 4 {
                    loge!("Failed to send our_pid in UpdateMountNamespace: Expected 4, got {ret}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                if mns_state == MountNamespaceState::Clean {
                    save_mns_fd(pid, MountNamespaceState::Mounted);
                }

                let ns_fd = save_mns_fd(pid, mns_state);
                if ns_fd == -1 {
                    loge!("Failed to save mount namespace fd for pid {pid}: {}", strerror());
                    let ret = write_u32(client_fd, 0);
                    if ret != 4 {
                        loge!("Failed to send ns_fd in UpdateMountNamespace: Expected 4, got {ret}");
                        unsafe { libc::close(client_fd) };
                        continue 'daemon;
                    }
                    break; /* INFO: C breaks the switch and closes the client */
                }

                let ret = write_u32(client_fd, ns_fd as u32);
                if ret != 4 {
                    loge!("Failed to send ns_fd in UpdateMountNamespace: Expected 4, got {ret}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }
            }
            DaemonSocketAction::RemoveModule => {
                let mut index: usize = 0;
                let ret = read_size(client_fd, &mut index);
                if ret != std::mem::size_of::<usize>() as isize {
                    loge!("Failed to read index in RemoveModule: Expected {}, got {ret}",
                          std::mem::size_of::<usize>());
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }

                if index >= context.modules.len() {
                    loge!("Invalid module index: {index}");
                    let ret = write_u8(client_fd, 0);
                    if ret != 1 {
                        loge!("Failed to send response in RemoveModule: Expected 1, got {ret}");
                        unsafe { libc::close(client_fd) };
                        continue 'daemon;
                    }
                    break; /* INFO: C falls through and closes the client */
                }

                let mut module = context.modules.remove(index);
                if module.companion >= 0 {
                    unsafe { libc::close(module.companion) };
                    module.companion = -1;
                }
                if module.companion_lib_fd >= 0 {
                    unsafe { libc::close(module.companion_lib_fd) };
                    module.companion_lib_fd = -1;
                }

                let ret = write_u8(client_fd, 1);
                if ret != 1 {
                    loge!("Failed to send response in RemoveModule: Expected 1, got {ret}");
                    unsafe { libc::close(client_fd) };
                    continue 'daemon;
                }
            }
        }

        unsafe { libc::close(client_fd) };
    }

    unsafe { libc::close(socket_fd) };
    root_impl_cleanup();
}

fn main() {
    logi!("Welcome to ReZygiskd{BIN_SUFFIX}");

    let args: Vec<String> = std::env::args().collect();

    if args.len() > 1 {
        match args[1].as_str() {
            "companion" => {
                if args.len() < 3 {
                    logi!("Usage: zygiskd companion <fd>");
                    std::process::exit(1);
                }
                let fd: i32 = args[2].parse().unwrap_or(0);
                companion::companion_entry(fd);
                return;
            }
            "version" => {
                logi!("ReZygisk Daemon {}", zksu_version());
                return;
            }
            "root" => {
                root_impls_setup();
                logi!("Root implementation: {}", stringify_root_impl_name());
                return;
            }
            _ => {
                logi!("Usage: zygiskd [companion|version|root]");
                return;
            }
        }
    }

    if !switch_mount_namespace(1) {
        loge!("Failed to switch mount namespace");
        std::process::exit(1);
    }
    root_impls_setup();
    zygiskd_start(args.first().map(|s| s.as_str()).unwrap_or("zygiskd"));
}
