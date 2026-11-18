
ACLOCAL_AMFLAGS = -I m4

SUBDIRS = . doc tests

RUBY=ruby
AM_CPPFLAGS = -Wall @AM_CPPFLAGS@

pkgconfigdir = $(libdir)/pkgconfig
pkgconfig_DATA= OpenCL.pc ocl-icd.pc

EXTRA_DIST=icd_generator.rb ocl_interface.yaml bootstrap \
	$(TESTFILES) khronos-headers

##################################################################
# Main OpenCL ICD Loader library
lib_LTLIBRARIES = libOpenCL.la
nodist_include_HEADERS = ocl_icd.h
pkgexampledir = $(docdir)/examples
pkgexample_DATA = ocl_icd_bindings.c

FILES_FROM_DATABASE = ocl_icd.h ocl_icd_loader_gen.h \
	ocl_icd_loader_gen.c ocl_icd_bindings.c \
	ocl_icd_loader_gen.map
BUILT_SOURCES = $(FILES_FROM_DATABASE)
CLEANFILES = $(FILES_FROM_DATABASE) stamp-generator
MAINTAINERCLEANFILES =

if UPDATE_DATABASE
use_system_headers=--system-headers
else
use_system_headers=
endif

# Generate sources and headers from the database
stamp-generator: ocl_interface.yaml
$(FILES_FROM_DATABASE): stamp-generator
stamp-generator: icd_generator.rb
	$(RUBY) $< --mode database --database $(srcdir)/ocl_interface.yaml \
		$(use_system_headers)
	echo "timestamp" > $@

# ignore the warning in OpenCL headers when using old interface
libOpenCL_la_CFLAGS= $(NO_DEPRECATED_DECLARATIONS_FLAGS) \
	$(AM_CFLAGS) $(PTHREAD_CFLAGS) \
	-DCL_NO_NON_ICD_DISPATCH_EXTENSION_PROTOTYPES \
	-DETC_OPENCL_VENDORS=\"@OCL_ICD_VENDORDIR@\" \
	-DETC_OPENCL_LAYERS=\"@OCL_ICD_LAYERDIR@\"

libOpenCL_la_LDFLAGS = -version-info 1:0:0 $(PTHREAD_CFLAGS)
libOpenCL_la_LIBADD = $(PTHREAD_LIBS)
if RUST_LOADER
# The Rust crate replaces the whole C loader implementation. Its objects are
# archived (rust/build-loader.sh) and linked into libOpenCL like any other
# convenience library, with the OPENCL_x.y version nodes applied by the
# version map derived from ocl_icd_loader_gen.map.
libOpenCL_la_LIBADD += rust/libocl-icd-rs.a
libOpenCL_la_LDFLAGS += -Wl,--version-script,rust/rust-loader.map \
	-Wl,--whole-archive -Wl,rust/libocl-icd-rs.a -Wl,--no-whole-archive
libOpenCL_la_DEPENDS = rust/libocl-icd-rs.a rust/rust-loader.map
else
libOpenCL_la_SOURCES = ocl_icd_loader.c ocl_icd_loader.h ocl_icd_debug.h
nodist_libOpenCL_la_SOURCES = ocl_icd_loader_gen.c ocl_icd.h
endif
if USE_MAP_AND_C
libOpenCL_la_LDFLAGS += -Wl,--version-script,ocl_icd_loader_gen.map
libOpenCL_la_DEPENDS = ocl_icd_loader_gen.map
endif

if RUST_LOADER
# rust/build-loader.sh: cargo builds the crate, its objects are archived into
# a convenience library, and a version map is derived from the C loader's
# generated map (filtered to what the crate exports) for the final libtool
# link. (The USE_MAP block below is skipped: the rust map supersedes it.)
CLEANFILES += rust/libocl-icd-rs.a rust/rust-loader.map
# cargo writes into rust/ (target/, regenerated src files); distcleancheck
# fails on anything left behind.
distclean-local::
	rm -rf rust/target rust/.cargo-home
	@if test "$(srcdir)" != "."; then \
	  rm -rf rust;   \
	fi

