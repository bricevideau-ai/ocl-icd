//! ICD and layer discovery + registration. Rust port of the vendor-scan and
//! platform-registration half of ocl_icd_loader.c (__initClIcd /
//! _find_and_check_platforms / __initLayer).
use crate::debug::{dlsym_addr, D_DUMP, D_LOG, D_WARN};
use crate::dispatch::{has_icd2_tag, new_tagged_table, DispTable, NUM_DISPATCH_SLOTS};
use crate::types::*;
use core::ffi::c_void;
use std::sync::OnceLock;

const ICD_EXTENSION: &str = ".icd";
const LAY_EXTENSION: &str = ".lay";

pub type ExtFnAddr = unsafe extern "C" fn(*const core::ffi::c_char) -> *mut c_void;
pub type IcdGetAddrForPlatform =
    unsafe extern "C" fn(cl_platform_id, *const core::ffi::c_char) -> *mut c_void;
pub type IcdSetPlatformDispatchData = unsafe extern "C" fn(cl_platform_id, *mut c_void) -> cl_int;
pub type IcdGetPlatformIDs =
    unsafe extern "C" fn(cl_uint, *mut cl_platform_id, *mut cl_uint) -> cl_int;
pub type GetPlatformInfo =
    unsafe extern "C" fn(cl_platform_id, cl_platform_info, usize, *mut c_void, *mut usize) -> cl_int;
pub type GetDeviceIDs =
    unsafe extern "C" fn(cl_platform_id, cl_device_type, cl_uint, *mut cl_device_id, *mut cl_uint) -> cl_int;
#[allow(dead_code)]
pub type InitLayer = unsafe extern "C" fn(
    cl_uint,
    *const *mut c_void,
    *mut cl_uint,
    *mut *const *mut c_void,
) -> cl_int;

pub struct VendorIcd {
    pub path: String,
    pub dl_handle: *mut c_void,
    /// clGetExtensionFunctionAddress (dlsym'd from the ICD).
    pub ext_fn_ptr: Option<ExtFnAddr>,
    pub num_platforms: cl_uint,
}

pub struct PlatformIcd {
    pub vendor_idx: usize,
    pub pid: cl_platform_id,
    pub suffix: String,
    pub ngpus: cl_uint,
    pub ncpus: cl_uint,
    pub ndevs: cl_uint,
    pub unloadable: cl_bool,
    /// Loader-managed ICD2 dispatch data (Box kept alive by REGISTRY).
    pub disp_data: Option<Box<DispTable>>,
}

pub type DeinitLayerFn = unsafe extern "C" fn() -> cl_int;

pub struct LayerIcd {
    pub dl_handle: *mut c_void,
    pub table: Box<DispTable>,
    pub deinit_fn: Option<DeinitLayerFn>,
}

pub struct Registry {
    pub vendors: Vec<VendorIcd>,
    pub platforms: Vec<PlatformIcd>,
    pub layers: Vec<LayerIcd>,
    pub ok: bool,
}

pub static REGISTRY: OnceLock<Registry> = OnceLock::new();

/// True once the registry has been built (i.e. any init path ran).
pub fn was_initialized() -> bool {
    REGISTRY.get().is_some()
}

// SAFETY: Registry contents are constructed once inside OnceLock and frozen.
unsafe impl Send for Registry {}
unsafe impl Sync for Registry {}

thread_local! {
    /// Set while this thread is inside build_registry (a layer calling back
    /// into the loader during clInitLayer must not re-enter init).
    static IN_INIT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Loader entry point: init exactly once. Returns None while the current
/// thread is itself performing initialization (re-entrant layer call).
pub fn init() -> Option<&'static Registry> {
    if crate::exports::DEINIT.load(std::sync::atomic::Ordering::Acquire) {
        return registry();
    }
    let busy = IN_INIT.with(|f| f.get());
    if busy {
        return registry();
    }
    IN_INIT.with(|f| f.set(true));
    let r = REGISTRY.get_or_init(|| unsafe { build_registry() });
    IN_INIT.with(|f| f.set(false));
    Some(r)
}

