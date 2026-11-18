#!/usr/bin/env python3
"""Rust counterpart of ocl-icd's icd_generator.rb (entry-point subset).

Reads ocl_interface.yaml (slot index -> Khronos prototype) and emits
src/gen_forwarders.rs:

  * `<name>_disp` — extern "C" implementations of every non-special dispatch
    function, with the C loader's generated-dispatch semantics:
      - first parameter's Khronos type selects the NULL-object error
        ($cl_data_type_error in icd_generator.rb);
      - an errcode_ret parameter gets set on error paths; non-standard-error
        funcs (clSVMAlloc) return NULL silently;
      - cl_platform_id first arg: NULL selects the default platform
        (selectPlatformID); dispatch routes through the platform's managed
        (ICD2) table; object first args route via KHR_ICD2_DISPATCH.
  * `<name>` — the exported entry point (deinit-aware + layer chain), via the
    `gen_entry!` macro.
  * `gen_slot_disp` / `gen_slot_unsupp` — address lookups by dispatch slot for
    the loader's _disp table and the post-deinit table.

All args are marshalled through usize; the uniform 6-arg extern "C"
trampoline is ABI-safe on LP64 (OpenCL prototypes carry no float args).
"""
import re
import sys
import os
import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # rust/
TOP = os.path.dirname(REPO)  # ocl-icd source root
YAML_SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(TOP, "ocl_interface.yaml")

SPECIFIC_LOADER = {
    "clGetExtensionFunctionAddress", "clGetPlatformIDs", "clGetGLContextInfoKHR",
    "clUnloadCompiler", "clUnloadPlatformCompiler", "clCreateContext",
    "clCreateContextFromType", "clWaitForEvents",
    "clGetPlatformInfo",  # hand-written _disp exists in exports.rs (selectPlatformID)
}
LOADER_DISP_NAMES = {
    "clGetPlatformIDs": "clGetPlatformIDs_disp",
    "clGetPlatformInfo": "clGetPlatformInfo_disp",
    "clCreateContext": "clCreateContext_disp",
    "clCreateContextFromType": "clCreateContextFromType_disp",
    "clWaitForEvents": "clWaitForEvents_disp",
    "clGetGLContextInfoKHR": "clGetGLContextInfoKHR_disp",
    "clGetExtensionFunctionAddress": "clGetExtensionFunctionAddress_disp",
    "clUnloadCompiler": "clUnloadCompiler_disp",
    "clUnloadPlatformCompiler": "clUnloadPlatformCompiler_disp",
}
FIRST_TYPE_ERROR = {
    "cl_platform_id": ("CL_INVALID_PLATFORM", "platform"),
    "cl_device_id": ("CL_INVALID_DEVICE", "object"),
    "cl_context": ("CL_INVALID_CONTEXT", "object"),
    "cl_command_queue": ("CL_INVALID_COMMAND_QUEUE", "object"),
    "cl_mem": ("CL_INVALID_MEM_OBJECT", "object"),
    "cl_program": ("CL_INVALID_PROGRAM", "object"),
    "cl_kernel": ("CL_INVALID_KERNEL", "object"),
    "cl_event": ("CL_INVALID_EVENT", "object"),
    "cl_sampler": ("CL_INVALID_SAMPLER", "object"),
}
NON_STANDARD_ERROR = {"clGetExtensionFunctionAddressForPlatform", "clSVMAlloc"}
OBJECT_TYPES = {"cl_platform_id", "cl_device_id", "cl_context", "cl_command_queue",
                "cl_mem", "cl_program", "cl_kernel", "cl_event", "cl_sampler"}

