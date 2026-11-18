//! Dispatch-table machinery: the loader's per-platform ICD2 table and the
//! object -> dispatch-table resolution (KHR_ICD2_DISPATCH in the C loader).
use crate::types::*;
use core::ffi::c_void;

include!("slots.rs");

/// Loader-managed dispatch data for one platform. `struct _cl_disp_data` in C.
#[repr(C)]
pub struct DispTable {
    pub slots: [*mut c_void; NUM_DISPATCH_SLOTS],
}

// SAFETY: every slot is written exactly once during registry construction
// (OnceLock), before any dispatch can observe it; afterwards read-only.
unsafe impl Send for DispTable {}
unsafe impl Sync for DispTable {}

/// Fixed-size table newtype usable in statics (arrays of raw pointers are
/// neither Send nor Sync by default).
pub struct TableCell(pub Box<[*mut c_void; NUM_DISPATCH_SLOTS]>);
// SAFETY: written once during construction, read-only afterwards.
unsafe impl Send for TableCell {}
unsafe impl Sync for TableCell {}

impl TableCell {
    pub fn new() -> Self {
        TableCell(Box::new([core::ptr::null_mut(); NUM_DISPATCH_SLOTS]))
    }
}

/// Slot 0 of a dispatch table for an ICD2 entity must carry the tag.
pub fn new_tagged_table() -> DispTable {
    let mut t = DispTable {
        slots: [core::ptr::null_mut(); NUM_DISPATCH_SLOTS],
    };
    t.slots[0] = CL_ICD2_TAG_KHR as *mut c_void;
    t
}

/// Resolve the dispatch table to use for `obj`, following the C loader's
/// `KHR_ICD2_DISPATCH`: if slot 0 of the object's own table holds the ICD2
/// tag, the loader-managed table sits behind `disp_data`; otherwise the
/// object's own table is authoritative (ICD1 path).
///
/// # Safety
/// `obj` must be a valid Khronos object (or null, which yields null).
pub unsafe fn object_dispatch(obj: *mut c_void) -> *mut *mut c_void {
    if obj.is_null() {
        return core::ptr::null_mut();
    }
    let hdr = obj as *const ObjectHeader;
    let table = (*hdr).dispatch;
    if table.is_null() {
        return core::ptr::null_mut();
    }
    if (*table as isize) == CL_ICD2_TAG_KHR {
        let dd = (*hdr).disp_data as *mut *mut c_void;
        // ICD2 objects must have disp_data set (by us for platforms, or by the
        // ICD itself for its own objects); fall back to the object's table.
        if dd.is_null() {
            table
        } else {
            dd
        }
    } else {
        table
    }
}

/// Fetch slot `slot` of `table` as a function pointer.
/// # Safety
/// `table` must be a valid dispatch table; the slot must hold a pointer of the
/// signature asserted by the caller (slot names are fixed by ocl_interface.yaml).
pub unsafe fn slot_fn(table: *mut *mut c_void, slot: usize) -> *mut c_void {
    if table.is_null() || slot >= NUM_DISPATCH_SLOTS {
        core::ptr::null_mut()
    } else {
        *table.add(slot)
    }
}

/// Is `obj` an ICD2-tagged object?
/// # Safety: see object_dispatch.
pub unsafe fn has_icd2_tag(obj: *mut c_void) -> bool {
    if obj.is_null() {
        return false;
    }
    let table = (obj as *const ObjectHeader).read().dispatch;
    !table.is_null() && (*table as isize) == CL_ICD2_TAG_KHR
}

/// Index of `name` in the generated DISPATCH_SLOT_NAMES table; usize::MAX when
/// absent. Compile-time usable — the entry macros assert their slot argument
/// against it, so a slot that ever drifts from the function name fails the
/// build instead of segfaulting inside a vendor driver.
pub const fn slot_of(name: &str) -> usize {
    let mut i = 0;
    while i < NUM_DISPATCH_SLOTS {
        if str_eq(DISPATCH_SLOT_NAMES[i], name) {
            return i;
        }
        i += 1;
    }
    usize::MAX
}

const fn str_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}
