//! Byte-level wire protocol primitives, byte-compatible with the C
//! implementation in `zygiskd/src/utils.c` and `loader/src/common/socket_utils.c`.
//!
//! - `u8` / `u32` / `size_t` are transmitted in native endianness (both peers
//!   always run on the same architecture).
//! - Strings are length-prefixed by a `size_t`.
//! - File descriptors are passed via `SCM_RIGHTS` ancillary data.

use std::ptr;

use crate::loge;

/* INFO: Same behaviour as the C `write_loop`: loop until all bytes are
         written, retrying on EAGAIN (1ms sleep) and EINTR. */
fn write_all(fd: i32, buf: &[u8]) -> isize {
    let mut written: usize = 0;
    while written < buf.len() {
        let ret = unsafe {
            libc::write(
                fd,
                buf.as_ptr().add(written) as *const libc::c_void,
                buf.len() - written,
            )
        };
        if ret < 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            if err.raw_os_error() == Some(libc::EAGAIN) {
                unsafe {
                    libc::usleep(1000);
                }
                continue;
            }
            return -1;
        }
        if ret == 0 {
            return -1;
        }
        written += ret as usize;
    }
    written as isize
}

fn read_exact(fd: i32, buf: &mut [u8]) -> isize {
    let mut got: usize = 0;
    while got < buf.len() {
        let ret = unsafe {
            libc::read(
                fd,
                buf.as_mut_ptr().add(got) as *mut libc::c_void,
                buf.len() - got,
            )
        };
        if ret < 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EINTR) || err.raw_os_error() == Some(libc::EAGAIN) {
                continue;
            }
            return -1;
        }
        if ret == 0 {
            return -1;
        }
        got += ret as usize;
    }
    got as isize
}

/* INFO: Single read like the C `read_uint8_t`, so EOF (0) can be
         distinguished from a hard error (-1). */
pub fn read_u8(fd: i32) -> isize {
    let mut v: u8 = 0;
    unsafe {
        let ret = libc::read(fd, (&mut v as *mut u8).cast::<libc::c_void>(), 1);
        if ret < 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EINTR) || err.raw_os_error() == Some(libc::EAGAIN) {
                return read_u8(fd);
            }
            return -1;
        }
        if ret == 0 {
            return 0;
        }
    }
    v as isize
}

pub fn write_u8(fd: i32, v: u8) -> isize {
    write_all(fd, &[v])
}

pub fn write_u32(fd: i32, v: u32) -> isize {
    write_all(fd, &v.to_ne_bytes())
}

pub fn read_u32(fd: i32, out: &mut u32) -> isize {
    let mut bytes = [0u8; 4];
    let ret = read_exact(fd, &mut bytes);
    if ret < 0 {
        return -1;
    }
    *out = u32::from_ne_bytes(bytes);
    ret
}

pub fn write_size(fd: i32, v: usize) -> isize {
    write_all(fd, &v.to_ne_bytes())
}

pub fn read_size(fd: i32, out: &mut usize) -> isize {
    let mut bytes = [0u8; std::mem::size_of::<usize>()];
    let ret = read_exact(fd, &mut bytes);
    if ret < 0 {
        return -1;
    }
    *out = usize::from_ne_bytes(bytes);
    ret
}

/* INFO: length-prefixed string, matching C `write_string`. */
pub fn write_string(fd: i32, s: &str) -> isize {
    let len = s.len();
    if write_all(fd, &len.to_ne_bytes()) != std::mem::size_of::<usize>() as isize {
        loge!("Failed to write string length: Not all bytes were written.");
        return -1;
    }
    let ret = write_all(fd, s.as_bytes());
    if ret != len as isize {
        loge!("Failed to write string: Not all bytes were written.");
        return -1;
    }
    ret
}

/* INFO: Reads a length-prefixed string, bounded by `max_len` (excluding the
         NUL terminator), matching the daemon-side `read_string`. */