/// The registry, iff initialized (never None after the first successful
/// init(); also None post-deinit only in the sense that contents are frozen).
pub fn registry() -> Option<&'static Registry> {
    REGISTRY.get()
}

pub fn env_flag(name: &str) -> bool {
    env_true(name)
}

/// Introspection for tests: did any registered platform advertise
/// cl_khr_icd_unloadable (i.e. will deinit dlclose its vendor)?
#[no_mangle]
pub extern "C" fn ocl_icd_rs_test_has_unloadable() -> cl_uint {
    match REGISTRY.get() {
        Some(r) => r.platforms.iter().filter(|p| p.unloadable != 0).count() as cl_uint,
        None => 0,
    }
}

// ────────────────────────────── discovery ──────────────────────────────

fn env_true(name: &str) -> bool {
    match std::env::var(name) {
        Ok(v) => !v.is_empty() && v != "0",
        Err(_) => false,
    }
}

fn assume_icd_extension() -> bool {
    matches!(std::env::var("OCL_ICD_ASSUME_ICD_EXTENSION"), Ok(v) if !v.is_empty())
}

fn ends_with_icd(name: &str) -> bool {
    name.ends_with(ICD_EXTENSION)
}

/// Load one candidate path with dlopen. Returns the handle on success.
fn load_icd(path: &str) -> *mut c_void {
    debug!(D_LOG, "Loading ICD '{}'", path);
    let cpath = match std::ffi::CString::new(path) {
        Ok(c) => c,
        Err(_) => return core::ptr::null_mut(),
    };
    // SAFETY: RTLD_LAZY|RTLD_LOCAL as in the C loader; we never dlclose.
    let h = unsafe { crate::clib::dlopen(cpath.as_ptr(), crate::clib::RTLD_LAZY | crate::clib::RTLD_LOCAL) };
    if h.is_null() {
        debug!(D_WARN, "error while dlopening: '{}' => skipping ICD", path);
    }
    h
}

/// Resolve a function in an ICD: dlsym first, then clGetExtensionFunctionAddress,
/// preferring the latter — exactly `_get_function_addr` in C.
unsafe fn get_function_addr(dlh: *mut c_void, ext: Option<ExtFnAddr>, name: &str) -> *mut c_void {
    let cname = match std::ffi::CString::new(name) {
        Ok(c) => c,
        Err(_) => return core::ptr::null_mut(),
    };
    let addr1 = crate::clib::dlsym(dlh, cname.as_ptr());
    let addr2 = match ext {
        Some(f) => f(cname.as_ptr()),
        None => core::ptr::null_mut(),
    };
    if addr2.is_null() {
        addr1
    } else {
        addr2
    }
}

/// Open one `.icd` file (a text file naming the vendor library) in `dir_path`.
unsafe fn open_driver(candidates: &mut Vec<*mut c_void>, dir_path: Option<&str>, file: &str) {
    let full = match dir_path {
        Some(d) => format!("{}/{}", d, file),
        None => file.to_string(),
    };
    debug!(D_LOG, "Considering file '{}'", full);
    let contents = match std::fs::read_to_string(&full) {
        Ok(c) => c,
        Err(_) => return,
    };
    let libname = match contents.lines().next() {
        Some(l) => l.trim_end().to_string(),
        None => String::new(),
    };
    if libname.is_empty() {
        debug!(D_WARN, "File contents too short, skipping ICD");
        return;
    }
    let h = load_icd(&libname);
    if !h.is_null() {
        candidates.push(h);
    }
}

