#!/bin/sh
# Build the Rust loader into $(builddir)/rust:
#   rust/libocl-icd-rs.a   convenience library linked into libOpenCL.la
#   rust/rust-loader.map   OPENCL_x.y version script for the final link
#
# Invoked from Makefile with:
#   build-loader.sh <srcdir>/rust <CARGO> <version>
#
# The version map is the C loader's generated map (ocl_icd_loader_gen.map)
# filtered to the symbols the crate actually exports, so the installed
# libOpenCL.so carries the same ABI nodes as the C build.
set -e
SRCDIR_RUST="$1"
CARGO="${2:-cargo}"
VERSION="$3"
TOP="$(pwd)"

BUILDDIR="$TOP/rust"
mkdir -p "$BUILDDIR"
if [ "$(cd "$SRCDIR_RUST" && pwd)" != "$(cd "$BUILDDIR" 2>/dev/null && pwd || echo none)" ]; then
  # out-of-tree (VPATH/distcheck): materialise the crate in the build dir
  mkdir -p "$BUILDDIR/src" "$BUILDDIR/scripts"
  cp -a "$SRCDIR_RUST/src/"* "$BUILDDIR/src/"
  cp -a "$SRCDIR_RUST/scripts/"* "$BUILDDIR/scripts/"
  for f in Cargo.toml build.rs; do cp -a "$SRCDIR_RUST/$f" "$BUILDDIR/$f"; done
fi
# regenerate the bindings from the interface database (slot indices never drift)
python3 "$BUILDDIR/scripts/gen_bindings.py" "$TOP/ocl_interface.yaml"

export OCL_ICD_RS_VERSION="$VERSION"
unset OCL_ICD_RS_MAP
cd "$BUILDDIR"
# 1. unversioned cdylib (source of truth for which symbols exist)
"$CARGO" build --release
# 2. version map, filtered against the cdylib export list
python3 scripts/gen_map.py "$TOP/ocl_icd_loader_gen.map" \
	"target/release/libocl_icd_rs.so" rust-loader.map
# 3. static archive of the crate objects for libtool
python3 scripts/archive-objects.py "$CARGO" . libocl-icd-rs.a
