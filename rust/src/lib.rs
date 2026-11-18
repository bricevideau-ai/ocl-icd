//! Prototype Rust port of the ocl-icd OpenCL ICD loader.
//!
//! See README.md for the fidelity matrix (what's ported, what's stubbed).
#![allow(non_snake_case, non_camel_case_types)]

mod clib;
#[macro_use]
mod debug;
mod dispatch;
#[path = "gen_forwarders.rs"]
pub mod gen;
mod exports;
mod registry;
mod types;
