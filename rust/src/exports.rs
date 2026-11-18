//! Exported loader entry points. Rust port of the dispatch bodies in
//! ocl_icd_loader.c: deinit state first, then layer chain, then per-object
//! ICD dispatch. Generated generic entry points live in gen_forwarders.rs.
use crate::debug::{D_LOG, D_WARN};
#[allow(unused_imports)]
use crate::debug::D_TRACE;
use crate::dispatch::{object_dispatch, slot_fn, TableCell, NUM_DISPATCH_SLOTS};
use crate::registry::{init, registry};
use crate::types::*;
use core::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

#[allow(unused_imports)]
use crate::debug;

pub static DEINIT: AtomicBool = AtomicBool::new(false);
pub static DEINITING: AtomicBool = AtomicBool::new(false);

/// Uniform usize-register marshalling of one entry-point argument (all
/// OpenCL args are pointers or integers; the 6-slot extern "C" trampoline is
/// ABI-correct on LP64).
pub fn marshal_arg<T>(x: &T) -> usize {
    let mut b = [0u8; 8];
    let n = core::mem::size_of::<T>().min(8);
    unsafe { std::ptr::copy_nonoverlapping(x as *const T as *const u8, b.as_mut_ptr(), n) };
    u64::from_le_bytes(b) as usize
}

/// Entry-point wrapper used by the generated forwarders (same semantics as
/// `entry!`, macro-exported so gen_forwarders.rs can invoke it).
#[macro_export]
macro_rules! gen_entry {
    ($name:ident, $slot:expr, $rt:ty, ($($argn:ident : $argt:ty),*), [$($padn:ident),*], $body:path) => {
        #[no_mangle]
        pub extern "C" fn $name($($argn: $argt),* $(, $padn: usize)*) -> $rt {
            $crate::debug::dbg($crate::debug::D_TRACE, format_args!("-> {}", stringify!($name)));
            if $crate::exports::DEINIT.load(std::sync::atomic::Ordering::Acquire) {
                type __F = unsafe extern "C" fn(usize, ...) -> usize;
                let __fp = unsafe { *$crate::exports::deinit_dispatch_table().add($slot) };
                if !__fp.is_null() {
                    let __f: __F = unsafe { std::mem::transmute(__fp) };
                    let mut __it = [$($crate::exports::marshal_arg(&$argn),)* $($crate::exports::marshal_arg(&$padn),)*];
                    let __r = unsafe { __f(__it[0], __it[1], __it[2], __it[3], __it[4], __it[5], __it[6], __it[7], __it[8], __it[9]) };
                    return unsafe { std::mem::transmute_copy::<usize, $rt>(&__r) };
                }
                return unsafe { std::mem::zeroed::<$rt>() };
            }
            $crate::registry::init();
            if let Some(reg) = $crate::registry::registry() {
                if let Some(layer) = reg.layers.first() {
                    let __fp = layer.table.slots[$slot];
                    if !__fp.is_null() {
                        type __F = unsafe extern "C" fn(usize, ...) -> usize;
                        let __f: __F = unsafe { std::mem::transmute(__fp) };
                        let mut __it = [$($crate::exports::marshal_arg(&$argn),)* $($crate::exports::marshal_arg(&$padn),)*];
                    let __r = unsafe { __f(__it[0], __it[1], __it[2], __it[3], __it[4], __it[5], __it[6], __it[7], __it[8], __it[9]) };
                        return unsafe { std::mem::transmute_copy::<usize, $rt>(&__r) };
                    }
                }
            }
            debug!($crate::debug::D_TRACE, "-> {}", stringify!($name));
            unsafe { $body($($argn),*) }
        }
    };
}