rust/libocl-icd-rs.a: $(srcdir)/rust/src/exports.rs $(srcdir)/rust/Cargo.toml \
		$(srcdir)/rust/build.rs $(srcdir)/ocl_interface.yaml \
		ocl_icd_loader_gen.map $(FILES_FROM_DATABASE)
	$(SHELL) $(srcdir)/rust/build-loader.sh \
		"$(srcdir)/rust" "$(CARGO)" "$(OCL_ICD_RS_VERSION)"
endif

# the crate ships in every tarball (distcheck configures the DIST with the
# flag while the outer configure is plain) — an EXTRA_DIST guarded by
# if RUST_LOADER vanishes from the default dist, as distcheck caught.
EXTRA_DIST += rust/build-loader.sh \
	rust/Cargo.toml rust/Cargo.lock rust/build.rs \
	rust/scripts/gen_bindings.py rust/scripts/gen_map.py \
	rust/scripts/archive-objects.py \
	rust/src/clib.rs rust/src/debug.rs rust/src/dispatch.rs \
	rust/src/exports.rs rust/src/gen_forwarders.rs rust/src/lib.rs \
	rust/src/registry.rs rust/src/slots.rs rust/src/types.rs

# gen_forwarders.rs/slots.rs are regenerated from ocl_interface.yaml by the
# build, so they are pruned from the tarball to keep the dist drift-proof;
# the committed copies only serve plain-git development builds.

####################################
# A utility to list loaded layers
bin_PROGRAMS = cllayerinfo

cllayerinfo_SOURCES = cllayerinfo.c ocl_icd_loader.c ocl_icd_loader.h ocl_icd_debug.h
nodist_cllayerinfo_SOURCES = ocl_icd_loader_gen.c ocl_icd.h
cllayerinfo_CFLAGS = -DCLLAYERINFO $(libOpenCL_la_CFLAGS)
cllayerinfo_LDFLAGS = $(PTHREAD_CFLAGS) $(PTHREAD_LIBS)
# NOTE: cllayerinfo never dispatches to vendors (it only dlopens layers), so it
# keeps the self-contained C loader even with --enable-rust-loader.

####################################
# A very small program test
check_PROGRAMS=ocl_test ocl_test_icdl
ocl_test_SOURCES = ocl_test.c
ocl_test_LDADD = libOpenCL.la
ocl_test_icdl_SOURCES = ocl_test_icdl.c
ocl_test_icdl_LDADD = libOpenCL.la

check_DATA = vendors/dummycl.icd vendors/dummycl2.icd vendors/dummycl-noext.icd
CLEANFILES += vendors/dummycl.icd vendors/dummycl2.icd vendors/dummycl-noext.icd
vendors/dummycl.icd:
	$(mkdir_p) vendors
	echo "$(CURDIR)/.libs/libdummycl.so" > $@

vendors/dummycl2.icd:
	$(mkdir_p) vendors
	echo "$(CURDIR)/.libs/libdummycl2.so" > $@

vendors/dummycl-noext.icd:
	$(MKDIR_P) vendors
	echo "$(CURDIR)/.libs/libdummycl-noext.so" > $@

clean-local: mostlyclean-generic clean-generic
	-rmdir vendors

##################################################################
# dummy OpenCL ICD
FILES_FROM_GENERATOR = run_dummy_icd_gen.c run_dummy_icd_weak_gen.c \
	libdummy_icd_gen.c libdummy_icd_gen.h dummy_icd_layer_gen.c
BUILT_SOURCES += $(FILES_FROM_GENERATOR)
CLEANFILES += $(FILES_FROM_GENERATOR) stamp-generator-dummy

# Generate sources and headers from OpenCL installed headers
$(FILES_FROM_GENERATOR): stamp-generator-dummy
stamp-generator-dummy: icd_generator.rb
stamp-generator-dummy: icd_generator.rb
	$(RUBY) $< --mode generate --database $(srcdir)/ocl_interface.yaml
	echo "timestamp" > $@

# noinst_LTLIBRARIES would be the correct thing but then libtool
# only built non shared version :-( So, declaring the libs as
# pkglib_LTLIBRARIES and using an install hook to remove them.
pkglib_LTLIBRARIES = libdummycl.la libdummycl2.la libdummycl-noext.la libdummylayer.la
install-exec-hook::
	$(RM) -r $(DESTDIR)$(pkglibdir)
