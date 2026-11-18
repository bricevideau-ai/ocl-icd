#!/usr/bin/env python3
"""Generate a linker version script for the Rust loader from the C loader's
generated map (ocl_icd_loader_gen.map).

The map guarantees the Rust .so exposes the exact same symbol->OPENCL_x.y node
assignment as the C one (the ABI contract apps and dlsym consumers rely on).
Symbols the Rust build does not export (Windows-only D3D/DX9 entry points, etc.)
are dropped, since GNU ld rejects versioned definitions of absent symbols
(--no-undefined-version).

Usage: gen_map.py <c.map> <cdylib.so> <out.map>
"""
import re
import subprocess
import sys


def main():
    cmap, so, out = sys.argv[1], sys.argv[2], sys.argv[3]
    src = open(cmap).read()
    src = re.sub(r'/\*[\s\S]*?\*/', '', src)  # ld scripts have no /* */ comments
    blocks = re.findall(r'(OPENCL_[\d.]+)\s*\{([\s\S]*?)\}\s*(?:OPENCL_[\d.]+)?\s*;', src)
    defined = set()
    for line in subprocess.run(
            ['nm', '-D', '--defined-only', so], stdout=subprocess.PIPE,
            check=True).stdout.decode().splitlines():
        parts = line.split()
        if len(parts) >= 3:  # "addr type name"
            defined.add(parts[-1].split('@')[0])
    nodes, prev = [], None
    for name, body in blocks:
        syms = sorted(s for s in set(re.findall(r'(cl\w+)\s*;', body)) if s in defined)
        if not syms:
            continue
        tail = f'}} {prev};' if prev else '  local:\n    *;\n};'
        nodes.append(f'{name} {{\n  global:\n' + ''.join(f'    {s};\n' for s in syms) + tail)
        prev = name
    open(out, 'w').write('\n\n'.join(nodes) + '\n')
    print('%d symbols in %d version nodes' %
          (sum(b.count(';') for b in nodes), len(nodes)), file=sys.stderr)


if __name__ == '__main__':
    main()
