//! Debug facility, mirroring ocl_icd_debug.h exactly:
//! OCL_ICD_DEBUG is parsed with atoi (DECIMAL) semantics:
//!   unset          -> mask 0    (silent, except D_ALWAYS)
//!   empty string   -> mask 1    (D_ALWAYS: "always" messages)
//!   numeric        -> bitmask   D_WARN=1 D_LOG=2 D_TRACE=4 D_DUMP=8
//! OCL_ICD_FILENAME additionally tags lines with the source file.
use core::ffi::c_void;
use std::sync::OnceLock;

pub const D_ALWAYS: u32 = 0;
pub const D_WARN: u32 = 0x01;
pub const D_LOG: u32 = 0x02;
pub const D_TRACE: u32 = 0x04;
pub const D_DUMP: u32 = 0x08;

static MASK: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(u32::MAX); // MAX = "not yet read"
static SHOW_FILE: OnceLock<bool> = OnceLock::new();

pub fn mask() -> u32 {
    let cur = MASK.load(std::sync::atomic::Ordering::Relaxed);
    if cur != u32::MAX {
        return cur;
    }
    let v = match std::env::var("OCL_ICD_DEBUG") {
        Err(_) => 0,
        Ok(s) => {
            let s = s.trim_start();
            if s.is_empty() {
                1 // atoi("") == 0, C then substitutes 1 (D_ALWAYS)
            } else {
                // atoi: leading decimal run, tolerate trailing junk.
                let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
                digits.parse().unwrap_or(0)
            }
        }
    };
    MASK.store(v, std::sync::atomic::Ordering::Relaxed);
    v
}

/// C manipulates debug_ocl_icd_mask directly around dump_platform; mirror it.
pub fn set_mask(v: u32) {
    MASK.store(v, std::sync::atomic::Ordering::Relaxed);
}

pub fn dbg(bit: u32, args: std::fmt::Arguments) {
    if bit == D_ALWAYS || mask() & bit != 0 {
        if *SHOW_FILE.get_or_init(|| std::env::var("OCL_ICD_FILENAME").is_ok()) {
            eprintln!("ocl-icd-rs [{}]: {}", file!(), args);
        } else {
            eprintln!("ocl-icd-rs: {}", args);
        }
    }
}

#[macro_export]
macro_rules! debug {
    ($bit:expr, $($arg:tt)*) => { $crate::debug::dbg($bit, format_args!($($arg)*)) };
}

/// dlsym(RTLD_DEFAULT) -- C's dump_field evaluates the symbol this way.
pub fn dlsym_default(name: &str) -> *mut c_void {
    let cname = match std::ffi::CString::new(name) {
        Ok(c) => c,
        Err(_) => return core::ptr::null_mut(),
    };
    unsafe { crate::clib::dlsym(crate::clib::RTLD_DEFAULT, cname.as_ptr()) }
}

/// Address of a raw symbol in a dlopen'd handle (dlsym).
pub fn dlsym_addr(handle: *mut c_void, name: &str) -> *mut c_void {
    let cname = match std::ffi::CString::new(name) {
        Ok(c) => c,
        Err(_) => return core::ptr::null_mut(),
    };
    // SAFETY: handle comes from dlopen; cname is NUL-terminated.
    unsafe { crate::clib::dlsym(handle, cname.as_ptr()) }
}
