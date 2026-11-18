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
  # distcheck ships the tarball read-only; generation writes into src/
  chmod -R u+w "$BUILDDIR"
fi
# Generate the Rust slot tables (src/slots.rs, src/gen_forwarders.rs) with
# the SAME interpreter and database the C loader's generated files come from:
# icd_generator.rb --mode rust-generate. One generator, one YAML parser,
# zero crate dependencies (the port oracle lives in rust/scripts/).
YAML="$SRCDIR_RUST/../ocl_interface.yaml"
for c in "$TOP/ocl_interface.yaml" "$(dirname "$SRCDIR_RUST")/ocl_interface.yaml" "$TOP/../ocl_interface.yaml"; do
  [ -f "$c" ] && YAML="$c" && break
done
[ -f "$YAML" ] || { echo "build-loader: cannot locate ocl_interface.yaml" >&2; exit 1; }
YAML="$(cd "$(dirname "$YAML")" && pwd)/ocl_interface.yaml"
GENRB="$TOP/icd_generator.rb"
[ -f "$GENRB" ] || GENRB="$(dirname "$YAML")/icd_generator.rb"
[ -f "$GENRB" ] || { echo "build-loader: cannot locate icd_generator.rb" >&2; exit 1; }
# absolutize: the script cd's into $BUILDDIR before invoking ruby, and a
# relative path would resolve against the wrong tree under VPATH/distcheck
GENRB="$(cd "$(dirname "$GENRB")" && pwd)/icd_generator.rb"
ruby "$GENRB" --mode rust-generate --database "$YAML" \
  --rust-slots "$BUILDDIR/src/slots.rs" --rust-gen "$BUILDDIR/src/gen_forwarders.rs"

export OCL_ICD_RS_VERSION="$VERSION"
unset OCL_ICD_RS_MAP
cd "$BUILDDIR"
# 1. unversioned cdylib (source of truth for which symbols exist)
"$CARGO" build --release
# 2. version map, filtered against the cdylib export list
ruby "$GENRB" --mode rust-map --c-map "$TOP/ocl_icd_loader_gen.map" \
  --cdylib target/release/libocl_icd_rs.so --out rust-loader.map
# 3. static archive of the crate objects for libtool
ruby "$GENRB" --mode rust-archive --cargo "$CARGO" --manifest-dir . --out libocl-icd-rs.a
