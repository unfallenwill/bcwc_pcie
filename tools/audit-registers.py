#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
audit-registers.py — 用 Apple 官方二进制当 ground truth，审计 Linux 驱动的寄存器表。

背景:
  Broadcom FaceTime HD (PCI 14e4:1570) 的 ISP/DDR 寄存器是 Apple 私有协议，
  没有公开文档。上游 Linux 驱动 (patjak/facetimehd, GPLv2) 是逆向得到的。
  为了确认它没有遗漏或写错寄存器，可以拿 Apple 自己的内核扩展
  AppleCameraInterface.kext 做交叉验证: Apple 驱动访问过的每一个 MMIO 偏移，
  都应该能在 Linux 驱动的 fthd_reg.h 里找到对应定义。

方法:
  1. 反汇编 Apple 的 kext。
  2. 在每个函数内做轻量数据流追踪, 找出持有 MMIO 基址的寄存器。
     Apple 的设备对象里有两个 MMIO 基址字段:
       this+0xfd0 -> S2 域 (DDR PHY / PCIe link)
       this+0xff0 -> ISP 域
     只有通过这两个基址(或其拷贝)的访问才算寄存器访问,
     这样可以排除把结构体字段误判成寄存器的情况。
  3. 与 fthd_reg.h 的 #define 做偏移集合比对。

用法:
  audit-registers.py --kext <AppleCameraInterface binary> --linux <fthd_reg.h>
                      [--json out.json] [--asm-out out.asm]
