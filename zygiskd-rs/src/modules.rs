//! Module discovery, mirroring the C `load_modules` in `zygiskd/src/zygiskd.c`.

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use crate::constants::{ARCH_STR, PATH_MODULES_DIR};
use crate::loge;
use crate::logi;

pub struct Module {
    pub name: String,
    /* INFO: Library loaded into the companion process. Points to the
             dedicated companion library (zygisk/companion/<arch>.so) when it
             exists, otherwise falls back to the combined module library
             (zygisk/<arch>.so). */
    pub companion_lib_fd: i32,
    pub companion: i32,
}

pub struct Context {
    pub modules: Vec<Module>,
}

impl Context {
    pub fn new() -> Self {
        Context {
            modules: Vec::new(),
        }
    }
}

fn access_ok(path: &Path, mode: i32) -> bool {
    let cpath = CString::new(path.as_os_str().as_bytes()).unwrap();
    let ok = unsafe { libc::access(cpath.as_ptr(), mode) };
    ok == 0
}

pub fn load_modules() -> Context {
    let mut context = Context::new();

    let dir = match std::fs::read_dir(PATH_MODULES_DIR) {
        Ok(d) => d,
        Err(e) => {
            loge!("Failed opening modules directory: {}. {}", PATH_MODULES_DIR, e);
            return context;
        }
    };

    logi!("Loading modules for architecture: {}", ARCH_STR);

    for entry in dir.flatten() {
        /* INFO: Only directories */
        if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }

        let name_bytes = entry.file_name().as_bytes().to_vec();
        if name_bytes == b"rezygisk" {
            continue;
        }
        let name = String::from_utf8_lossy(&name_bytes).into_owned();

        let so_path = Path::new(PATH_MODULES_DIR)
            .join(&name)
            .join("zygisk")
            .join(format!("{}.so", ARCH_STR));
        if !access_ok(&so_path, libc::R_OK) {
            continue;
        }

        let disabled = Path::new(PATH_MODULES_DIR).join(&name).join("disable");
        if access_ok(&disabled, libc::F_OK) {
            continue;
        }

        /* INFO: A module may ship a dedicated companion library at
                 zygisk/companion/<arch>.so so that the code injected into apps
                 (zygisk/<arch>.so) and the code loaded into the companion
                 process stay separate. When that file is absent, the combined
                 module library is used for the companion as well (legacy
                 behaviour). */
        let companion_so_path = Path::new(PATH_MODULES_DIR)
            .join(&name)
            .join("zygisk")
            .join("companion")
            .join(format!("{}.so", ARCH_STR));

        let (companion_lib_path, dedicated) = if access_ok(&companion_so_path, libc::R_OK) {
            (companion_so_path, true)
        } else {
            (so_path, false)
        };

        let cpath = CString::new(companion_lib_path.as_os_str().as_bytes()).unwrap();
        let companion_lib_fd =
            unsafe { libc::open(cpath.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
        if companion_lib_fd == -1 {
            loge!("Failed loading module \"{}\"", name);
            continue;
        }

        if dedicated {
            logi!("Module \"{}\" ships a dedicated companion library", name);
        }

        context.modules.push(Module {
            name,
            companion_lib_fd,
            companion: -1,
        });
    }

    context
}
