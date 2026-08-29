//! Low-level utilities mirroring the C `zygiskd/src/utils.c`.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::ptr;
use std::sync::atomic::{AtomicI32, Ordering};

use crate::constants::MountNamespaceState;
use crate::loge;
use crate::logi;
use crate::logw;
use crate::wire;

pub fn strerror() -> String {
    std::io::Error::last_os_error().to_string()
}

/* INFO: Mirrors the C `atoi`: parse leading ASCII digits, ignore the rest. */
pub fn atoi(s: &str) -> i32 {
    let s = s.trim_start();
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse::<i32>().unwrap_or(0)
}

pub fn switch_mount_namespace(pid: i32) -> bool {
    let path = format!("/proc/{pid}/ns/mnt");
    let cpath = CString::new(path).unwrap();
    let nsfd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
    if nsfd == -1 {
        loge!("Failed to open nsfd: {}", strerror());
        return false;
    }

    if unsafe { libc::setns(nsfd, libc::CLONE_NEWNS) } == -1 {
        loge!("Failed to setns: {}", strerror());
        unsafe { libc::close(nsfd) };
        return false;
    }

    unsafe { libc::close(nsfd) };
    true
}

fn write_file(path: &str, data: &[u8]) -> bool {
    let cpath = CString::new(path).unwrap();
    let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_WRONLY | libc::O_CLOEXEC) };
    if fd == -1 {
        return false;
    }

    let mut written = 0usize;
    while written < data.len() {
        let ret = unsafe {
            libc::write(
                fd,
                data.as_ptr().add(written) as *const c_void,
                data.len() - written,
            )
        };
        if ret < 0 {
            unsafe { libc::close(fd) };
            return false;
        }
        written += ret as usize;
    }
    unsafe { libc::close(fd) };
    true
}

pub fn set_socket_create_context(context: &str) {
    let bytes = context.as_bytes();
    if !write_file("/proc/thread-self/attr/sockcreate", bytes) {
        loge!(
            "Failed to open sockcreate with {}: {}. Retrying with tid.",
            std::io::Error::last_os_error().raw_os_error().unwrap_or(0),
            strerror()
        );

        let tid = unsafe { libc::gettid() };
        let path = format!("/proc/self/task/{tid}/attr/sockcreate");
        if !write_file(&path, bytes) {
            loge!(
                "Failed to open tid sockcreate with {}: {}",
                std::io::Error::last_os_error().raw_os_error().unwrap_or(0),
                strerror()
            );
        }
    }
}

fn get_current_attr() -> Option<String> {
    let cpath = CString::new("/proc/self/attr/current").unwrap();
    let fd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
    if fd == -1 {
        return None;
    }

    let mut buf = [0u8; 4096];
    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut c_void, buf.len()) };
    unsafe { libc::close(fd) };
    if n <= 0 {
        return None;
    }

    let len = (n as usize).min(buf.len() - 1);
    Some(String::from_utf8_lossy(&buf[..len]).into_owned())
}

fn sockaddr_un(path: &str) -> (libc::sockaddr_un, usize) {
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let max = std::mem::size_of_val(&addr.sun_path) - 1;
    let n = path.as_bytes().len().min(max);
    for (dst, &src) in addr.sun_path[..n].iter_mut().zip(&path.as_bytes()[..n]) {
        *dst = src as libc::c_char;
    }
    let len = std::mem::size_of::<libc::sockaddr_un>();
    (addr, len)
}

pub fn unix_datagram_sendto(path: &str, buf: &[u8]) {
    let current_attr = match get_current_attr() {
        Some(a) => a,
        None => {
            loge!("Failed to get current attribute");
            return;
        }
    };

    set_socket_create_context(&current_attr);

    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_DGRAM, 0) };
    if fd == -1 {
        loge!("socket: {}", strerror());
        set_socket_create_context("u:r:zygote:s0");
        return;
    }

    let (addr, addrlen) = sockaddr_un(path);
    let sock = &addr as *const libc::sockaddr_un as *const libc::sockaddr;
    if unsafe { libc::connect(fd, sock, addrlen as libc::socklen_t) } == -1 {
        loge!("connect: {}", strerror());
        unsafe { libc::close(fd) };
        set_socket_create_context("u:r:zygote:s0");
        return;
    }

    let ret = unsafe {
        libc::sendto(
            fd,
            buf.as_ptr() as *const c_void,
            buf.len(),
            0,
            sock,
            addrlen as libc::socklen_t,
        )
    };
    if ret == -1 {
        loge!("sendto: {}", strerror());
        unsafe { libc::close(fd) };
        set_socket_create_context("u:r:zygote:s0");
        return;
    }

    set_socket_create_context("u:r:zygote:s0");
    unsafe { libc::close(fd) };
}