/// Shared entry-point trampoline: deinit state -> first layer -> body.
/// Used by the hand-written specials; gen_forwarders.rs defines its own
/// `gen_entry!` with the same semantics for the generated set.
macro_rules! entry {
    ($name:ident, $slot:expr, $rt:ty, ($($argn:ident : $argt:ty),*), [$($padn:ident),*], $body:path) => {
        #[no_mangle]
        pub extern "C" fn $name($($argn: $argt),* $(, $padn: usize)*) -> $rt {
            $crate::debug::dbg($crate::debug::D_TRACE, format_args!("-> {}", stringify!($name)));
            if $crate::exports::DEINIT.load(std::sync::atomic::Ordering::Acquire) {
                type __F = unsafe extern "C" fn(usize, ...) -> usize;
                let __fp = unsafe { *$crate::exports::deinit_dispatch_table().add($slot) };
                if !__fp.is_null() {
                    let __f: __F = unsafe { std::mem::transmute(__fp) };
                    let mut __it = [$($crate::exports::marshal_arg(&$argn),)* $($crate::exports::marshal_arg(&$padn),)*];
                    let __r = unsafe { __f(__it[0], __it[1], __it[2], __it[3], __it[4], __it[5], __it[6], __it[7], __it[8], __it[9]) };
                    return unsafe { std::mem::transmute_copy::<usize, $rt>(&__r) };
                }
                return unsafe { std::mem::zeroed::<$rt>() };
            }
            $crate::registry::init();
            if let Some(reg) = $crate::registry::registry() {
                if let Some(layer) = reg.layers.first() {
                    let __fp = layer.table.slots[$slot];
                    if !__fp.is_null() {
                        type __F = unsafe extern "C" fn(usize, ...) -> usize;
                        let __f: __F = unsafe { std::mem::transmute(__fp) };
                        let mut __it = [$($crate::exports::marshal_arg(&$argn),)* $($crate::exports::marshal_arg(&$padn),)*];
                    let __r = unsafe { __f(__it[0], __it[1], __it[2], __it[3], __it[4], __it[5], __it[6], __it[7], __it[8], __it[9]) };
                        return unsafe { std::mem::transmute_copy::<usize, $rt>(&__r) };
                    }
                }
            }
            debug!($crate::debug::D_TRACE, "-> {}", stringify!($name));
            unsafe { $body($($argn),*) }
        }
    };
}

unsafe fn write_string(s: &str, size: usize, value: *mut c_void, size_ret: *mut usize) -> cl_int {
    let need = s.len() + 1;
    if !value.is_null() {
        if size < need {
            return CL_INVALID_VALUE;
        }
        std::ptr::copy_nonoverlapping(s.as_ptr(), value as *mut u8, s.len());
        (value as *mut u8).add(s.len()).write(0);
    }
    if !size_ret.is_null() {
        *size_ret = need;
    }
    CL_SUCCESS
}

/// 8-byte LE-ordered bit pattern of a by-value arg (u64/flags), for uniform
/// marshalling through usize registers.
pub fn val<T: Copy>(x: &T) -> usize {
    let mut b = [0u8; 8];
    let n = core::mem::size_of::<T>().min(8);
    unsafe { std::ptr::copy_nonoverlapping(x as *const T as *const u8, b.as_mut_ptr(), n) };
    u64::from_le_bytes(b) as usize
}

/// Uniform 6-register trampoline call into a dispatch slot (usize marshalled).
/// NULL slot -> 0 (NULL pointer / CL-shaped nothing).
pub unsafe fn call_by_slot(table: *mut *mut c_void, slot: usize, args: &[usize]) -> usize {
    call_by_slot_n(table, slot, args, args.len())
}

pub unsafe fn call_by_slot_void(table: *mut *mut c_void, slot: usize, args: &[usize]) {
    let _ = call_by_slot(table, slot, args);
}

pub unsafe fn call_by_slot_n(table: *mut *mut c_void, slot: usize, args: &[usize], nargs: usize) -> usize {
    let f = slot_fn(table, slot);
    if f.is_null() {
        return 0;
    }
    // 10 general-purpose registers on LP64: pass the whole prefix, zero-pad
    // the rest. Functions with >10 args have stack-carried ones we cannot
    // marshal from a slice length alone (documented limitation).
    type F = unsafe extern "C" fn(usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) -> u64;
    let mut a = [0usize; 10];
    let n = nargs.min(args.len()).min(10);
    a[..n].copy_from_slice(&args[..n]);
    let f: F = std::mem::transmute(f);
    f(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]) as usize
}