/// Port of `__initClIcd`: collect dlopen'd vendor handles from
/// OCL_ICD_FILENAMES, then the vendor directory (OPENCL_VENDOR_PATH or
/// OCL_ICD_VENDORS, default /etc/OpenCL/vendors).
unsafe fn discover_vendors() -> Vec<*mut c_void> {
    let mut handles = Vec::new();

    if let Ok(filenames) = std::env::var("OCL_ICD_FILENAMES") {
        debug!(D_LOG, "OCL_ICD_FILENAMES set to '{}'", filenames);
        for entry in filenames.split(':').filter(|s| !s.is_empty()) {
            let h = load_icd(entry);
            if !h.is_null() {
                handles.push(h);
            }
        }
    }

    let vendor_path = std::env::var("OPENCL_VENDOR_PATH")
        .unwrap_or_else(|_| "/etc/OpenCL/vendors".into());
    let vendor_path = if vendor_path.is_empty() {
        "/etc/OpenCL/vendors".to_string()
    } else {
        vendor_path
    };
    let vendors_set = std::env::var("OCL_ICD_VENDORS")
        .ok()
        .filter(|s| !s.is_empty());
    let dir_path = vendors_set.clone().unwrap_or_else(|| vendor_path.clone());
    // C: is_dir starts 0; an unset/empty OCL_ICD_VENDORS (dir_path :=
    // vendor_path) OR a stat-confirmed directory flips it to 1.
    let mut is_dir = vendors_set.is_none();

    if !is_dir {
        // stat: EACCES etc. -> C prints "Cannot stat. Aborting" (the print
        // is inside the if; execution continues) and keeps is_dir=0.
        match std::fs::symlink_metadata(&dir_path) {
            Ok(m) => is_dir = m.is_dir(),
            Err(e) if e.raw_os_error() != Some(crate::clib::ENOENT) => {
                debug!(D_WARN, "Cannot stat '{}'. Aborting", dir_path);
            }
            _ => {}
        }
    }

    if !is_dir {
        debug!(D_LOG, "Only loading '{}' as an ICD", dir_path);
        if ends_with_icd(&dir_path) {
            // C: _open_driver first with the vendor_path as base (no-op for
            // absolute paths), then with NULL base (the path itself).
            let before = handles.len();
            open_driver(&mut handles, Some(&vendor_path), &dir_path);
            if handles.len() == before {
                open_driver(&mut handles, None, &dir_path);
            }
        } else {
            let h = load_icd(&dir_path);
            if !h.is_null() {
                handles.push(h);
            }
        }
    } else {
        debug!(D_LOG, "Reading icd list from '{}'", dir_path);
        match std::fs::read_dir(&dir_path) {
            Ok(rd) => {
                // C readdir order, deliberately unsorted: registration order
                // is filesystem order and the sort tests pin it.
                for e in rd.filter_map(|e| e.ok()) {
                    if let Ok(name) = e.file_name().into_string() {
                        if ends_with_icd(&name) {
                            open_driver(&mut handles, Some(&dir_path), &name);
                        }
                    }
                }
            }
            Err(e) => {
                // is_dir was set from env (path is actually a lib file):
                // opendir ENOTDIR -> the D_DUMP line, then abort.
                if e.raw_os_error() == Some(crate::clib::ENOTDIR) {
                    debug!(D_DUMP, "{} is not a directory, trying to use it as a ICD libname", dir_path);
                }
                return handles;
            }
        }
    }

    // Load layers from the same directory (port of __initLayers).
    // (kept in build_registry via the directory scan below)
    handles
}

unsafe fn discover_layers() -> Vec<(*mut c_void, String)> {
    let mut out = Vec::new();
    // OPENCL_LAYERS (C): colon-separated list of library paths, loaded first.
    if let Ok(list) = std::env::var("OPENCL_LAYERS") {
        for entry in list.split(':').filter(|s| !s.is_empty()) {
            let h = load_icd(entry);
            if !h.is_null() {
                out.push((h, entry.to_string()));
            }
        }
    }
    let dir_path = std::env::var("OCL_ICD_LAYERS")
                .ok()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| {
                    let vp = std::env::var("OPENCL_VENDOR_PATH")
                        .unwrap_or_else(|_| "/etc/OpenCL/vendors".into());
                    let vp = if vp.is_empty() { "/etc/OpenCL/vendors".to_string() } else { vp };
                    std::env::var("OCL_ICD_VENDORS")
                        .ok()
                        .filter(|s| !s.is_empty())
                        .unwrap_or(vp)
                });
    if let Ok(rd) = std::fs::read_dir(&dir_path) {
        let mut names: Vec<String> = rd
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n.ends_with(LAY_EXTENSION))
            .collect();
        names.sort();
        for n in names {
            let full = format!("{}/{}", dir_path, n);
            let contents = match std::fs::read_to_string(&full) {
                Ok(c) => c,
                Err(_) => continue,
            };
            if let Some(libname) = contents.lines().next().map(|l| l.trim_end().to_string()) {
                if libname.is_empty() {
                    continue;
                }
                let h = load_icd(&libname);
                if !h.is_null() {
                    out.push((h, libname));
                }
            }
        }
    }
    out
}