BASE_TO_RUST = {
    "cl_int": "cl_int", "cl_uint": "cl_uint", "cl_bool": "cl_bool",
    "size_t": "usize", "char": "c_char", "void": "c_void", "cl_char": "i8",
    "cl_uchar": "u8", "cl_short": "i16", "cl_ushort": "u16", "cl_long": "i64",
    "cl_flags": "u64", "cl_bitfield": "u64", "cl_ulong": "u64",
    "cl_device_type": "cl_device_type", "cl_context_properties": "cl_context_properties",
    "cl_mem_flags": "u64", "cl_map_flags": "u64", "cl_svm_mem_flags": "u64",
    "cl_mem_migration_flags": "u64", "cl_command_queue_properties": "u64",
    "cl_device_fp_config": "u64",
    "cl_device_partition_property": "isize", "cl_sampler_properties": "isize",
    "cl_pipe_properties": "isize", "cl_kernel_execution_properties": "isize",
    "cl_platform_info": "cl_platform_info", "cl_device_info": "cl_device_info",
    "cl_context_info": "cl_context_info", "cl_command_queue_info": "u32",
    "cl_mem_object_type": "u32", "cl_image_info": "u32",
    "cl_build_status": "i32", "cl_program_info": "u32", "cl_program_binary_type": "u32",
    "cl_program_build_info": "u32", "cl_kernel_info": "u32", "cl_kernel_work_group_info": "u32",
    "cl_kernel_arg_info": "u32", "cl_event_info": "u32", "cl_event_status": "i32",
    "cl_profiling_info": "u32", "cl_sampler_info": "u32", "cl_addressing_mode": "u32",
    "cl_filter_mode": "u32", "cl_channel_order": "u32", "cl_channel_type": "u32",
    "cl_gl_info_type": "u32", "cl_gl_texture_info": "u32", "cl_gl_platform_info": "u32",
    "cl_gl_context_info": "u32", "cl_image_desc": "c_void", "cl_image_format": "c_void",
    "cl_layer_info": "u32", "cl_layer_properties": "usize",
    "cl_platform_id": "cl_platform_id", "cl_device_id": "cl_device_id",
    "cl_context": "cl_context", "cl_command_queue": "cl_command_queue",
    "cl_mem": "cl_mem", "cl_program": "cl_program", "cl_kernel": "cl_kernel",
    "cl_event": "cl_event", "cl_sampler": "cl_sampler", "cl_GLuint": "u32",
    "cl_GLint": "i32", "cl_GLenum": "u32", "cl_GLsizei": "u32", "clGLenum": "u32",
    "clGLint": "i32", "clGLsizei": "u32",
}

