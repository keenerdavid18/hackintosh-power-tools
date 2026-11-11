#!/usr/bin/env python3
"""Real package and per-core C-state residency from PMCDump.kext (1.4+), like turbostat.

Takes two snapshots N seconds apart (default 45) and prints package power (RAPL), package PC2-PC10
residency (read on CPU 0) and, per logical CPU, core type and C6 / C7-or-deeper residency.
Run it while the machine is otherwise idle; anything you run meanwhile shows up as C0.
  python3 residency.py [seconds] [label]
"""
import plistlib
import struct
import subprocess
import sys
import time

TSC_HZ = 2.995e9


def snap():
    s = plistlib.loads(subprocess.run(["ioreg", "-a", "-r", "-c", "PMCDump", "-d1", "-w0"], capture_output=True).stdout)[0]
    msrs = {m: (v if ok else None) for m, ok, v in (struct.unpack_from("<IIQ", s["msr-regs"], i) for i in range(0, len(s["msr-regs"]), 16))}
    cores = {}
    raw = s.get("core-regs", b"")
    for cpu in range(len(raw) // 48):
        valid, ctype, tsc, c3, c6, c7, mc6 = struct.unpack_from("<IIQQQQQ", raw, cpu * 48)
        if valid:
            cores[cpu] = (ctype, tsc, c3, c6, c7, mc6)
    return msrs, cores


secs = int(sys.argv[1]) if len(sys.argv) > 1 else 45
label = sys.argv[2] if len(sys.argv) > 2 else ""
a, ca = snap()
time.sleep(secs)
b, cb = snap()

dt = b[0x10] - a[0x10]
unit = 1 / (1 << ((a[0x606] >> 8) & 0x1F))
watts = ((b[0x611] - a[0x611]) & 0xFFFFFFFF) * unit / (dt / TSC_HZ)
pkg = {n: 100 * (b[m] - a[m]) / dt for m, n in ((0x60D, "PC2"), (0x3F8, "PC3"), (0x3F9, "PC6"), (0x3FA, "PC7"),
                                                 (0x630, "PC8"), (0x631, "PC9"), (0x632, "PC10")) if a.get(m) is not None}
print(f"== {label} over {dt / TSC_HZ:.0f} s: package {watts:.2f} W  " + "  ".join(f"{k} {v:.1f}%" for k, v in pkg.items())
      + f"  (idle {sum(pkg.values()):.1f}%)")

NA = (1 << 64) - 1
pct = lambda x0, x1, t: "  n/a" if NA in (x0, x1) else f"{100 * (x1 - x0) / t:5.1f}"
types = {0x40: "P", 0x20: "E"}
for cpu in sorted(cb):
    if cpu not in ca:
        continue
    t0, s0, _, c60, c70, m60 = ca[cpu]
    _, s1, _, c61, c71, m61 = cb[cpu]
    t = s1 - s0
    print(f"   cpu{cpu:<2} {types.get(t0, hex(t0))}-core  C6 {pct(c60, c61, t)}%  C7+ {pct(c70, c71, t)}%"
          + (f"  module-C6 {pct(m60, m61, t)}%" if NA not in (m60, m61) else ""))