/// The dispatch table for a platform handle. Generated entry points resolve
/// NULL -> default platform id BEFORE this call (selectPlatformID fidelity);
/// a NULL that reaches here (hand-written specials) still maps to default.
pub unsafe fn platform_dispatch_table(pid: cl_platform_id) -> Option<*mut *mut c_void> {
    let reg = registry()?;
    if pid.is_null() {
        return reg.default_platform().map(|p| reg.platform_table(p));
    }
    reg.find_platform(pid).map(|p| reg.platform_table(p))
}

/// getDefaultPlatformID(): the pid a vendor call should see when the app
/// passed NULL (generated entries resolve this before marshalling).
pub fn default_platform_id() -> Option<cl_platform_id> {
    registry().and_then(|r| r.default_platform_id())
}

/// Table handed to layers: the loader's own `_disp` dispatch.
pub fn loader_dispatch_table() -> *const *mut c_void {
    LOADER_TABLE
        .get_or_init(|| {
            let mut t = TableCell::new();
            for i in 0..NUM_DISPATCH_SLOTS {
                t.0[i] = crate::gen::gen_slot_disp(i);
            }
            t
        })
        .0
        .as_ptr() as *const *mut c_void
}

static LOADER_TABLE: OnceLock<TableCell> = OnceLock::new();

/// Post-deinit dispatch (C: `deinit_dispatch`): every slot routes to an
/// `_unsupp` stub.
pub fn deinit_dispatch_table() -> *const *mut c_void {
    DEINIT_TABLE
        .get_or_init(|| {
            let mut t = TableCell::new();
            for i in 0..NUM_DISPATCH_SLOTS {
                t.0[i] = crate::gen::gen_slot_unsupp(i);
            }
            t.0[0] = clGetPlatformIDs_unsupp as *mut c_void;
            t
        })
        .0
        .as_ptr() as *const *mut c_void
}

static DEINIT_TABLE: OnceLock<TableCell> = OnceLock::new();

extern "C" fn clGetPlatformIDs_unsupp(
    _a0: usize, _a1: usize, _a2: usize, _a3: usize, _a4: usize, _a5: usize,
) -> cl_int {
    CL_PLATFORM_NOT_FOUND_KHR
}

// ─────────────────────── loader-specific bodies ───────────────────────

pub unsafe fn clGetPlatformIDs_body(
    num_entries: cl_uint,
    platforms: *mut cl_platform_id,
    num_platforms: *mut cl_uint,
) -> cl_int {
    if platforms.is_null() && num_platforms.is_null() {
        return CL_INVALID_VALUE;
    }
    if num_entries == 0 && !platforms.is_null() {
        return CL_INVALID_VALUE;
    }
    let reg = match registry() {
        Some(r) => r,
        None => {
            if !num_platforms.is_null() {
                *num_platforms = 0;
            }
            return CL_PLATFORM_NOT_FOUND_KHR;
        }
    };
    if reg.platforms.is_empty() {
        if !num_platforms.is_null() {
            *num_platforms = 0;
        }
        return CL_PLATFORM_NOT_FOUND_KHR;
    }
    if !num_platforms.is_null() {
        *num_platforms = reg.platforms.len() as cl_uint;
    }
    if !platforms.is_null() {
        let n = reg.platforms.len().min(num_entries as usize);
        for i in 0..n {
            *platforms.add(i) = reg.platforms[i].pid;
        }
    }
    CL_SUCCESS
}

unsafe fn clGetPlatformInfo_body(
    platform: cl_platform_id,
    param_name: cl_platform_info,
    size: usize,
    value: *mut c_void,
    size_ret: *mut usize,
) -> cl_int {
    // selectPlatformID: the vendor must see the RESOLVED platform, not NULL.
    let platform = if platform.is_null() {
        match default_platform_id() {
            Some(p) => p,
            None => return CL_INVALID_PLATFORM,
        }
    } else {
        platform
    };
    match platform_dispatch_table(platform) {
        Some(t) => call_by_slot(
            t,
            1,
            &[platform as usize, param_name as usize, size, value as usize, size_ret as usize],
        ) as cl_int,
        None => CL_INVALID_PLATFORM,
    }
}