// ────────────────────────── registration ──────────────────────────

unsafe fn malloc_platform_info_str(
    f: GetPlatformInfo,
    pid: cl_platform_id,
    what: cl_platform_info,
) -> Option<String> {
    let mut need: usize = 0;
    if f(pid, what, 0, core::ptr::null_mut(), &mut need) != CL_SUCCESS {
        return None;
    }
    let mut buf = vec![0u8; need];
    if f(pid, what, need, buf.as_mut_ptr() as *mut c_void, &mut need) != CL_SUCCESS {
        return None;
    }
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    Some(String::from_utf8_lossy(&buf[..end]).into_owned())
}

fn count_devices(p: &mut PlatformIcd) {
    unsafe {
        let table = crate::dispatch::object_dispatch(p.pid);
        let get = crate::dispatch::slot_fn(table, 2);
        if get.is_null() {
            return;
        }
        let f: GetDeviceIDs = std::mem::transmute::<*mut c_void, GetDeviceIDs>(get);
        let ok = |t: cl_device_type, out: &mut cl_uint| {
            *out = 0;
            let e = f(p.pid, t, 0, core::ptr::null_mut(), out);
            if e != CL_SUCCESS && e != CL_DEVICE_NOT_FOUND {
                *out = 0;
            }
        };
        ok(CL_DEVICE_TYPE_GPU, &mut p.ngpus);
        ok(CL_DEVICE_TYPE_CPU, &mut p.ncpus);
        ok(CL_DEVICE_TYPE_ALL, &mut p.ndevs);
    }
}

