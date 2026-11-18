//! Minimal OpenCL type vocabulary for the loader prototype.
//! Mirrors khronos-headers/CL values exactly; only what the port uses.
#![allow(non_camel_case_types, dead_code)]

pub type cl_int = i32;
pub type cl_uint = u32;
pub type cl_bool = cl_uint;
pub type cl_device_type = u64;
pub type cl_context_properties = isize;
pub type cl_mem_flags = u64;
pub type cl_mem_object_type = u32;
pub type cl_platform_info = u32;
pub type cl_device_info = u32;
pub type cl_context_info = u32;
pub type cl_icdl_info = u32;

// Opaque handles. The dispatch pointer is always the FIRST field of every
// Khronos object (struct _cl_*), which is what makes ICD dispatch possible.
pub type cl_platform_id = *mut c_void;
pub type cl_device_id = *mut c_void;
pub type cl_context = *mut c_void;
pub type cl_command_queue = *mut c_void;
pub type cl_mem = *mut c_void;
pub type cl_event = *mut c_void;
pub type cl_sampler = *mut c_void;
pub type cl_program = *mut c_void;
pub type cl_kernel = *mut c_void;

use core::ffi::c_void;

pub const CL_SUCCESS: cl_int = 0;
pub const CL_DEVICE_NOT_FOUND: cl_int = -1;
pub const CL_OUT_OF_HOST_MEMORY: cl_int = -6;
pub const CL_INVALID_VALUE: cl_int = -30;
pub const CL_INVALID_PLATFORM: cl_int = -32;
pub const CL_INVALID_DEVICE: cl_int = -33;
pub const CL_INVALID_CONTEXT: cl_int = -34;
pub const CL_INVALID_EVENT_WAIT_LIST: cl_int = -48;
pub const CL_INVALID_EVENT: cl_int = -40;
pub const CL_INVALID_OPERATION: cl_int = -59;
pub const CL_INVALID_COMMAND_QUEUE: cl_int = -36;
pub const CL_INVALID_MEM_OBJECT: cl_int = -38;
pub const CL_PLATFORM_NOT_FOUND_KHR: cl_int = -1001;

pub const CL_FALSE: cl_bool = 0;
pub const CL_TRUE: cl_bool = 1;

pub const CL_DEVICE_TYPE_DEFAULT: cl_device_type = 1 << 0;
pub const CL_DEVICE_TYPE_CPU: cl_device_type = 1 << 1;
pub const CL_DEVICE_TYPE_GPU: cl_device_type = 1 << 2;
pub const CL_DEVICE_TYPE_ACCELERATOR: cl_device_type = 1 << 3;
pub const CL_DEVICE_TYPE_ALL: cl_device_type = 0xFFFFFFFF;

pub const CL_PLATFORM_PROFILE: cl_platform_info = 0x0900;
pub const CL_PLATFORM_VERSION: cl_platform_info = 0x0901;
pub const CL_PLATFORM_NAME: cl_platform_info = 0x0902;
pub const CL_PLATFORM_VENDOR: cl_platform_info = 0x0903;
pub const CL_PLATFORM_EXTENSIONS: cl_platform_info = 0x0904;
pub const CL_PLATFORM_ICD_SUFFIX_KHR: cl_platform_info = 0x0920;
pub const CL_PLATFORM_UNLOADABLE_KHR: cl_platform_info = 0x0921;

pub const CL_DEVICE_TYPE: cl_device_info = 0x1000;
pub const CL_DEVICE_NAME: cl_device_info = 0x102B;

pub const CL_CONTEXT_PLATFORM: cl_context_properties = 0x1084;

pub const CL_ICDL_OCL_VERSION: cl_icdl_info = 1;
pub const CL_ICDL_VERSION: cl_icdl_info = 2;
pub const CL_ICDL_NAME: cl_icdl_info = 3;
pub const CL_ICDL_VENDOR: cl_icdl_info = 4;

/// cl_khr_icd 2.0 (ICD2) tag. An object is ICD2 when the first slot of its
/// dispatch table (clGetPlatformIDs) holds this value instead of a pointer.
#[cfg(target_pointer_width = "64")]
pub const CL_ICD2_TAG_KHR: isize = 0x4F50454E434C3331isize;
#[cfg(target_pointer_width = "32")]
pub const CL_ICD2_TAG_KHR: isize = 0x434C3331isize;

/// The generic view of the first two fields of every ICD2 object:
/// dispatch pointer + loader-managed dispatch data pointer.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ObjectHeader {
    pub dispatch: *mut *mut c_void,
    pub disp_data: *mut c_void,
}