/// Find the CL_CONTEXT_PLATFORM property value in a properties array.
unsafe fn platform_from_properties(properties: *const cl_context_properties) -> Option<cl_platform_id> {
    if properties.is_null() {
        return None;
    }
    let mut i = 0usize;
    loop {
        let p = *properties.add(i);
        if p == 0 {
            break;
        }
        if p == CL_CONTEXT_PLATFORM {
            return Some(*properties.add(i + 1) as *mut c_void);
        }
        i += 2;
    }
    None
}

unsafe fn clCreateContext_body(
    properties: *const cl_context_properties,
    num_devices: cl_uint,
    devices: *const cl_device_id,
    pfn_notify: *mut c_void,
    user_data: *mut c_void,
    errcode_ret: *mut cl_int,
) -> cl_context {
    if let Some(plat) = platform_from_properties(properties) {
        if plat.is_null() {
            if !errcode_ret.is_null() {
                *errcode_ret = CL_INVALID_PLATFORM;
            }
            return core::ptr::null_mut();
        }
        match platform_dispatch_table(plat) {
            Some(t) => call_by_slot(
                t,
                4,
                &[properties as usize, num_devices as usize, devices as usize, pfn_notify as usize, user_data as usize, errcode_ret as usize],
            ) as *mut c_void,
            None => {
                if !errcode_ret.is_null() {
                    *errcode_ret = CL_INVALID_PLATFORM;
                }
                core::ptr::null_mut()
            }
        }
    } else if devices.is_null() || num_devices == 0 {
        if !errcode_ret.is_null() {
            *errcode_ret = CL_INVALID_VALUE;
        }
        core::ptr::null_mut()
    } else if (*devices).is_null() {
        if !errcode_ret.is_null() {
            *errcode_ret = CL_INVALID_DEVICE;
        }
        core::ptr::null_mut()
    } else {
        let t = object_dispatch(*devices);
        call_by_slot(
            t,
            4,
            &[properties as usize, num_devices as usize, devices as usize, pfn_notify as usize, user_data as usize, errcode_ret as usize],
        ) as *mut c_void
    }
}

unsafe fn clCreateContextFromType_body(
    properties: *const cl_context_properties,
    device_type: cl_device_type,
    pfn_notify: *mut c_void,
    user_data: *mut c_void,
    errcode_ret: *mut cl_int,
) -> cl_context {
    let t = match platform_from_properties(properties) {
        Some(plat) => {
            if plat.is_null() {
                if !errcode_ret.is_null() {
                    *errcode_ret = CL_INVALID_PLATFORM;
                }
                return core::ptr::null_mut();
            }
            platform_dispatch_table(plat)
        }
        None => platform_dispatch_table(core::ptr::null_mut()),
    };
    match t {
        Some(t) => call_by_slot(
            t,
            5,
            &[properties as usize, val(&device_type), pfn_notify as usize, user_data as usize, errcode_ret as usize, 0],
        ) as *mut c_void,
        None => {
            if !errcode_ret.is_null() {
                *errcode_ret = CL_INVALID_PLATFORM;
            }
            core::ptr::null_mut()
        }
    }
}

unsafe fn clWaitForEvents_body(num_events: cl_uint, event_list: *const cl_event) -> cl_int {
    if event_list.is_null() || num_events == 0 {
        return CL_INVALID_EVENT_WAIT_LIST;
    }
    let e0 = *event_list;
    if e0.is_null() {
        return CL_INVALID_EVENT;
    }
    call_by_slot(object_dispatch(e0), 41, &[num_events as usize, event_list as usize, 0, 0, 0, 0]) as cl_int
}

unsafe fn clGetGLContextInfoKHR_body(
    properties: *const cl_context_properties,
    param_name: u32,
    size: usize,
    value: *mut c_void,
    size_ret: *mut usize,
) -> cl_int {
    match platform_from_properties(properties) {
        Some(plat) if !plat.is_null() => match platform_dispatch_table(plat) {
            Some(t) => call_by_slot(
                t,
                74,
                &[properties as usize, param_name as usize, size, value as usize, size_ret as usize, 0],
            ) as cl_int,
            None => CL_INVALID_PLATFORM,
        },
        _ => CL_INVALID_PLATFORM,
    }
}

