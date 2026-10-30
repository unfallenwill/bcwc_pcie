#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
trace-offsets.py — 把 Apple kext 中某个寄存器偏移的使用点定位到具体函数。

用法:
  trace-offsets.py <asm file> <offset> [<offset> ...]
  trace-offsets.py <asm file> --range 0xc0000-0xc0024
"""
import re
import sys

FUNC_RE = re.compile(r'^([0-9a-f]{16}) <([^>]+)>:')
OFF_RE = re.compile(r'\b(mov[a-z]*|lea)\s+(?:%\w+,)?(0x[0-9a-f]+)\(')
INSN_RE = re.compile(r'^\s+([0-9a-f]+):\t(.*)$')


def load(path):
    """返回 [(func_name, addr, insn_text), ...]"""
    out = []
    func = '<unknown>'
    addr = ''
    for line in open(path, encoding='utf-8', errors='replace'):
        m = FUNC_RE.match(line)
        if m:
            addr, func = m.group(1), m.group(2)
            continue
        m = INSN_RE.match(line)
        if m:
            out.append((func, m.group(1), m.group(2).strip()))
    return out


def main():
    path = sys.argv[1]
    want = set()
    for a in sys.argv[2:]:
        if a.startswith('--range'):
            continue
        want.add(int(a, 16))

    rows = load(path)
    hits = {}
    for func, addr, insn in rows:
        m = OFF_RE.search(insn)
        if not m:
            continue
        off = int(m.group(2), 16)
        if off in want:
            hits.setdefault(off, []).append((func, addr, insn))

    for off in sorted(want):
        print(f"=== 0x{off:05x} ===")
        lst = hits.get(off, [])
        if not lst:
            print("  (未找到)")
            continue
        for func, addr, insn in lst:
            short = func.replace('_ZN10AppleCamIn', 'AppleCamIn::')
            print(f"  {addr}  {short}")
            print(f"      {insn}")
        print()


if __name__ == '__main__':
    main()