/* INFO: Mirrors C `chcon`: lsetxattr on the SELinux attribute. */
pub fn chcon(path: &str, context: &str) -> i32 {
    let cpath = CString::new(path).unwrap();
    let cname = CString::new("security.selinux").unwrap();
    let cctx = CString::new(context).unwrap();
    unsafe {
        libc::lsetxattr(
            cpath.as_ptr(),
            cname.as_ptr(),
            cctx.as_ptr() as *const c_void,
            context.len() + 1,
            0,
        )
    }
}

pub fn unix_listener_from_path(path: &str) -> i32 {
    let cpath = CString::new(path).unwrap();
    unsafe {
        if libc::remove(cpath.as_ptr()) == -1
            && std::io::Error::last_os_error().raw_os_error() != Some(libc::ENOENT)
        {
            loge!("remove: {}", strerror());
            return -1;
        }

        let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
        if fd == -1 {
            loge!("socket: {}", strerror());
            return -1;
        }

        let (addr, addrlen) = sockaddr_un(path);
        let sock = &addr as *const libc::sockaddr_un as *const libc::sockaddr;
        if libc::bind(fd, sock, addrlen as libc::socklen_t) == -1 {
            loge!("bind: {}", strerror());
            libc::close(fd);
            return -1;
        }

        if libc::listen(fd, 2) == -1 {
            loge!("listen: {}", strerror());
            libc::close(fd);
            return -1;
        }

        if chcon(path, "u:object_r:zygisk_file:s0") == -1 {
            logw!("chcon (non-fatal): {}", strerror());
        }

        fd
    }
}

/* INFO: Runs `file` with `argv` (argv[0] must be provided by the caller as
         the first element), captures up to `max_len` bytes of stdout.
         Returns the captured bytes with the trailing newline stripped,
         matching the C `exec_command`. */
pub fn exec_command(file: &CStr, argv: &[*const c_char], max_len: usize) -> Option<Vec<u8>> {
    unsafe {
        let mut link = [0i32; 2];
        if libc::pipe(link.as_mut_ptr()) == -1 {
            loge!("pipe: {}", strerror());
            return None;
        }

        let pid = libc::fork();
        if pid < 0 {
            loge!("fork: {}", strerror());
            libc::close(link[0]);
            libc::close(link[1]);
            return None;
        }

        if pid == 0 {
            libc::dup2(link[1], libc::STDOUT_FILENO);
            libc::close(link[0]);
            libc::close(link[1]);
            libc::execv(file.as_ptr(), argv.as_ptr());
            loge!("execv failed: {}", strerror());
            libc::_exit(1);
        }

        libc::close(link[1]);
        let mut buf = vec![0u8; max_len];
        let n = libc::read(link[0], buf.as_mut_ptr() as *mut c_void, max_len);
        libc::close(link[0]);

        let mut status = 0;
        libc::waitpid(pid, &mut status, 0);

        if n > 0 {
            let len = (n as usize).saturating_sub(1);
            buf.truncate(len);
            Some(buf)
        } else {
            Some(Vec::new())
        }
    }
}

pub fn check_unix_socket(fd: i32, block: bool) -> bool {
    let mut pfd = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    let timeout: i32 = if block { -1 } else { 0 };
    if unsafe { libc::poll(&mut pfd, 1, timeout) } == -1 {
        loge!("poll: {}", strerror());
        return false;
    }

    pfd.revents & !libc::POLLIN == 0
}

/* INFO: Mirrors C `non_blocking_execv`: forks, redirects stdout to a pipe,
         execs `file`. Returns the pipe read end (or -1). */
