#!/usr/bin/env python3
"""Build a static archive (convenience lib) from a cargo cdylib's objects.

rustc's link-args are harvested with a capturing pseudo-linker (arguments are
recorded, then the link is made to fail), the codegen .o files are pulled out,
and `ar` packs them so libtool can fold the Rust loader into libOpenCL.so as a
convenience library — with symbol versioning applied by the final link's
--version-script, exactly like the C objects.

Usage: archive-objects.py <cargo> <manifest-dir> <out.a>
"""
import os
import re
import subprocess
import sys
import tempfile


def main():
    cargo, manifest_dir, out = sys.argv[1], sys.argv[2], sys.argv[3]
    argv_file = tempfile.mktemp(prefix='ocl-icd-rs-link-argv-')
    wrapper = tempfile.mktemp(prefix='ocl-icd-rs-link-')
    with open(wrapper, 'w') as f:
        f.write(
            '#!/bin/bash\n'
            'for a in "$@"; do [ "$a" = "-shared" ] && { printf "%%s\\n" "$@" > %s; exit 1; }; done\n'
            'exec "${CC:-cc}" "$@"\n' % argv_file)
    os.chmod(wrapper, 0o755)
    env = dict(os.environ)
    env['RUSTFLAGS'] = (env.get('RUSTFLAGS', '') + ' -C linker=' + wrapper).strip()
    r = subprocess.run([cargo, 'build', '--release'], cwd=manifest_dir,
                       capture_output=True, text=True, env=env)
    if not os.path.exists(argv_file):
        sys.stderr.write('linker wrapper never invoked:\n' + (r.stderr or '')[-500:])
        return 1
    args = [l.rstrip('\n') for l in open(argv_file)]
    objs = [a for a in args
            if a.endswith(('.o', '.rlib', '.a'))
            and '/build' not in a and 'build_script' not in a
            # rustc's scratch symbols.o is deleted when the fake link "fails"
            and not re.search(r'rustc[A-Za-z0-9]+/symbols\.o$', a)]
    if not objs:
        sys.stderr.write('no objects harvested from %d args\n' % len(args))
        return 1
    # rlibs contribute objects too; `ar` can't absorb them, so extract-and-pack
    tmp = tempfile.mkdtemp(prefix='ocl-icd-rs-obj-')
    final = []
    for i, o in enumerate(objs):
        if o.endswith(('.rlib', '.a')):
            d = os.path.join(tmp, 'm%d' % i)
            os.makedirs(d, exist_ok=True)
            subprocess.run(['ar', 'x', o], cwd=d, check=True,
                           capture_output=True)
            final += [os.path.join(d, x) for x in os.listdir(d) if x.endswith('.o')]
        else:
            final.append(o)
    if os.path.exists(out):
        os.unlink(out)
    subprocess.run(['ar', 'qc', out] + final, check=True)
    subprocess.run(['ranlib', out], check=True)
    print('archived %d objects -> %s' % (len(final), out), file=sys.stderr)


if __name__ == '__main__':
    sys.exit(main())