def parse_entry(entry):
    # parameter NAMES live inside /* */ in the YAML -> harvest them, then
    # replace each comment by its name so later parsing sees a normal prototype
    comments = re.findall(r"/\*\s*(?:const\s+)?([A-Za-z_][A-Za-z0-9_ ]*)\s*\*/", entry)
    def repl(m):
        inner = re.sub(r"^[\s*]+|[\s*]+$", "", m.group(0)[2:-2])
        w = inner.split()
        ok = w and all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", x) for x in w)
        return w[-1] if ok else "unnamed"
    body = re.sub(r"/\*.*?\*/", repl, entry, flags=re.S)
    m = re.search(r"CL_API_CALL\s*([A-Za-z0-9_]+)\s*\(", body, flags=re.S)
    if not m:
        return None
    name = m.group(1)
    ret_m = re.search(r"CL_API_ENTRY\s+(.*?)\s*CL_API_CALL", body, flags=re.S)
    ret_raw = " ".join(ret_m.group(1).split()) if ret_m else "cl_int"
    if ret_raw.startswith("const "):
        ret_raw = ret_raw[6:]
    ret_base = ret_raw.replace("*", " ").replace("[", " ").split()[-1] if ret_raw not in ("void",) else "void"
    ret_ptr = ret_raw != "void" and ("*" in ret_raw or "[" in ret_raw or ret_base in OBJECT_TYPES)
    ret_u64 = not ret_ptr and ret_base == "cl_ulong"
    ret_void = not ret_ptr and not ret_u64 and ret_raw == "void"
    start = body.index("(", m.end() - 1)
    depth, end = 0, None
    for i in range(start, len(body)):
        if body[i] == "(":
            depth += 1
        elif body[i] == ")":
            depth -= 1
            if depth == 0:
                end = i
                break
    flat = re.sub(r"\s+", " ", body[start + 1 : end])
    chunks, cur, depth = [], "", 0
    for ch in flat:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            chunks.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        chunks.append(cur)
    params = []
    for c in chunks:
        c = c.strip()
        if not c or c == "void":
            continue
        # callback parameter: a parenthesised declarator "(... * name)" whose
        # closing paren is NOT followed by "(" (a call, not a declarator)
        fmc = re.search(r"\*\s*(?:/\*\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\*/\s*)?\)", c)
        if fmc and c[: fmc.start()].count("(") - c[: fmc.start()].count(")") >= 1:
            # star sits inside an unclosed paren -> parenthesised declarator
            params.append(("*mut c_void", fmc.group(1)))
            continue
        nm = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", c)
        if not nm:
            return None
        pname = nm.group(1)
        decl = c[: nm.start(1)]
        stars = decl.count("*")
        toks = decl.replace("*", " ").split()
        toks = [t for t in toks if t != "const"]
        bt = toks[-1] if toks else "void"
        rust = BASE_TO_RUST.get(bt, "c_void" if stars else "usize")
        is_const = "const" in toks or "const" in decl.split(bt)[0]
        for _ in range(stars):
            rust = f"*mut {rust}"
        if is_const and rust.startswith("*mut"):
            rust = rust.replace("*mut", "*const", 1)
        params.append((rust, pname))
    if ret_ptr:
        ret_rust = "*mut c_void"
    elif ret_u64:
        ret_rust = "u64"
    elif ret_base == "void":
        ret_rust = "()"
    else:
        ret_rust = BASE_TO_RUST.get(ret_base, "cl_int")
    # errcode_ret is always cl_int* regardless of how the YAML spells it
    params = [(" *mut cl_int" if pn == "errcode_ret" else (pt.replace("cl_int", "cl_int")), pn)
              if pn != "errcode_ret" else ("*mut cl_int", pn) for pt, pn in params]
    # dedupe parameter identifiers (unnamed slots from commentless prototypes)
    seen = {}
    uniq = []
    for pt, pn in params:
        if pn in seen:
            seen[pn] += 1
            pn = "%s%d" % (pn, seen[pn])
        else:
            seen[pn] = 0
        uniq.append((pt, pn))
    params = uniq
    return name, ret_rust, ret_ptr, ret_void, ret_u64, params

def classify(t):
    ts = t.strip()
    if ts.startswith("*") or ts in FIRST_TYPE_ERROR:
        return "Ptr"
    if ts == "u64" or ts == "cl_device_type":
        return "U64"
    return "Trivial"

def marsh_of(pt, pn):
    c = classify(pt)
    if c == "U64":
        return f"val(&{pn})"
    return f"{pn} as usize"

def unmarshal_expr(pt, arg):
    """expr converting a usize register back to parameter type pt."""
    ts = pt.strip()
    if classify(ts) == "Ptr" or ts in FIRST_TYPE_ERROR or ts.startswith("*"):
        return f"{arg} as *mut _ as {ts}" if not ts.startswith("*") else f"{arg} as {ts}"
    if ts == "u64":
        return f"{arg} as u64"
    if ts == "usize":
        return arg
    if ts == "cl_device_type":
        return f"{arg} as cl_device_type"
    if ts in ("cl_context_properties", "isize"):
        return f"{arg} as isize"
    if ts.startswith("cl_"):
        return f"{arg} as {ts}"
    return f"{arg} as {ts}"