/// Port of `_find_and_check_platforms`: for each dlopen'd handle, enumerate
/// platforms via clIcdGetPlatformIDsKHR, validate cl_khr_icd + suffix, and for
/// ICD2 platforms build the loader-managed dispatch table.
unsafe fn find_and_check_platforms(handles: Vec<*mut c_void>) -> (Vec<VendorIcd>, Vec<PlatformIcd>) {
    let mut vendors = Vec::new();
    let mut platforms = Vec::new();

    for dlh in handles {
        let ext_addr_raw = get_function_addr(dlh, None, "clGetExtensionFunctionAddress");
        let ext: Option<ExtFnAddr> = if ext_addr_raw.is_null() {
            None
        } else {
            Some(std::mem::transmute::<*mut c_void, ExtFnAddr>(ext_addr_raw))
        };

        let plt_ids_raw = get_function_addr(dlh, ext, "clIcdGetPlatformIDsKHR");
        let plt_info_raw = get_function_addr(dlh, ext, "clGetPlatformInfo");
        if plt_ids_raw.is_null() {
            debug!(D_WARN, "Missing clIcdGetPlatformIDsKHR symbol in ICD, skipping it");
            continue;
        }
        let plt_fn: IcdGetPlatformIDs = std::mem::transmute(plt_ids_raw);

        let mut num: cl_uint = 0;
        if plt_fn(0, core::ptr::null_mut(), &mut num) != CL_SUCCESS || num == 0 {
            debug!(D_LOG, "No platform in ICD, skipping it");
            continue;
        }
        let mut pids = vec![core::ptr::null_mut::<c_void>(); num as usize];
        if plt_fn(num, pids.as_mut_ptr(), core::ptr::null_mut()) != CL_SUCCESS {
            debug!(D_WARN, "Error in loading ICD platforms, skipping ICD");
            continue;
        }

        let pltfn_raw = get_function_addr(dlh, ext, "clIcdGetFunctionAddressForPlatformKHR");
        let pltfn: Option<IcdGetAddrForPlatform> =
            (!pltfn_raw.is_null()).then(|| std::mem::transmute(pltfn_raw));
        let spltdd_raw = get_function_addr(dlh, ext, "clIcdSetPlatformDispatchDataKHR");
        let spltdd: Option<IcdSetPlatformDispatchData> =
            (!spltdd_raw.is_null()).then(|| std::mem::transmute(spltdd_raw));

        let mut valid = 0;
        for pid in pids {
            let tagged = has_icd2_tag(pid);
            if tagged && (pltfn.is_none() || spltdd.is_none()) {
                debug!(D_WARN, "ICD2 platform missing dispatch entry points, skipping it");
                continue;
            }
            // clUnloadCompiler slot (31) must carry the tag too (spec check).
            if tagged {
                let own = (pid as *const ObjectHeader).read().dispatch;
                if own.is_null() || *own.add(31) as isize != CL_ICD2_TAG_KHR {
                    debug!(D_WARN, "ICD2 platform without clUnloadCompiler tag, skipping");
                    continue;
                }
            }

            let mut entry = PlatformIcd {
                vendor_idx: 0, // fixed up below
                pid,
                suffix: String::new(),
                ngpus: 0,
                ncpus: 0,
                ndevs: 0,
                unloadable: CL_FALSE,
                disp_data: None,
            };

            if tagged {
                let mut table = new_tagged_table();
                if let Some(pltfn) = pltfn {
                    for (i, name) in super::dispatch::DISPATCH_SLOT_NAMES.iter().enumerate() {
                        if name.is_empty() {
                            continue;
                        }
                        let cname = std::ffi::CString::new(*name).unwrap();
                        let addr = pltfn(pid, cname.as_ptr());
                        table.slots[i] = addr;
                    }
                }
                let boxed = Box::new(table);
                spltdd.unwrap()(pid, Box::as_ref(&boxed) as *const DispTable as *mut c_void);
                entry.disp_data = Some(boxed);
                debug!(D_LOG, "Found icd2 platform, using loader managed dispatch");
            }

            // C: under D_DUMP, dump_platform probes every dispatch slot
            // with five NULL args; vendors' info functions emit their
            // "<slot>  : " marker as a side effect (the testsuite checks
            // those lines). Trace is suppressed during the probe loop.
            if crate::debug::mask() & crate::debug::D_DUMP != 0 {
                let saved = crate::debug::mask();
                crate::debug::set_mask(saved & !crate::debug::D_TRACE);
                dump_platform(ext, pid);
                crate::debug::set_mask(saved);
            }

            // extension check (cl_khr_icd) unless ASSUME
            let info_fn: Option<GetPlatformInfo> = {
                let raw = if plt_info_raw.is_null() {
                    // Assume-ICD-extension path: take it from the dispatch table.
                    super::dispatch::slot_fn(super::dispatch::object_dispatch(pid), 1)
                } else {
                    plt_info_raw
                };
                (!raw.is_null()).then(|| std::mem::transmute(raw))
            };
            let info_fn = match info_fn {
                Some(f) => f,
                None => {
                    debug!(D_WARN, "Missing clGetPlatformInfo, skipping platform");
                    continue;
                }
            };
            if !assume_icd_extension() {
                match malloc_platform_info_str(info_fn, pid, CL_PLATFORM_EXTENSIONS) {
                    Some(exts) if exts.split_whitespace().any(|e| e == "cl_khr_icd") => {
                        // cl_khr_icd_unloadable (ICD 3.x): platform may be
                        // dlclosed at loader deinitialization.
                        if exts.split_whitespace().any(|e| e == "cl_khr_icd_unloadable") {
                            let mut un = CL_TRUE;
                            if info_fn(
                                pid,
                                CL_PLATFORM_UNLOADABLE_KHR,
                                core::mem::size_of::<cl_bool>(),
                                &mut un as *mut _ as *mut c_void,
                                core::ptr::null_mut(),
                            ) != CL_SUCCESS
                            {
                                un = CL_FALSE;
                            }
                            entry.unloadable = un;
                        }
                    }
                    _ => {
                        debug!(D_WARN, "Missing cl_khr_icd extension, skipping platform");
                        continue;
                    }
                }
            }
            match malloc_platform_info_str(info_fn, pid, CL_PLATFORM_ICD_SUFFIX_KHR) {
                Some(s) => entry.suffix = s,
                None => {
                    debug!(D_WARN, "Missing ICD suffix, skipping platform");
                    continue;
                }
            }

            entry.vendor_idx = vendors.len(); // provisional; vendors pushed after loop
            platforms.push(entry);
            valid += 1;
        }

        if valid != 0 {
            vendors.push(VendorIcd {
                path: String::new(),
                dl_handle: dlh,
                ext_fn_ptr: ext,
                num_platforms: valid,
            });
        } else {
            crate::clib::dlclose(dlh);
        }
    }

    // device counts + sort (OCL_ICD_PLATFORM_SORT=none disables; else GPU,CPU,DEV)
    let sort_mode = std::env::var("OCL_ICD_PLATFORM_SORT").unwrap_or_default();
    if sort_mode != "none" && platforms.len() > 1 {
        for p in platforms.iter_mut() {
            count_devices(p);
        }
        platforms.sort_by(|a, b| {
            b.ngpus
                .cmp(&a.ngpus)
                .then(b.ncpus.cmp(&a.ncpus))
                .then(b.ndevs.cmp(&a.ndevs))
        });
    }

    (vendors, platforms)
}