libdummycl_la_SOURCES = libdummy_icd.c libdummy_icd.h
nodist_libdummycl_la_SOURCES = libdummy_icd_gen.c libdummy_icd_gen.h
libdummycl_la_LDFLAGS = -module
libdummycl_noext_la_SOURCES = $(libdummycl_la_SOURCES)
nodist_libdummycl_noext_la_SOURCES = $(nodist_libdummycl_la_SOURCES)
libdummycl_noext_la_LDFLAGS = -module
libdummycl_noext_la_CPPFLAGS = $(AM_CPPFLAGS) -DICD_WITHOUT_EXTENSION
libdummycl2_la_SOURCES = $(libdummycl_la_SOURCES)
nodist_libdummycl2_la_SOURCES = $(nodist_libdummycl_la_SOURCES)
libdummycl2_la_LDFLAGS = -module
libdummycl2_la_CPPFLAGS = $(AM_CPPFLAGS) -DICD_SUFFIX=\"2\"
nodist_libdummylayer_la_SOURCES = dummy_icd_layer_gen.c
libdummylayer_la_LDFLAGS = -module

noinst_PROGRAMS=run_dummy_icd_through_our_ICDL
run_dummy_icd_through_our_ICDL_SOURCES = run_dummy_icd.c
nodist_run_dummy_icd_through_our_ICDL_SOURCES = \
	run_dummy_icd_gen.c run_dummy_icd_weak_gen.c
# ignore the warning in OpenCL headers when using old interface
run_dummy_icd_through_our_ICDL_CFLAGS= $(NO_DEPRECATED_DECLARATIONS_FLAGS) $(AM_CFLAGS)
# we want to link to our implementation here
run_dummy_icd_through_our_ICDL_LDADD = libOpenCL.la
#
run_dummy_icd_through_our_ICDL_CPPFLAGS = $(AM_CPPFLAGS) -DOCL_ICD_PRINT_EXPECTED

##################################################################
# rules to update the database from an already installed ICD Loader
if UPDATE_DATABASE

noinst_PROGRAMS += run_dummy_icd
run_dummy_icd_SOURCES = \
	$(run_dummy_icd_through_our_ICDL_SOURCES)
nodist_run_dummy_icd_SOURCES = \
	$(nodist_run_dummy_icd_through_our_ICDL_SOURCES)
run_dummy_icd_CFLAGS= \
	$(run_dummy_icd_through_our_ICDL_CFLAGS)
# we do not want to link to our implementation here
run_dummy_icd_LDADD = -lOpenCL
run_dummy_icd_LINK = $(CCLD) $(AM_CFLAGS) $(CFLAGS) $(AM_LDFLAGS) $(LDFLAGS) -o $@

# run the test program and update the database
run_dummy_icd_output.yaml: run_dummy_icd install_test_lib libdummycl.la
	"$$(dirname $<)/$$(basename $<)" > $@
	@if grep -v -E '^(---|([0-9]* *: .*))$$' $@ ; then \
		echo "Invalid $@ file, trying to fix it" ; \
		grep -E '^(---|([0-9]* *: .*))$$' $@ > $@.fix ;\
		mv $@.fix $@ ;\
	fi

CLEANFILES += run_dummy_output.yaml
.PHONY: update-database
update-database: icd_generator.rb run_dummy_icd_output.yaml
	$(RUBY) $< --mode update-database \
		--database $(srcdir)/ocl_interface.yaml \
		--input run_dummy_icd_output.yaml

.PHONY: install_test_lib uninstall_test_lib
install_test_lib:
	sudo bash -c 'echo "$(CURDIR)/.libs/libdummycl.so" > /etc/OpenCL/vendors/dummycl.icd'

uninstall_test_lib:
	sudo rm -f /etc/OpenCL/vendors/dummycl.icd

else
.PHONY: update-database
update-database:
	@echo You need to reconfigure this software with --enable-update-database
	@exit 1
endif
##################################################################