// ─────────────────────── exported specials ───────────────────────

entry!(clGetPlatformIDs, 0, cl_int, (num_entries: cl_uint,  platforms: *mut cl_platform_id,  num_platforms: *mut cl_uint), [__pad0,__pad1,__pad2,__pad3,__pad4,__pad5,__pad6], clGetPlatformIDs_disp);
entry!(clGetPlatformInfo, 1, cl_int, (platform: cl_platform_id,  param_name: cl_platform_info,  param_value_size: usize,  param_value: *mut c_void,  param_value_size_ret: *mut usize), [__pad0,__pad1,__pad2,__pad3,__pad4], clGetPlatformInfo_disp);
entry!(clCreateContext, 4, cl_context, (properties: *const cl_context_properties,  num_devices: cl_uint,  devices: *const cl_device_id,  pfn_notify: *mut c_void,  user_data: *mut c_void,  errcode_ret: *mut cl_int), [__pad0,__pad1,__pad2,__pad3], clCreateContext_disp);
entry!(clCreateContextFromType, 5, cl_context, (properties: *const cl_context_properties,  device_type: cl_device_type,  pfn_notify: *mut c_void,  user_data: *mut c_void,  errcode_ret: *mut cl_int), [__pad0,__pad1,__pad2,__pad3,__pad4], clCreateContextFromType_disp);
entry!(clWaitForEvents, 41, cl_int, (num_events: cl_uint,  event_list: *const cl_event), [__pad0,__pad1,__pad2,__pad3,__pad4,__pad5,__pad6,__pad7], clWaitForEvents_disp);
entry!(clGetGLContextInfoKHR, 74, cl_int, (properties: *const cl_context_properties,  param_name: u32,  param_value_size: usize,  param_value: *mut c_void,  param_value_size_ret: *mut usize), [__pad0,__pad1,__pad2,__pad3,__pad4], clGetGLContextInfoKHR_disp);

macro_rules! plain {
    ($name:ident, $body:path, ($($argn:ident : $argt:ty),*) -> $ret:ty) => {
        pub unsafe extern "C" fn $name($($argn: $argt),*) -> $ret { unsafe { $body($($argn),*) } }
    };
}

plain!(clGetPlatformIDs_disp, clGetPlatformIDs_body, (num_entries: cl_uint, platforms: *mut cl_platform_id, num_platforms: *mut cl_uint) -> cl_int);
plain!(clGetPlatformInfo_disp, clGetPlatformInfo_body, (platform: cl_platform_id, param_name: cl_platform_info, param_value_size: usize, param_value: *mut c_void, param_value_size_ret: *mut usize) -> cl_int);
plain!(clCreateContext_disp, clCreateContext_body, (properties: *const cl_context_properties, num_devices: cl_uint, devices: *const cl_device_id, pfn_notify: *mut c_void, user_data: *mut c_void, errcode_ret: *mut cl_int) -> cl_context);
plain!(clCreateContextFromType_disp, clCreateContextFromType_body, (properties: *const cl_context_properties, device_type: cl_device_type, pfn_notify: *mut c_void, user_data: *mut c_void, errcode_ret: *mut cl_int) -> cl_context);
plain!(clWaitForEvents_disp, clWaitForEvents_body, (num_events: cl_uint, event_list: *const cl_event) -> cl_int);
plain!(clGetGLContextInfoKHR_disp, clGetGLContextInfoKHR_body, (properties: *const cl_context_properties, param_name: u32, param_value_size: usize, param_value: *mut c_void, param_value_size_ret: *mut usize) -> cl_int);