def main():
    # 1. regenerate slots.rs inline from the YAML (slot indices can never drift)
    d = yaml.safe_load(open(YAML_SRC))
    n = max(int(k) for k in d) + 1
    snames = []
    for i in range(n):
        v = d.get(i, d.get(str(i)))
        mm = re.search(r"CL_API_CALL\s+([A-Za-z0-9_]+)\s*\(", v) if v else None
        snames.append(mm.group(1) if mm else "")
    slines = ["// GENERATED by rust/scripts/gen_bindings.py -- do not edit",
              "pub const NUM_DISPATCH_SLOTS: usize = %d;" % n,
              "pub const DISPATCH_SLOT_NAMES: [&str; NUM_DISPATCH_SLOTS] = ["]
    slines += ['    "%s",' % nm for nm in snames]
    slines += ["];", ""]
    open(os.path.join(REPO, "src/slots.rs"), "w").write("\n".join(slines))
    entries, slot_of = {}, {}
    for i in range(n):
        v = d.get(i, d.get(str(i)))
        if not v:
            continue
        p = parse_entry(v)
        if p is None:
            print("// UNPARSED slot %d" % i, file=sys.stderr)
            continue
        name = p[0]
        if name in entries:
            continue
        entries[name] = (i,) + p[1:]
        slot_of[name] = i

    out = [
        "// GENERATED by scripts/gen_rust_bindings.py from ocl-icd ocl_interface.yaml",
        "// -- do not edit. Regenerate after upstream spec changes.",
        "#![allow(clippy::too_many_arguments, unused_variables, non_snake_case, dead_code)]",
        "use crate::dispatch::object_dispatch;",
        "use crate::exports::{call_by_slot, call_by_slot_void, platform_dispatch_table, val, default_platform_id};",
        "use crate::exports::{clGetPlatformIDs_disp, clGetPlatformInfo_disp, clCreateContext_disp,",
        "    clCreateContextFromType_disp, clWaitForEvents_disp, clGetGLContextInfoKHR_disp,",
        "    clGetExtensionFunctionAddress_disp,",
        "    clUnloadCompiler_disp, clUnloadPlatformCompiler_disp};",
        "use crate::gen_entry;",
        "use crate::types::*;",
        "use core::ffi::{c_char, c_void};",
        "",
        "// error constants for NULL-object paths (khronos values)",
        "const CL_INVALID_CONTEXT: cl_int = -34;",
        "const CL_INVALID_COMMAND_QUEUE: cl_int = -36;",
        "const CL_INVALID_MEM_OBJECT: cl_int = -38;",
        "const CL_INVALID_EVENT: cl_int = -40;",
        "const CL_INVALID_KERNEL: cl_int = -42;",
        "const CL_INVALID_SAMPLER: cl_int = -35;",
        "const CL_INVALID_PROGRAM: cl_int = -44;",
        "const CL_INVALID_OPERATION: cl_int = -59;",
        "",
    ]

    skipped = []
    GENERATED = set()
    for name in sorted(entries, key=lambda k: entries[k][0]):
        slot, ret_rust, ret_ptr, ret_void, ret_u64, params = entries[name]
        if name in SPECIFIC_LOADER:
            continue
        if not params:
            skipped.append((name, "no params"))
            continue
        ft = params[0][0]
        base = ft
        while base.startswith("*mut ") or base.startswith("*const "):
            base = base[5:]
        if base not in FIRST_TYPE_ERROR:
            skipped.append((name, "unmapped first param " + ft))
            continue
        err_const, route = FIRST_TYPE_ERROR[base]
        has_err = any(pn == "errcode_ret" for _t, pn in params)
        nonstd = name in NON_STANDARD_ERROR
        p0 = params[0][1]

        arglist = ", ".join(f"{pn}: {pt}" for pt, pn in params)
        marsh = ", ".join(marsh_of(pt, pn) for pt, pn in params)

        # error branch statements (shared shape)
        nb = []
        if has_err:
            nb.append(f"if !errcode_ret.is_null() {{ *errcode_ret = {err_const}; }}")
            nb.append("return core::ptr::null_mut();" if ret_ptr else
                      (f"return {err_const};" if not ret_void and not ret_u64 else "return;"))
        elif nonstd:
            nb.append("return core::ptr::null_mut();")
        else:
            nb.append("return core::ptr::null_mut();" if ret_ptr else
                      ("return;" if ret_void else f"return {err_const};"))

        out.append(f"// ── slot {slot}: {name} ──")
        out.append("#[allow(clippy::too_many_arguments)]")
        out.append(f'pub unsafe extern "C" fn {name}_disp({arglist}) -> {ret_rust} {{')
        indent_nb = ["    " + l for l in nb]
        if name == "clGetExtensionFunctionAddressForPlatform":
            # C injects generate_get_extension_address_for_platform here:
            # func_desc table for KHR/EXT-suffixed names, before dispatch.
            out.append('    if !func_name.is_null() {')
            out.append('        let cname = unsafe { std::ffi::CStr::from_ptr(func_name) };')
            out.append('        if let Ok(s) = cname.to_str() {')
            out.append('            if s.len() > 3 && (s.ends_with("KHR") || s.ends_with("EXT")) {')
            out.append('                if let Some(a) = crate::gen::func_desc_lookup(s) { return a; }')
            out.append('            }')
            out.append('        }')
            out.append('    }')
        if route == "platform":
            # selectPlatformID fidelity (ocl-icd >= 2.3.3): NULL means
            # the default platform, and the RESOLVED id is what the
            # vendor call receives, not NULL. No default (C would then
            # deref a NULL table) -> loader-side invalid platform.
            if ret_void:
                ret_none = "return"
            elif ret_ptr or ret_u64:
                ret_none = "return core::ptr::null_mut()"
            else:
                ret_none = f"return {err_const}"
            out.append(
                f"    let {p0} = if {p0}.is_null() {{"
                f"        match default_platform_id() {{\n"
                f"            Some(p) => p,\n"
                f"            None => {{ "
                + " ".join(nb if len(nb) == 1 else nb + [ret_none])
                + " }\n"
                f"        }}\n"
                f"    }} else {{ {p0} }};")
            out.append(f"    let t = match platform_dispatch_table({p0}) {{")
            out.append("        Some(t) => t,")
            out.append("        None => {")
            out.extend("    " + l for l in indent_nb)
            out.append("        }")
            out.append("    };")
        else:
            out.append(f"    if {p0}.is_null() {{")
            out.extend(indent_nb)
            out.append("    }")
            out.append(f"    let t = object_dispatch({p0});")
        slot_expr = f'crate::dispatch::slot_of("{name}")'
        if ret_ptr:
            out.append(f"    call_by_slot(t, {slot_expr}, &[{marsh}]) as *mut c_void")
        elif ret_u64:
            out.append(f"    call_by_slot(t, {slot_expr}, &[{marsh}]) as u64")
        elif ret_void:
            out.append(f"    call_by_slot_void(t, {slot_expr}, &[{marsh}]);")
        else:
            out.append(f"    call_by_slot(t, {slot_expr}, &[{marsh}]) as cl_int")
        out.append("}")
        npad = max(0, 10 - len(params))
        pads = ",".join(f"__pad{k}" for k in range(npad))
        out.append(f"gen_entry!({name}, crate::dispatch::slot_of(\"{name}\"), {ret_rust}, ({arglist}), [{pads}], {name}_disp);")
        out.append("")
        GENERATED.add(name)

    # ── C function_description[] equivalent ──
    EXPORTED_NAMES = set(GENERATED) | (set(SPECIFIC_LOADER) - {"clGetExtensionFunctionAddress"}) | {
        "clGetExtensionFunctionAddressForPlatform", "clDeinitCompound", "clIcdGetPlatformIDsKHR"}
    out.append("/// Name -> loader export address (C: function_description[] table).")
    out.append("use crate::exports::{" + ", ".join(sorted((set(SPECIFIC_LOADER) - {"clGetExtensionFunctionAddress"}) | {"clDeinitCompound", "clIcdGetPlatformIDsKHR"})) + "};")
    out.append("pub fn func_desc_lookup(name: &str) -> Option<*mut c_void> {")
    out.append("    match name {")
    for fn_name in sorted(EXPORTED_NAMES - {"clGetICDLoaderInfoOCLICD"}):
        out.append(f'        "{fn_name}" => Some({fn_name} as *mut c_void),')
    out.append("        _ => None,")
    out.append("    }")
    out.append("}")
    out.append("")

    # ── slot address lookups ──
    out.append("/// Address of the loader's layer-facing (`_disp`) implementation of slot `slot`.")
    out.append("pub fn gen_slot_disp(slot: usize) -> *mut c_void {")
    out.append("    match slot {")
    seen_slots = set()
    for name in sorted(entries, key=lambda k: entries[k][0]):
        slot = slot_of[name]
        if name in SPECIFIC_LOADER:
            # hand-written specials claim their slot FIRST (they are the
            # authoritative implementation; generated dup-name slots lose)
            ln = LOADER_DISP_NAMES.get(name)
            if ln:
                seen_slots.add(slot)
                out.append(f"        {slot} => {ln} as *mut c_void,")
            continue
        if slot in seen_slots or name not in GENERATED:
            continue
        seen_slots.add(slot)
        out.append(f"        {slot} => {name}_disp as *mut c_void,")
    out.append("        _ => core::ptr::null_mut(),")
    out.append("    }")
    out.append("}")
    out.append("")
    out.append("/// Address of the post-deinit (`_unsupp`) variant of slot `slot`:")
    out.append("/// sets errcode_ret = CL_INVALID_OPERATION when the signature carries one.")
    out.append("pub fn gen_slot_unsupp(slot: usize) -> *mut c_void {")
    out.append("    match slot {")
    seen_slots = set()
    stub_defs = []
    stub_defs_named = [set()]
    for name in sorted(entries, key=lambda k: entries[k][0]):
        slot = slot_of[name]
        if name in SPECIFIC_LOADER or slot in seen_slots:
            continue
        seen_slots.add(slot)
        _s, ret_rust, ret_ptr, ret_void, ret_u64, params = entries[name]
        nargs = len(params)
        eidx = next((j for j, (_t, pn) in enumerate(params) if pn == "errcode_ret"), None)
        if eidx is not None and eidx >= 10:
            # errcode_ret travels on the stack (>10 args); writing a register
            # alias would corrupt another arg -> degrade to plain NULL return
            eidx = None
        if eidx is not None:
            fn = f"us_err_s{slot}_a{eidx}"
            if fn not in stub_defs_named[0]:
                stub_defs_named[0].add(fn)
                stub_defs.append(
                    "extern \"C\" fn %s(a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize) -> usize {\n"
                    "    unsafe {\n        let __a = [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9];\n"
                    "        if __a[%d] != 0 { *(__a[%d] as *mut cl_int) = CL_INVALID_OPERATION; }\n    }\n"
                    "    0\n}" % (fn, eidx, eidx))
            out.append(f"        {slot} => {fn} as *mut c_void,")
        elif ret_ptr or name in NON_STANDARD_ERROR:
            out.append(f"        {slot} => unsupp_null as *mut c_void,")
        elif ret_void:
            out.append(f"        {slot} => unsupp_void as *mut c_void,")
        else:
            out.append(f"        {slot} => unsupp_int as *mut c_void,")
    # hand-written specials need deinit stubs too (C fills these with their
    # own _unsupp variants): clGetPlatformInfo sets errcode_ret, ext-address
    # lookups return NULL.
    out.append("        1 => unsupp_int as *mut c_void, // clGetPlatformInfo (no errcode_ret param: plain -59)")
    out.append("        65 => unsupp_null as *mut c_void, // clGetExtensionFunctionAddress")

    out.append("        _ => core::ptr::null_mut(),")
    out.append("    }")
    out.append("}")
    stubs = list(stub_defs)
    out.extend(stubs)
    out.append("""
extern "C" fn unsupp_int(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize) -> cl_int {
    CL_INVALID_OPERATION
}
extern "C" fn unsupp_null(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize) -> usize {
    0
}
extern "C" fn unsupp_void(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize) {}
extern "C" fn unsupp_errcode(_a0: usize, _a1: usize, _a2: usize, _a3: usize, _a4: usize, a5: usize) -> usize {
    unsafe {
        if a5 != 0 {
            *(a5 as *mut cl_int) = CL_INVALID_OPERATION;
        }
    }
    0
}
""")
    for name, why in skipped:
        out.append("// SKIPPED %s: %s" % (name, why))

    open(os.path.join(REPO, "src/gen_forwarders.rs"), "w").write("\n".join(out) + "\n")
    print("generated: %d functions; skipped: %d"
          % (len([k for k in entries if k not in SPECIFIC_LOADER]) - len(skipped), len(skipped)))
    for name, why in skipped:
        print("  skipped %s (%s)" % (name, why))

if __name__ == "__main__":
    main()