unsafe fn build_registry() -> Registry {
    debug_init_env();
    let handles = discover_vendors();
    let (vendors, platforms) = find_and_check_platforms(handles);

    let mut layers = Vec::new();
    if !env_true("OCL_ICD_FORCE_LEGACY_TERMINATION") {
        for (h, name) in discover_layers() {
            let init_raw = dlsym_addr(h, "clInitLayerWithProperties");
            if init_raw.is_null() {
                debug!(D_WARN, "Layer '{}' rejected (no clInitLayerWithProperties)", name);
                crate::clib::dlclose(h);
                continue;
            }
            let deinit_raw = dlsym_addr(h, "clDeinitLayer");
            let f: extern "C" fn(
                cl_uint,
                *const *mut c_void,
                *mut cl_uint,
                *mut *const *mut c_void,
                *const cl_properties_placeholder,
            ) -> cl_int = std::mem::transmute(init_raw);
            let mut n: cl_uint = 0;
            let mut table: *const *mut c_void = core::ptr::null();
            let target = crate::exports::loader_dispatch_table();
            let r = f(
                NUM_DISPATCH_SLOTS as cl_uint,
                target,
                &mut n,
                &mut table,
                core::ptr::null(),
            );
            if r != CL_SUCCESS || table.is_null() {
                debug!(D_WARN, "Layer '{}' rejected (clInitLayerWithProperties failed)", name);
                crate::clib::dlclose(h);
                continue;
            }
            let _ = deinit_raw;
            // Copy the layer's dispatch table into a loader-owned box.
            let mut t = DispTable {
                slots: [core::ptr::null_mut(); NUM_DISPATCH_SLOTS],
            };
            for i in 0..NUM_DISPATCH_SLOTS {
                t.slots[i] = *table.add(i);
            }
            let deinit_fn: Option<DeinitLayerFn> =
                (!deinit_raw.is_null()).then(|| std::mem::transmute(deinit_raw));
            layers.push(LayerIcd {
                dl_handle: h,
                table: Box::new(t),
                deinit_fn,
            });
            debug!(D_LOG, "Layer '{}' loaded", name);
        }
    }

    let _ = &vendors;
    Registry {
        vendors,
        platforms,
        layers,
        ok: true,
    }
}

