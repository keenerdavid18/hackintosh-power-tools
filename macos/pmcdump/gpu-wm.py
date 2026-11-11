#!/usr/bin/env python3
"""Decode / compare iGPU display watermark registers (NootedGreen issue #34 display-watermark lead).

  python3 gpu-wm.py                       macOS: read PMCDump 1.6's "gpu-regs" from ioreg, decode,
                                          and save macos/results/gpu-regs-macos-<date>.txt
  python3 gpu-wm.py FILE                  decode a saved dump (macOS or linux/gpu-regs.sh output)
  python3 gpu-wm.py MACOS_FILE LINUX_FILE side-by-side comparison of the registers that differ

Register layout (i915, display version 12/13): per pipe base 0x70000 + 0x1000*pipe.
  CUR_CTL +0x080, CUR_WM(level) +0x140+4*l, CUR_WM_TRANS +0x168, CUR_BUF_CFG +0x17C
  plane n (1-4): PLANE_CTL +0x180+0x100*(n-1), PLANE_WM(level) +0x240+..+4*l, PLANE_WM_TRANS +0x268,
                 PLANE_BUF_CFG +0x27C
  WM value: bit 31 enable, bit 30 ignore lines, lines bits 26:14, blocks bits 10:0.
  On display 12+, WM "levels" 6 and 7 (+0x258/+0x25C, cursor +0x158/+0x15C) are the SAGV watermarks.
  BUF_CFG: start bits 11:0, end bits 27:16 (DDB blocks).
  DC_STATE_EN 0x45504: bits 1:0 = 1 DC5, 2 DC6 allowed. DMC DC5/DC6 counters 0x101084/0x101088.
"""
import datetime
import os
import plistlib
import re
import subprocess
import sys

# Keep in sync with PMCDump.cpp kGpuRanges and linux/gpu-regs.sh.
RANGES = [(0x44FE0, 0x45040), (0x45270, 0x45280), (0x45500, 0x45530), (0x60000, 0x60080), (0x61000, 0x61080),
          (0x70000, 0x70600), (0x71000, 0x71600), (0x72000, 0x72600), (0x73000, 0x73600), (0x101080, 0x101090)]
OFFS = [o for a, b in RANGES for o in range(a, b, 4)]
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def from_ioreg():
    out = subprocess.run(["ioreg", "-a", "-r", "-c", "PMCDump", "-d", "1"], capture_output=True).stdout
    if not out:
        raise SystemExit("PMCDump not loaded")
    node = plistlib.loads(out)[0]
    data = node.get("gpu-regs")
    if not data:
        raise SystemExit("PMCDump loaded but no gpu-regs (needs 1.6; GPU not found yet?)")
    vals = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
    return dict(zip(OFFS, vals)), f"macOS PMCDump, BAR0 {node.get('gpu-bar0', 0):#x}, sample {node.get('pmc-samples')}"


def from_file(path):
    regs, head = {}, []
    for line in open(path, errors="replace"):
        m = re.match(r"\s*(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s*$", line)
        if m:
            regs[int(m.group(1), 16)] = int(m.group(2), 16)
        elif line.startswith("==") and len(head) < 4:
            head.append(line.strip().lstrip("= "))
    return regs, " | ".join(head) or path


def wm(v):
    if not v & (1 << 31):
        return "  off"
    lines = (v >> 14) & 0x1FFF
    blocks = v & 0x7FF
    return f"{blocks:4d}b/{lines:3d}l" + ("i" if v & (1 << 30) else "")


def buf(v):
    s, e = v & 0xFFF, (v >> 16) & 0xFFF
    return f"{s}-{e}" if v else "-"


def decode(regs, title):
    r = lambda o: regs.get(o, 0)
    print(f"== {title}")
    dc = r(0x45504)
    print(f"DC_STATE_EN {dc:#010x} (allowed: {['none', 'DC5', 'DC6', '?'][dc & 3]})   DMC DC5 count {r(0x101084)}  DC6 count {r(0x101088)}")
    print(f"DBUF_CTL_S1 {r(0x45008):#010x}  DBUF_CTL_S2 {r(0x44FE8):#010x}  ARB_CTL {r(0x45000):#010x}  MBUS_ABOX_CTL {r(0x45038):#010x}")
    print("WM_LINETIME " + "  ".join(f"{chr(65 + p)}:{r(0x45270 + 4 * p):#x}" for p in range(4)))
    for p in range(4):
        base = 0x70000 + 0x1000 * p
        planes = []
        if r(base + 0x80) & 0x27:
            planes.append(("cursor", base + 0x140, base + 0x168, base + 0x17C))
        for n in range(1, 5):
            pb = base + 0x180 + 0x100 * (n - 1)
            if r(pb) & (1 << 31):
                planes.append((f"plane{n}", pb + 0xC0, pb + 0xE8, pb + 0xFC))
        if not planes:
            continue
        print(f"-- pipe {chr(65 + p)}   (levels L0-L5, SAGV, SAGV-trans, trans; b = blocks, l = lines)")
        for name, wm0, trans, bcfg in planes:
            lv = "  ".join(wm(r(wm0 + 4 * l)) for l in range(6))
            sagv = f"{wm(r(wm0 + 0x18))} {wm(r(wm0 + 0x1C))}"
            enabled = sum(1 for l in range(6) if r(wm0 + 4 * l) >> 31)
            print(f"   {name:7s} buf {buf(r(bcfg)):9s} levels on {enabled}/6: {lv} | sagv {sagv} | trans {wm(r(trans))}")


def compare(a, b, ta, tb):
    print(f"== A: {ta}\n== B: {tb}")
    diff = [o for o in OFFS if a.get(o) != b.get(o)]
    print(f"== {len(diff)} of {len(OFFS)} registers differ (watermark/buffer/DC ones listed)")
    for o in diff:
        rel = o & 0xFFF
        interesting = o >= 0x70000 and o < 0x74000 and (0x140 <= rel < 0x180 or (rel - 0x180) % 0x100 >= 0xC0) or o < 0x46000 or o > 0x100000
        if interesting:
            print(f"   {o:#08x}  A {a.get(o, 0):#010x}  B {b.get(o, 0):#010x}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        regs, title = from_ioreg()
        decode(regs, title)
        path = os.path.join(REPO, "macos", "results", f"gpu-regs-macos-{datetime.datetime.now():%Y-%m-%d-%H%M}.txt")
        with open(path, "w") as f:
            f.write(f"== {datetime.datetime.now()}  {title}\n== regs\n")
            f.writelines(f"{o:#08x} {regs[o]:#010x}\n" for o in OFFS)
        print(f"saved {path}")
    elif len(args) == 1:
        decode(*from_file(args[0]))
    else:
        (a, ta), (b, tb) = from_file(args[0]), from_file(args[1])
        decode(a, "A " + ta)
        decode(b, "B " + tb)
        compare(a, b, ta, tb)
