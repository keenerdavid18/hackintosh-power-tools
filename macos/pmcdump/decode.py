#!/usr/bin/env python3
"""Decode PMCDump.kext's "pmc-regs" (PCH PMC registers) like Linux pmc_core does.

Prints the same views as Linux's /sys/kernel/debug/pmc_core files so the two can be compared
line by line: ltr_show (per-IP LTR, decoded like pmc_core_ltr_show), ltr_ignore, pfear (IP
power-gating: "Off" = power gated), and the live low-power-mode requirement status
(substate_requirements' "Live Status"). Names come from Linux 6.17 (linux_names.json).
  python3 decode.py            # all sections
  python3 decode.py ltr        # one section: ltr | pfear | lpm | msr (msr waits ~10 s)
"""
import json
import os
import plistlib
import struct
import subprocess
import sys

names = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "linux_names.json")))
raw = subprocess.run(["ioreg", "-a", "-r", "-c", "PMCDump", "-d1", "-w0"], capture_output=True).stdout
svc = plistlib.loads(raw) if raw.strip() else []
if not svc or "pmc-regs" not in svc[0]:
    raise SystemExit("no pmc-regs property - is PMCDump.kext loaded?")
regs, samples = svc[0]["pmc-regs"], svc[0].get("pmc-samples")
r32 = lambda off: struct.unpack_from("<I", regs, off)[0]
want = sys.argv[1] if len(sys.argv) > 1 else "all"


def ltr_ns(raw):
    """Linux pmc_core_ltr_show: snoop = bits 9:0 x 2^(5*scale 12:10) if bit 15; non-snoop = 25:16/28:26 if bit 31."""
    def dec(val, scale, req):
        return val * (1 << (5 * scale)) if req else 0
    snoop = dec(raw & 0x3FF, (raw >> 10) & 7, raw & (1 << 15))
    nonsnoop = dec((raw >> 16) & 0x3FF, (raw >> 26) & 7, raw & (1 << 31))
    return snoop, nonsnoop


pmcfg = r32(0x1818)
print(f"== PMC at 0x{svc[0].get('pmc-base', 0):X}, sample #{samples}, PM_CFG 0x{pmcfg:08x}"
      f" (read disable bit 22 {'SET - LPM/PFEAR may read 0' if pmcfg & (1 << 22) else 'clear'}),"
      f" SLP_S0 counter {r32(0x193C)}")

if want in ("all", "ltr"):
    ign = r32(0x1B0C)
    print(f"== ltr_show (LTR_IGNORE 0x{ign:08x})")
    for i, (name, off) in enumerate(names["ltr"]):
        raw = r32(off)
        s, ns = ltr_ns(raw)
        flag = " IGNORED" if i < 23 and ign & (1 << i) else ""
        print(f"{i:2} {name:20} LTR: RAW 0x{raw:08x}  Non-Snoop(ns) {ns:>10}  Snoop(ns) {s:>10}{flag}")

if want in ("all", "pfear"):
    pf = bytes(regs[0x1D90:0x1D90 + 9])
    on = [n for i, n in enumerate(names["pfear"]) if not (pf[i // 8] >> (i % 8)) & 1 and not n.startswith("RES")]
    print(f"== pfear: IPs NOT power gated (\"On\"): {', '.join(on)}")

if want in ("all", "lpm"):
    print("== live low-power-mode requirement status (Linux substate_requirements 'Live Status'; listed = NOT met)")
    for i, (mapname, bits) in enumerate(names["lpm"].items()):
        live = r32(0x1C5C + 4 * i)
        unmet = [n for n, mask in bits if isinstance(mask, int) and not live & mask]
        print(f"   {mapname.replace('tgl_', '').replace('_map', ''):24} live 0x{live:08x}  not met: {', '.join(unmet) or '-'}")

if want in ("all", "msr"):
    import time

    def msr_sample():
        out = subprocess.run(["ioreg", "-a", "-r", "-c", "PMCDump", "-d1", "-w0"], capture_output=True).stdout
        s = plistlib.loads(out)[0]
        if "msr-regs" not in s:
            raise SystemExit("no msr-regs - PMCDump 1.2+ needed")
        ents = {}
        for i in range(0, len(s["msr-regs"]), 16):
            msr, ok, val = struct.unpack_from("<IIQ", s["msr-regs"], i)
            ents[msr] = val if ok else None
        return s.get("pmc-samples"), ents

    n0, a = msr_sample()
    while True:                       # wait for two new kernel samples (~10 s apart)
        time.sleep(1)
        n1, b = msr_sample()
        if n1 is not None and n0 is not None and n1 >= n0 + 2:
            break
    e2 = a.get(0xE2)
    if e2 is not None:
        lim = {0: "C0/C1", 1: "C2", 2: "C3", 3: "C6", 4: "C7", 5: "C7s", 6: "C8", 7: "C9", 8: "C10", 15: "no limit"}
        bits = {10: "IO_MWAIT_redir", 15: "CFG_LOCK", 25: "C3_autodemote", 26: "C1_autodemote", 27: "C3_undemote",
                28: "C1_undemote", 29: "PKG_C_demote", 30: "PKG_C_undemote"}
        on = [n for b_, n in bits.items() if e2 & (1 << b_)]
        print(f"== MSR 0xE2 PKG_CST_CONFIG_CONTROL 0x{e2:016x}: package C-state limit = {lim.get(e2 & 0xF, hex(e2 & 0xF))}; set: {', '.join(on) or '-'}")
    pc = a.get(0x1FC)
    if pc is not None:
        print(f"== MSR 0x1FC POWER_CTL 0x{pc:016x}: C1E {'on' if pc & 2 else 'off'}, EE turbo {'off' if pc & (1 << 19) else 'on'}")
    dt = b[0x10] - a[0x10]
    print(f"== package C-state residency over {dt / 3e9:.1f} s (counter delta / TSC delta, like turbostat):")
    for msr, name in ((0x60D, "PC2"), (0x3F8, "PC3"), (0x3F9, "PC6"), (0x3FA, "PC7"), (0x630, "PC8"), (0x631, "PC9"), (0x632, "PC10")):
        if a.get(msr) is None or b.get(msr) is None:
            print(f"   {name:5} n/a (MSR 0x{msr:X} not readable)")
        else:
            print(f"   {name:5} {100 * (b[msr] - a[msr]) / dt:6.2f} %")
    unread = [hex(m) for m, v in a.items() if v is None]
    if unread:
        print(f"   unreadable MSRs: {', '.join(unread)}")