pub fn non_blocking_execv(file: &CStr, argv: &[*const c_char]) -> i32 {
    unsafe {
        let mut link = [0i32; 2];
        if libc::pipe(link.as_mut_ptr()) == -1 {
            loge!("pipe: {}", strerror());
            return -1;
        }

        let pid = libc::fork();
        if pid < 0 {
            loge!("fork: {}", strerror());
            return -1;
        }

        if pid == 0 {
            libc::dup2(link[1], libc::STDOUT_FILENO);
            libc::close(link[0]);
            libc::close(link[1]);
            libc::execv(file.as_ptr(), argv.as_ptr());
            libc::_exit(1);
        }

        libc::close(link[1]);
        link[0]
    }
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Mountinfo {
    pub id: u32,
    pub parent: u32,
    pub device: u64,
    pub root: String,
    pub target: String,
    pub vfs_option: String,
    pub shared: u32,
    pub master: u32,
    pub propagate_from: u32,
    pub fstype: String,
    pub source: String,
    pub fs_option: String,
}

fn makedev(maj: u32, min: u32) -> u64 {
    let maj = maj as u64;
    let min = min as u64;
    ((maj & 0xfffff000) << 32)
        | ((maj & 0xfff) << 8)
        | ((min & 0xffffff00) << 12)
        | (min & 0xff)
}

pub fn parse_mountinfo(pid: &str) -> Option<Vec<Mountinfo>> {
    let path = format!("/proc/{pid}/mountinfo");
    let content = std::fs::read_to_string(path).ok()?;

    let mut mounts = Vec::new();
    for line in content.lines() {
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.len() < 6 {
            continue;
        }

        let id = atoi(tokens[0]) as u32;
        let parent = atoi(tokens[1]) as u32;
        let majmin: Vec<&str> = tokens[2].split(':').collect();
        let maj = majmin.first().map(|s| atoi(s) as u32).unwrap_or(0);
        let min = majmin.get(1).map(|s| atoi(s) as u32).unwrap_or(0);
        let device = makedev(maj, min);

        let root = tokens[3].to_string();
        let target = tokens[4].to_string();
        let vfs_option = tokens[5].to_string();

        let mut shared = 0u32;
        let mut master = 0u32;
        let mut propagate_from = 0u32;
        let mut fstype = String::new();
        let mut source = String::new();
        let mut fs_option = String::new();

        if let Some(dash) = tokens.iter().position(|&t| t == "-") {
            for opt in &tokens[6..dash] {
                if let Some(rest) = opt.strip_prefix("shared:") {
                    shared = atoi(rest) as u32;
                } else if let Some(rest) = opt.strip_prefix("master:") {
                    master = atoi(rest) as u32;
                } else if let Some(rest) = opt.strip_prefix("propagate_from:") {
                    propagate_from = atoi(rest) as u32;
                }
            }
            let base = dash + 1;
            if base < tokens.len() {
                fstype = tokens[base].to_string();
            }
            if base + 1 < tokens.len() {
                source = tokens[base + 1].to_string();
            }
            if base + 2 < tokens.len() {
                fs_option = tokens[base + 2].to_string();
            }
        }

        mounts.push(Mountinfo {
            id,
            parent,
            device,
            root,
            target,
            vfs_option,
            shared,
            master,
            propagate_from,
            fstype,
            source,
            fs_option,
        });
    }

    Some(mounts)
}

pub fn umount_root() -> bool {
    let mounts = match parse_mountinfo("self") {
        Some(m) => m,
        None => {
            loge!("Failed to parse mountinfo");
            return false;
        }
    };

    const SOURCE_NAME: &str = "APatch";
    logi!("[{}] Unmounting root", SOURCE_NAME);

    let mut targets: Vec<String> = Vec::new();
    for mount in &mounts {
        let mut should_unmount = false;
        if mount.source == SOURCE_NAME {
            should_unmount = true;
        }
        if mount.target.starts_with("/data/adb/modules") {
            should_unmount = true;
        }
        if mount.root.starts_with("/adb/modules/") {
            should_unmount = true;
        }
        if should_unmount {
            targets.push(mount.target.clone());
        }
    }

    for target in targets.iter().rev() {
        let ctarget = CString::new(target.as_str()).unwrap();
        if unsafe { libc::umount2(ctarget.as_ptr(), libc::MNT_DETACH) } == -1 {
            loge!("[{}] Failed to unmount {}: {}", SOURCE_NAME, target, strerror());
            continue;
        }
        logi!("[{}] Unmounted {}", SOURCE_NAME, target);
    }

    true
}

static CLEAN_NAMESPACE_FD: AtomicI32 = AtomicI32::new(-1);
static MOUNTED_NAMESPACE_FD: AtomicI32 = AtomicI32::new(-1);

/* INFO: Mirrors C `save_mns_fd`. Forks a child that switches into the target
         mount namespace (and, for Clean, unshares + umounts the root), then
         caches the child's mnt ns fd. */
pub fn save_mns_fd(pid: i32, mns_state: MountNamespaceState) -> i32 {
    let cached = match mns_state {
        MountNamespaceState::Clean => CLEAN_NAMESPACE_FD.load(Ordering::SeqCst),
        MountNamespaceState::Mounted => MOUNTED_NAMESPACE_FD.load(Ordering::SeqCst),
    };
    if cached != -1 {
        return cached;
    }

    let mut sockets = [0i32; 2];
    if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, sockets.as_mut_ptr()) } == -1 {
        loge!("socketpair: {}", strerror());
        return -1;
    }
    let socket_parent = sockets[0];
    let socket_child = sockets[1];

    let fork_pid = unsafe { libc::fork() };
    if fork_pid < 0 {
        loge!("fork: {}", strerror());
        unsafe {
            libc::close(socket_parent);
            libc::close(socket_child);
        }
        return -1;
    }

    if fork_pid == 0 {
        unsafe { libc::close(socket_parent) };

        if !switch_mount_namespace(pid) {
            loge!("Failed to switch mount namespace");
            let _ = wire::write_u8(socket_child, 0);
            unsafe {
                libc::close(socket_child);
                libc::_exit(0);
            }
        }

        if mns_state == MountNamespaceState::Clean {
            unsafe { libc::unshare(libc::CLONE_NEWNS) };
            if !umount_root() {
                loge!("Failed to umount root");
                let _ = wire::write_u8(socket_child, 0);
                unsafe {
                    libc::close(socket_child);
                    libc::_exit(0);
                }
            }
        }

        if wire::write_u8(socket_child, 1) != 1 {
            loge!("Failed to write to socket_child: {}", strerror());
            unsafe {
                libc::close(socket_child);
                libc::_exit(1);
            }
        }

        let _ = wire::read_u8(socket_child);

        unsafe {
            libc::close(socket_child);
            libc::_exit(0);
        }
    }

    unsafe { libc::close(socket_child) };

    let has_succeeded = wire::read_u8(socket_parent);
    if has_succeeded == -1 {
        loge!("Failed to read from socket_parent: {}", strerror());
        unsafe { libc::close(socket_parent) };
        return -1;
    }
    if has_succeeded == 0 {
        loge!("Failed to umount root");
        unsafe { libc::close(socket_parent) };
        return -1;
    }

    let ns_path = format!("/proc/{fork_pid}/ns/mnt");
    let cpath = CString::new(ns_path).unwrap();
    let ns_fd = unsafe { libc::open(cpath.as_ptr(), libc::O_RDONLY) };
    if ns_fd == -1 {
        loge!("open: {}", strerror());
        unsafe { libc::close(socket_parent) };
        return -1;
    }

    let _ = wire::write_u8(socket_parent, 1);

    unsafe { libc::close(socket_parent) };

    let mut status = 0;
    unsafe {
        libc::waitpid(fork_pid, &mut status, 0);
    }

    match mns_state {
        MountNamespaceState::Clean => {
            CLEAN_NAMESPACE_FD.store(ns_fd, Ordering::SeqCst);
        }
        MountNamespaceState::Mounted => {
            MOUNTED_NAMESPACE_FD.store(ns_fd, Ordering::SeqCst);
        }
    }

    ns_fd
}

/* INFO: Kept for C-parity; unused in the current build. */
#[allow(dead_code)]
pub fn get_property(name: &str) -> String {
    extern "C" {
        fn __system_property_get(__name: *const c_char, __value: *mut u8) -> i32;
    }
    let cname = CString::new(name).unwrap();
    let mut buf = [0u8; 92];
    unsafe {
        __system_property_get(cname.as_ptr(), buf.as_mut_ptr());
        let n = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        String::from_utf8_lossy(&buf[..n]).into_owned()
    }
}

/* Re-export ptr to silence potential unused-import warnings under some cfgs. */
#[allow(unused_imports)]
use ptr as _ptr;