/// Not a loader export: in the C loader this is a plain `static`, reachable
/// only through clGetExtensionFunctionAddress. Exporting it PUBLICLY lets a
/// vendor dlsym(RTLD_DEFAULT) find it and branch on our identity strings -
/// the NVIDIA driver visibly changes its CL_DEVICE_LUID_KHR write behaviour
/// when it does (leaves the low half of the buffer untouched). Keep it hidden.
extern "C" fn clGetICDLoaderInfoOCLICD(
    param_name: cl_icdl_info,
    param_value_size: usize,
    param_value: *mut c_void,
    param_value_size_ret: *mut usize,
) -> cl_int {
    // Drop-in identity: byte-identical to the C loader's four strings, which
    // the upstream testsuite pins (tests/testsuite-standard.at "ICD Loader
    // extension"). version follows the packaged ocl-icd VERSION via build.rs
    // (env OCL_ICD_RS_VERSION override), NOT the crate version.
    let s: &str = match param_name {
        CL_ICDL_OCL_VERSION => "OpenCL 3.1",
        CL_ICDL_VERSION => env!("OCL_ICD_VERSION"),
        CL_ICDL_NAME => "OpenCL ICD Loader",
        CL_ICDL_VENDOR => "OCL Icd free software",
        _ => return CL_INVALID_VALUE,
    };
    match unsafe { write_string(s, param_value_size, param_value, param_value_size_ret) } {
        CL_SUCCESS => CL_SUCCESS,
        _ => CL_INVALID_VALUE,
    }
}

#[no_mangle]
pub extern "C" fn clIcdGetPlatformIDsKHR(
    num_entries: cl_uint,
    platforms: *mut cl_platform_id,
    num_platforms: *mut cl_uint,
) -> cl_int {
    init();
    if DEINIT.load(Ordering::Acquire) {
        return CL_PLATFORM_NOT_FOUND_KHR;
    }
    unsafe { clGetPlatformIDs_body(num_entries, platforms, num_platforms) }
}

#[no_mangle]
pub extern "C" fn clGetExtensionFunctionAddress(func_name: *const core::ffi::c_char) -> *mut c_void {
    init();
    if DEINIT.load(Ordering::Acquire) {
        return core::ptr::null_mut();
    }
    unsafe { ext_addr_disp(func_name) }
}

pub unsafe extern "C" fn clGetExtensionFunctionAddress_disp(func_name: *const core::ffi::c_char) -> *mut c_void {
    init();
    ext_addr_disp(func_name)
}

