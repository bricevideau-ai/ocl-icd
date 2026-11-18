//! Minimal libc surface (dlopen family + a few errno constants), declared
//! directly against the C runtime the process already links. The crate carries
//! NO crates.io dependencies so it builds offline in CI and inside the ocl-icd
//! source tree with only a Rust toolchain.
#![allow(dead_code)]

pub type Mode = core::ffi::c_int;

pub const RTLD_LAZY: Mode = 0x1;
pub const RTLD_LOCAL: Mode = 0;

// glibc/macOS values.
pub const RTLD_NEXT: *mut core::ffi::c_void = -1isize as *mut core::ffi::c_void;
pub const RTLD_DEFAULT: *mut core::ffi::c_void = 0isize as *mut core::ffi::c_void;

pub const ENOENT: core::ffi::c_int = 2;
pub const ENOTDIR: core::ffi::c_int = 20;

extern "C" {
    #[link_name = "dlopen"]
    pub fn dlopen(filename: *const core::ffi::c_char, mode: Mode) -> *mut core::ffi::c_void;
    #[link_name = "dlsym"]
    pub fn dlsym(handle: *mut core::ffi::c_void, symbol: *const core::ffi::c_char)
        -> *mut core::ffi::c_void;
    #[link_name = "dlclose"]
    pub fn dlclose(handle: *mut core::ffi::c_void) -> core::ffi::c_int;
}
