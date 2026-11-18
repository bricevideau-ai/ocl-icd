// Embeds the packaged ocl-icd version so clGetICDLoaderInfoOCLICD reports the
// exact string the C loader does (the upstream testsuite pins it). Resolution
// order: OCL_ICD_RS_VERSION (set by the integration Makefile), a VERSION file
// at the source root, the AC_INIT version in ../configure.ac, else the crate
// version (which tracks releases).
use std::{env, fs};
fn main() {
    let v = env::var("OCL_ICD_RS_VERSION").unwrap_or_else(|_| {
        let dir = env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
        for path in [format!("{}/../VERSION", dir), format!("{}/../configure.ac", dir)] {
            if let Ok(s) = fs::read_to_string(&path) {
                if path.ends_with("VERSION") {
                    return s.trim().to_string();
                }
                if let Some(line) = s.lines().find(|l| l.starts_with("AC_INIT(")) {
                    if let Some(v) = line.split(',').nth(1) {
                        return v.trim().to_string();
                    }
                }
            }
        }
        env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.0.0".to_string())
    });
    println!("cargo:rustc-env=OCL_ICD_VERSION={}", v);
    // Pass 2 of rust/build-loader.sh: apply the OPENCL_x.y version map to the
    // cdylib only (link-args here never reach build-script binaries).
    if let Ok(map) = env::var("OCL_ICD_RS_MAP") {
        println!("cargo:rustc-link-arg=-Wl,--version-script={}", map);
    }
}
