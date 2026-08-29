use std::env;

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "android" {
        // __android_log_print lives in liblog on Android
        println!("cargo:rustc-link-lib=log");
    }

    println!("cargo:rerun-if-env-changed=MIN_APATCH_VERSION");
    println!("cargo:rerun-if-env-changed=ZKSU_VERSION");
    if let Ok(v) = env::var("MIN_APATCH_VERSION") {
        println!("cargo:rustc-env=MIN_APATCH_VERSION={}", v);
    }
    if let Ok(v) = env::var("ZKSU_VERSION") {
        println!("cargo:rustc-env=ZKSU_VERSION={}", v);
    }
}
