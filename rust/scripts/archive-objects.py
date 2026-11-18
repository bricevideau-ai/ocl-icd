#!/usr/bin/env python3
"""Build a static archive (convenience lib) from a cargo cdylib's objects.

rustc's link-args are harvested with a capturing pseudo-linker (arguments are
recorded, then only the -shared link is made to fail), the crate's codegen .o
files are pulled out, rlib members are extracted, and `ar` packs the union so
libtool can fold the Rust loader into libOpenCL.so as a convenience library —
with symbol versioning applied by the final link's --version-script, exactly
like the C objects.

Fails LOUDLY when no crate objects show up in the harvest: an archive of rlib
members alone links fine but exports nothing at all (silent empty loader —
the x86_64 CI failure mode, where rustc passed link inputs via a @response
file the harvester did not expand).

Usage: archive-objects.py <cargo> <manifest-dir> <out.a>
"""
import os
import re
import subprocess
import sys
import tempfile


def main():
    cargo, manifest_dir, out = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
    argv_file = tempfile.mktemp(prefix='ocl-icd-rs-link-argv-')
    rsp_file = tempfile.mktemp(prefix='ocl-icd-rs-link-rsp-')
    wrapper = tempfile.mktemp(prefix='ocl-icd-rs-link-')
    with open(wrapper, 'w') as f:
        f.write(
            '#!/bin/bash\n'
            'for a in "$@"; do\n'
            '  [ "$a" = "-shared" ] || continue\n'
            '  printf "%%s\\n" "$@" > %s\n'
            '  for b in "$@"; do\n'
            '    case "$b" in @*) [ -e "$${b#@}" ] && cp "$${b#@}" %s ;; esac\n'
            '  done\n'
            '  exit 1\n'
            'done\n'
            'exec "${CC:-cc}" "$@"\n' % (argv_file, rsp_file))
    os.chmod(wrapper, 0o755)
    env = dict(os.environ)
    env['RUSTFLAGS'] = (env.get('RUSTFLAGS', '') + ' -C linker=' + wrapper).strip()
    # cwd MUST be the manifest dir: the wrapper resolves its argv-dump paths
    # relative to cargo's cwd, and a bare relative manifest (VPATH/distcheck:
    # "rust") would otherwise pull build inputs from the parent directory.
    r = subprocess.run([cargo, 'build', '--release'], cwd=manifest_dir,
                       capture_output=True, text=True, env=env)
    if not os.path.exists(argv_file):
        sys.stderr.write('linker wrapper never invoked for a -shared link:\n'
                         + (r.stderr or '')[-500:])
        return 1
    args = []
    for l in open(argv_file):
        a = l.rstrip('\n')
        # rustc may pass inputs through a @response file (newer binutils);
        # the wrapper snapshotted it (cargo deletes it right after the failing
        # link). Without this the crate's .o files are never harvested.
        if a.startswith('@'):
            src = a[1:] if os.path.exists(a[1:]) else (rsp_file if os.path.exists(rsp_file) else None)
            if src:
                args += [x.strip() for x in open(src) if x.strip()]
            continue
        args.append(a)

    def keep(a):
        # filter by BASENAME only: newer rustc places the cdylib's own cgus
        # under target/release/build/<pkg>-<hash>/out/, and a path-substring
        # '/build' test silently discards exactly the objects we need.
        b = os.path.basename(a)
        return ('build_script' not in b
                and not re.search(r'rustc[A-Za-z0-9]+/symbols\.o$', a)
                and not (b == 'symbols.o' and '/out/' not in a))
    plain = [a for a in args if a.endswith('.o') and keep(a)]
    libs = [a for a in args if a.endswith(('.rlib', '.a')) and keep(a)]
    if not any('ocl_icd_rs' in os.path.basename(a) for a in plain):
        sys.stderr.write('no crate codegen objects among %d harvested inputs '
                         '(+%d rlibs) — refusing to write an archive that '
                         'would export nothing. argv tokens: %r\n'
                         % (len(plain), len(libs), args[:12]))
        return 1

    # rlibs contribute objects too; `ar` can't absorb them, so extract-and-pack
    tmp = tempfile.mkdtemp(prefix='ocl-icd-rs-obj-')
    final = list(plain)
    for i, o in enumerate(libs):
        d = os.path.join(tmp, 'm%d' % i)
        os.makedirs(d, exist_ok=True)
        subprocess.run(['ar', 'x', o], cwd=d, check=True, capture_output=True)
        final += [os.path.join(d, x) for x in sorted(os.listdir(d)) if x.endswith('.o')]
    if os.path.exists(out):
        os.unlink(out)
    subprocess.run(['ar', 'qc', out] + final, check=True)
    subprocess.run(['ranlib', out], check=True)
    print('archived %d objects (%d crate + %d from %d rlibs) -> %s'
          % (len(final), len(plain), len(final) - len(plain), len(libs), out),
          file=sys.stderr)


if __name__ == '__main__':
    sys.exit(main())