unsafe fn ext_addr_disp(func_name: *const core::ffi::c_char) -> *mut c_void {
    if func_name.is_null() {
        return core::ptr::null_mut();
    }
    let name = match std::ffi::CStr::from_ptr(func_name).to_str() {
        Ok(s) => s,
        Err(_) => return core::ptr::null_mut(),
    };
    // C order: function_description table (KHR/EXT-suffixed names only),
    // then suffix-matched vendor lookup, then the OCLICD fallback last.
    // C order: the function_description table is consulted only for
    // KHR/EXT-suffixed names; the vendor suffix loop runs for EVERY name.
    if name.len() > 3 && (name.ends_with("KHR") || name.ends_with("EXT")) {
        if let Some(a) = crate::gen::func_desc_lookup(name) {
            return a;
        }
    }
    if name == "clDeinitCompound" {
        return clDeinitCompound as *mut c_void;
    }
    if let Some(reg) = registry() {
        // Suffix match against every platform's ICD, as in the C loader
        // (ungated: any name can end with a platform's ICD suffix).
        {
            // C: RETURN on the FIRST platform whose suffix matches (a bare
            // return inside the loop) -- never probes further vendors.
            for p in &reg.platforms {
                if !p.suffix.is_empty() && name.ends_with(p.suffix.as_str()) {
                    if let Some(v) = reg.vendors[p.vendor_idx].ext_fn_ptr {
                        let cname = match std::ffi::CString::new(name) {
                            Ok(c) => c,
                            Err(_) => return core::ptr::null_mut(),
                        };
                        return v(cname.as_ptr());
                    }
                    return core::ptr::null_mut();
                }
            }
        }
    }
    if name == "clGetICDLoaderInfoOCLICD" {
        // C fallback, kept last (and the fn itself hidden, like its static)
        return clGetICDLoaderInfoOCLICD as *mut c_void;
    }
    core::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn clUnloadCompiler() -> cl_int {
    if DEINIT.load(Ordering::Acquire) {
        return CL_INVALID_OPERATION;
    }
    CL_SUCCESS
}
pub unsafe extern "C" fn clUnloadCompiler_disp() -> cl_int {
    clUnloadCompiler()
}

#[no_mangle]
pub extern "C" fn clUnloadPlatformCompiler(platform: cl_platform_id) -> cl_int {
    if DEINIT.load(Ordering::Acquire) {
        return CL_INVALID_OPERATION;
    }
    unsafe { clUnloadPlatformCompiler_disp(platform) }
}
/// C: generated body — selectPlatformID, vendor dispatch slot 100, and the
/// loader's own _unsupp fallback when the platform's table has no entry.
pub unsafe extern "C" fn clUnloadPlatformCompiler_disp(platform: cl_platform_id) -> cl_int {
    let platform = if platform.is_null() {
        match default_platform_id() {
            Some(p) => p,
            None => return CL_INVALID_PLATFORM,
        }
    } else {
        platform
    };
    match platform_dispatch_table(platform) {
        Some(t) => {
            let f = crate::dispatch::slot_fn(t, 100);
            if f.is_null() {
                return CL_INVALID_OPERATION;
            }
            let f: unsafe extern "C" fn(cl_platform_id) -> cl_int = std::mem::transmute(f);
            f(platform)
        }
        None => CL_INVALID_PLATFORM,
    }
}

// ─────────────────────── deinitialization ───────────────────────
// Port of _deinitClIcd_no_inline + ocl_icd_destructor.

#[no_mangle]
pub extern "C" fn clDeinitCompound() -> cl_int {
    unsafe { deinit_compound_body() }
}

pub unsafe fn deinit_compound_body() -> cl_int {
    if DEINITING.swap(true, Ordering::AcqRel) {
        return CL_SUCCESS; // already being torn down
    }
    if crate::registry::env_flag("OCL_ICD_FORCE_LEGACY_TERMINATION") {
        DEINITING.store(false, Ordering::Release);
        debug!(D_WARN, "Loader termination disabled (OCL_ICD_FORCE_LEGACY_TERMINATION)");
        return CL_SUCCESS;
    }
    debug!(D_LOG, "Terminating loader");
    DEINIT.store(true, Ordering::Release);

    if let Some(reg) = registry() {
        let disable_unload = crate::registry::env_flag("OCL_ICD_DISABLE_DYNAMIC_LIBRARY_UNLOADING");
        // Layers: clDeinitLayer, then dlclose (reverse order of loading).
        for layer in reg.layers.iter().rev() {
            if let Some(f) = layer.deinit_fn {
                let err = f();
                if err != CL_SUCCESS {
                    debug!(D_WARN, "Layer deinit returned error {}", err);
                }
            }
            if !disable_unload {
                crate::clib::dlclose(layer.dl_handle);
            }
        }
        // ICDs: one dlclose per platform that was marked unloadable — vendors
        // whose last unloadable platform goes down reach refcount 0 and are
        // genuinely unmapped (dlclose is refcounted; our own base ref from
        // dlopen keeps the rest alive, matching the C bookkeeping).
        for p in &reg.platforms {
            if p.unloadable != CL_FALSE && !disable_unload {
                crate::clib::dlclose(reg.vendors[p.vendor_idx].dl_handle);
            }
        }
        // C: free(_picds[i].extension_suffix/disp_data), free(_picds),
        // free(_icds) -- drop all registry-owned heap before returning.
        reg.release();
    }
    CL_SUCCESS
}

// The library's own destructor (C: ocl_icd_destructor). Runs when the loader
// is dlclosed; deliberately NOT registered as atexit, so a normal process
// exit skips unloading vendor code (prototype choice; avoids racing other
// libraries' destructors).
#[used]
#[link_section = ".fini_array"]
static DESTRUCTOR: unsafe extern "C" fn() = destructor_fn;

unsafe extern "C" fn destructor_fn() {
    // Mirror C: ocl_icd_destructor skips teardown entirely when __initClIcd
    // never ran (no registry built). Printing/closing in an untouched
    // process is observable stderr noise vs the reference loader.
    if crate::registry::was_initialized() && !DEINIT.load(Ordering::Acquire) {
        clDeinitCompound();
    }
}