/// C dump_platform: call every dispatch slot with NULL args (vendors'
/// info functions print their "<slot>  : " marker as a side effect; the
/// testsuite compares those lines) and dump addresses to stderr.
unsafe fn dump_platform(ext: Option<ExtFnAddr>, pid: *mut c_void) {
    eprintln!("ocl-icd-rs: platform @{pid:p}:  name=field_in_struct [clGetExtensionFunctionAddress(name)/clGetExtensionFunctionAddressForPlatform(name)]");
    let table = crate::dispatch::object_dispatch(pid);
    for (i, name) in super::dispatch::DISPATCH_SLOT_NAMES.iter().enumerate() {
        if name.is_empty() {
            continue;
        }
        let field = *table.add(i);
        // C: dump_field asks the vendor's ext-address fn for the name; that
        // fn only ever answers for KHR/EXT-suffixed names (side-effect
        // markers would double-print if called for plain names).
        let khr_ext = name.len() > 3
            && (name.ends_with("KHR") || name.ends_with("EXT") || name.ends_with("IMG")
                || name.ends_with("NV") || name.ends_with("AMD") || name.ends_with("APPLE"));
        let a = match (ext, khr_ext) {
            (Some(f), true) => std::ffi::CString::new(*name)
                .map(|c| f(c.as_ptr()))
                .unwrap_or(core::ptr::null_mut()),
            _ => core::ptr::null_mut(),
        };
        // C dump_field's third arg is a dlsym(RTLD_DEFAULT) lookup, not a
        // call; invoking the slot would double-print vendor markers.
        let b = crate::debug::dlsym_default(name);
        eprintln!("ocl-icd-rs: {:>40}={field:p} [{a:p}/{b:p}]", *name);
    }
}

fn debug_init_env() {
    let _ = crate::debug::mask(); // force OnceLock read (no-op if unset)
}

// Placeholder: cl_layer_properties is cl_properties (uintptr_t); we only ever
// pass NULL from the prototype.
pub type cl_properties_placeholder = usize;

// ────────────────────────── queries ──────────────────────────

impl Registry {
    /// Free the registry's heap at deinit (C: `free(_icds); free(_picds);`
    /// in _deinitClIcd_no_inline). Leaves the vecs empty; all post-deinit
    /// entry points gate on DEINIT before touching the registry, and the
    /// dlclose destructor makes this the last write to the struct.
    pub unsafe fn release(&self) {
        let me = self as *const Registry as *mut Registry;
        let _ = std::mem::take(&mut (*me).vendors);
        let _ = std::mem::take(&mut (*me).platforms);
        let _ = std::mem::take(&mut (*me).layers);
    }

    pub fn find_platform(&self, pid: cl_platform_id) -> Option<&PlatformIcd> {
        self.platforms.iter().find(|p| p.pid == pid)
    }

    /// The dispatch table to call into for `platform`: loader-managed table
    /// for ICD2 platforms, the platform's own table otherwise.
    pub fn platform_table(&self, platform: &PlatformIcd) -> *mut *mut c_void {
        match &platform.disp_data {
            Some(b) => Box::as_ref(b) as *const DispTable as *mut *mut c_void,
            None => unsafe { crate::dispatch::object_dispatch(platform.pid) },
        }
    }

    pub fn default_platform(&self) -> Option<&PlatformIcd> {
        // getDefaultPlatformID() fidelity: OCL_ICD_DEFAULT_PLATFORM picks
        // the platform by index in registration (_picd) order; the answer
        // is latched on first call like the C static. Unset -> index 0.
        // Empty/garbage/out-of-range -> no default at all (None).
        static LATCHED: std::sync::OnceLock<Option<usize>> = std::sync::OnceLock::new();
        let idx = LATCHED.get_or_init(|| match std::env::var("OCL_ICD_DEFAULT_PLATFORM") {
            Err(_) => Some(0usize),
            Ok(s) => s.parse::<i64>().ok()
                .filter(|i| *i >= 0 && (*i as usize) < self.platforms.len())
                .map(|i| i as usize),
        });
        idx.and_then(|i| self.platforms.get(i))
    }

    pub fn default_platform_id(&self) -> Option<*mut std::ffi::c_void> {
        self.default_platform().map(|p| p.pid)
    }
}


