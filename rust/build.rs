// Build script for the Rust loader crate.
//
// 1) Embeds the packaged ocl-icd version so clGetICDLoaderInfoOCLICD reports
//    the exact string the C loader does (the upstream testsuite pins it).
//    Resolution order: OCL_ICD_RS_VERSION (set by the integration Makefile),
//    a VERSION file at the source root, the AC_INIT version in
//    ../configure.ac, else the crate version (which tracks releases).
// 2) When OCL_ICD_RS_MAP is set, applies the OPENCL_x.y version script to
//    the cdylib link (link-args here never reach build-script binaries).
//
// The slot tables (src/slots.rs, src/gen_forwarders.rs) are generated
// before cargo runs, by: ruby icd_generator.rb --mode rust-generate
// (rust/build-loader.sh); rust/scripts/gen_bindings.py is the parity oracle.
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

    if let Ok(map) = env::var("OCL_ICD_RS_MAP") {
        println!("cargo:rustc-link-arg=-Wl,--version-script={}", map);
    }
}