pub fn read_string(fd: i32, max_len: usize) -> Result<String, ()> {
    let mut str_len: usize = 0;
    if read_size(fd, &mut str_len) < 0 {
        return Err(());
    }
    if str_len > max_len {
        loge!("Failed to read string: Buffer is too small ({} > {max_len}).", str_len);
        return Err(());
    }
    let mut buf = vec![0u8; str_len];
    if read_exact(fd, &mut buf) != str_len as isize {
        loge!("Failed to read string: Promised bytes doesn't exist.");
        return Err(());
    }
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

fn cmsg_len(len: usize) -> usize {
    unsafe { libc::CMSG_LEN(len as libc::c_uint) as usize }
}

fn cmsg_space(len: usize) -> usize {
    unsafe { libc::CMSG_SPACE(len as libc::c_uint) as usize }
}

fn cmsg_align(len: usize) -> usize {
    let align = std::mem::size_of::<usize>();
    (len + align - 1) & !(align - 1)
}

/* INFO: Manual CMSG_NXTHDR since libc does not expose it. */
unsafe fn cmsg_next(
    mhdr: *const libc::msghdr,
    cmsg: *const libc::cmsghdr,
) -> *mut libc::cmsghdr {
    let next = (cmsg as *const u8).add(cmsg_align((*cmsg).cmsg_len)) as *const libc::cmsghdr;
    let control_start = (*mhdr).msg_control as usize;
    let controllen = (*mhdr).msg_controllen;
    if next as usize + std::mem::size_of::<libc::cmsghdr>() > control_start + controllen {
        return ptr::null_mut();
    }
    next as *mut libc::cmsghdr
}

/* INFO: Mirror of C `write_fd`: sends `sendfd` over `fd` as SCM_RIGHTS. */
pub fn write_fd(fd: i32, sendfd: i32) -> isize {
    unsafe {
        let space = cmsg_space(std::mem::size_of::<libc::c_int>());
        let cmsgbuf = vec![0u8; space];
        let mut msg: libc::msghdr = std::mem::zeroed();
        let mut iov = libc::iovec {
            iov_base: [0u8].as_mut_ptr().cast(),
            iov_len: 1,
        };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsgbuf.as_ptr() as *mut libc::c_void;
        msg.msg_controllen = cmsgbuf.len();

        let cmsg = cmsgbuf.as_ptr() as *mut libc::cmsghdr;
        (*cmsg).cmsg_len = cmsg_len(std::mem::size_of::<libc::c_int>());
        (*cmsg).cmsg_level = libc::SOL_SOCKET;
        (*cmsg).cmsg_type = libc::SCM_RIGHTS;
        ptr::copy_nonoverlapping(
            &sendfd as *const libc::c_int,
            libc::CMSG_DATA(cmsg).cast::<libc::c_int>(),
            1,
        );

        let ret = libc::sendmsg(fd, &msg, 0);
        if ret == -1 {
            loge!("sendmsg: {}", std::io::Error::last_os_error());
            return -1;
        }
        ret
    }
}

/* INFO: Mirror of C `read_fd`: receives one fd via SCM_RIGHTS. */
pub fn read_fd(fd: i32) -> i32 {
    unsafe {
        let space = cmsg_space(std::mem::size_of::<libc::c_int>());
        let mut cmsgbuf = vec![0u8; space];
        let mut cnt: libc::c_int = 1;
        let mut iov = libc::iovec {
            iov_base: (&mut cnt as *mut libc::c_int).cast(),
            iov_len: std::mem::size_of::<libc::c_int>(),
        };
        let mut msg: libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsgbuf.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = cmsgbuf.len();

        let ret = libc::recvmsg(fd, &mut msg, libc::MSG_WAITALL);
        if ret == -1 {
            loge!("recvmsg: {}", std::io::Error::last_os_error());
            return -1;
        }

        let mut sendfd: libc::c_int = -1;
        let mut cmsg = cmsgbuf.as_ptr() as *const libc::cmsghdr;
        let first = msg.msg_control as *const libc::cmsghdr;
        if !first.is_null() {
            loop {
                if (*cmsg).cmsg_level == libc::SOL_SOCKET
                    && (*cmsg).cmsg_type == libc::SCM_RIGHTS
                    && (*cmsg).cmsg_len >= cmsg_len(std::mem::size_of::<libc::c_int>())
                {
                    ptr::copy_nonoverlapping(
                        libc::CMSG_DATA(cmsg).cast::<libc::c_int>(),
                        &mut sendfd,
                        1,
                    );
                    break;
                }
                let next = cmsg_next(&msg, cmsg);
                if next.is_null() {
                    break;
                }
                cmsg = next;
            }
        }

        if sendfd == -1 {
            loge!("Failed to receive fd: No valid fd found in ancillary data.");
            return -1;
        }
        sendfd
    }
}

/* INFO: Kept for symmetry; unused for now. */
#[allow(dead_code)]
pub struct Wire;

#[allow(dead_code)]
impl Wire {
    pub fn write_uint8(fd: i32, v: u8) -> isize {
        write_u8(fd, v)
    }
}