"""
import argparse
import collections
import json
import re
import subprocess
import sys

# ------------------------------------------------------------------ 反汇编 --

def disassemble(path):
    try:
        out = subprocess.run(['objdump', '-d', '--no-show-raw-insn', path],
                             capture_output=True, text=True, check=True)
        return out.stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"objdump 失败: {e}", file=sys.stderr)
        sys.exit(2)


FUNC_RE = re.compile(r'^([0-9a-f]{16}) <([^>]+)>:')
INSN_RE = re.compile(r'^\s+([0-9a-f]+):\t(.*?)\s*$')
MOV_MEM_RE = re.compile(r'^mov[a-z]*\s+(?:%\w+,)?(?P<off>0x[0-9a-f]+)\((?P<base>%[\w]+)\)')
MOV_REG_RE = re.compile(r'^mov[a-z]*\s+(?P<src>%[\w]+),(?P<dst>%[\w]+)$')
LOAD_BASE_RE = re.compile(
    r'^mov[a-z]*\s+0x(?P<field>fd0|ff0)\((?P<this>%r\w+)\),(?P<dst>%r\w+)$')
# 访问: mov 0xOFF(%reg),%dst  /  mov %src,0xOFF(%reg)
ACCESS_RE = re.compile(r'^mov[a-z]*\s+(?:%\w+,)?(?P<off>0x[0-9a-f]+)\((?P<base>%[\w]+)\)')
LEA_RE = re.compile(r'^lea\s+(?P<off>0x[0-9a-f]+)\((?P<base>%[\w]+)\)')

MMIO_FIELDS = ('fd0', 'ff0')


def parse_functions(asm_text):
    """把反汇编切成 [(函数名, [指令, ...]), ...]"""
    funcs = []
    name = '<unknown>'
    insns = []
    for line in asm_text.splitlines():
        m = FUNC_RE.match(line)
        if m:
            if insns:
                funcs.append((name, insns))
            name, insns = m.group(2), []
            continue
        m = INSN_RE.match(line)
        if m:
            insns.append((m.group(1), m.group(2)))
    if insns:
        funcs.append((name, insns))
    return funcs


# ------------------------------------------------------- MMIO 基址数据流 --

def scan_function(insns):
    """返回该函数内访问到的 MMIO 偏移计数。

    追踪规则(保守但足够精确):
      - `mov 0xfd0(this),%reg` / `mov 0xff0(this),%reg` -> %reg 是 MMIO 基址
      - `mov %reg,%reg2` 复制基址
      - 之后 `OFF(%base)` 的访问计入
    """
    bases = set()
    counts = collections.Counter()
    for _addr, ins in insns:
        m = LOAD_BASE_RE.match(ins)
        if m:
            bases.add(m.group('dst'))
            continue
        m = MOV_REG_RE.match(ins)
        if m and m.group('src') in bases:
            bases.add(m.group('dst'))
            continue
        for rx in (ACCESS_RE, LEA_RE):
            m = rx.match(ins)
            if m and m.group('base') in bases:
                off = int(m.group('off'), 16)
                if off >= 0x1000 and off % 4 == 0:
                    counts[off] += 1
                break
    return counts


def apple_offsets(asm_text):
    total = collections.Counter()
    per_func = {}
    for name, insns in parse_functions(asm_text):
        c = scan_function(insns)
        if c:
            per_func[name] = c
            total.update(c)
    return total, per_func


# ----------------------------------------------------------------- Linux 侧 --

DEFINE_RE = re.compile(
    r'^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\s+(0x[0-9a-fA-F]+)\s*(?:/\*.*?\*/|//.*)?$',
    re.M)


def linux_registers(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    out = collections.defaultdict(list)
    for name, val in DEFINE_RE.findall(txt):
        out[int(val, 16)].append(name)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kext', required=True, help='AppleCameraInterface 二进制')
    ap.add_argument('--linux', required=True, help='fthd_reg.h')
    ap.add_argument('--json', help='把结果写成 JSON')
    ap.add_argument('--asm-out', help='把反汇编保存到该路径')
    args = ap.parse_args()

    asm_text = disassemble(args.kext)
    if args.asm_out:
        with open(args.asm_out, 'w') as f:
            f.write(asm_text)
        print(f"反汇编已写入 {args.asm_out}")

    apple, per_func = apple_offsets(asm_text)
    linux = linux_registers(args.linux)

    app_offs = set(apple)
    lin_offs = set(linux)
    matched = sorted(app_offs & lin_offs)
    only_apple = sorted(app_offs - lin_offs)
    only_linux = sorted(lin_offs - app_offs)

    total = sum(apple.values())
    covered = sum(apple[o] for o in matched)

    print("=" * 72)
    print("FaceTime HD 寄存器交叉审计")
    print("  ground truth: Apple AppleCameraInterface.kext (macOS 10.12.6)")
    print("  被审计对象 : Linux 驱动 fthd_reg.h")
    print("=" * 72)
    print(f"Apple kext 访问的寄存器偏移 : {len(app_offs)}")
    print(f"Linux 驱动定义的寄存器偏移   : {len(lin_offs)}")
    print(f"双方重合                     : {len(matched)}")
    print(f"仅 Apple 使用                 : {len(only_apple)}")
    print(f"仅 Linux 定义                 : {len(only_linux)}")
    print()

    print("--- 重合的偏移（Linux 侧名称 / Apple 侧访问次数）---")
    for off in matched:
        print(f"  0x{off:05x}  x{apple[off]:<3} {', '.join(linux[off])}")
    print()

    print("--- 仅 Apple 使用（Linux 未定义）---")
    if only_apple:
        for off in only_apple:
            users = [n for n, c in per_func.items() if off in c]
            short = ', '.join(u.replace('_ZN10AppleCamIn', 'AppleCamIn::') for u in users[:2])
            print(f"  0x{off:05x}  x{apple[off]:<3} {short}")
    else:
        print("  (无)")
    print()

    print("--- 仅 Linux 定义（Apple kext 未使用）---")
    if only_linux:
        for off in only_linux:
            print(f"  0x{off:05x}  {', '.join(linux[off])}")
    else:
        print("  (无)")
    print()

    print("--- 访问次数覆盖率 ---")
    print(f"  Apple kext 寄存器访问共 {total} 次")
    print(f"  Linux 驱动已定义其中 {covered} 次 ({100.0*covered/total:.1f}%)")
    unmatched_uses = total - covered
    print(f"  未覆盖 {unmatched_uses} 次")
    print()

    if args.json:
        with open(args.json, 'w') as f:
            json.dump({
                'ground_truth': 'AppleCameraInterface.kext (macOS 10.12.6)',
                'apple_offsets': len(app_offs),
                'linux_offsets': len(lin_offs),
                'matched': [{'offset': f'0x{o:05x}', 'names': linux[o],
                             'apple_uses': apple[o]} for o in matched],
                'only_apple': [{'offset': f'0x{o:05x}', 'uses': apple[o],
                                'functions': [n.replace('_ZN10AppleCamIn', 'AppleCamIn::')
                                              for n in per_func if o in per_func]}
                               for o in only_apple],
                'only_linux': [{'offset': f'0x{o:05x}', 'names': linux[o]}
                               for o in only_linux],
                'apple_access_total': total,
                'coverage_pct': round(100.0 * covered / total, 2),
            }, f, indent=2, ensure_ascii=False)
        print(f"JSON 已写入 {args.json}")


if __name__ == '__main__':
    sys.exit(main())
