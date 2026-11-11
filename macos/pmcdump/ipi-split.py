#!/usr/bin/env python3
"""Split IPIs by cause from ipi-test.sh's ktrace (ktrace.ndjson + kernel.syms + kextstat.txt).

  python3 ipi-split.py DIR

Interrupt events (DBG_MACH_EXCP_INTR 0x0105): arg0 = vector; 0xde = IPI (interprocessor), 0xdd = LAPIC timer.
x86 MP events (DBG_MACH_MP 0x0190, osfmk/i386/mp.c): 0 TLB_FLUSH, 1 CPUS_CALL, 2 CPUS_CALL_LOCAL,
  3 CPUS_CALL_ACTION (arg = function), 4 CPUS_CALL_NOOP, 5-7 CPU start/deactivate.
Scheduler (DBG_MACH_SCHED 0x0140): 0x17 REMOTE_AST (an IPI to make another CPU reschedule),
  0x2f REMOTE_DEFERRED_AST, 0x30 CANCEL_REMOTE_DEFERRED_AST.
mp_rendezvous (used by e.g. SMCProcessor/PMCDump to run code on every CPU) has no trace point: it shows up only
as IPIs (vector 0xde) not explained by the other causes.
"""
import bisect
import collections
import json
import os
import sys

d = sys.argv[1]
KC_OFFSET = int(os.environ.get("KC_OFFSET", "0xe8000"), 16)   # see wake-attrib.py
syms = []
for line in open(os.path.join(d, "kernel.syms")):
    a, _, name = line.split(None, 2)
    syms.append((int(a, 16), name.strip()))
syms.sort()
saddr = [a for a, _ in syms]
kexts = []
for line in open(os.path.join(d, "kextstat.txt")):
    p = line.split()
    if len(p) > 6 and p[2].startswith("0x"):
        kexts.append((int(p[2], 16), int(p[3], 16), p[5]))


def sym(addr):
    for base, size, name in kexts:
        if base <= addr < base + size:
            return f"{name}+0x{addr - base:x}"
    i = bisect.bisect_right(saddr, addr - KC_OFFSET) - 1
    if i >= 0 and addr - KC_OFFSET - saddr[i] < 0x10000:
        return syms[i][1]
    return hex(addr)


def num(x):
    return int(x, 0) if isinstance(x, str) else (x or 0)


events = []
for l in open(os.path.join(d, "ktrace.ndjson"), errors="replace"):
    l = l.strip()
    if l.startswith("{"):
        try:
            events.append(json.loads(l))
        except ValueError:
            pass
if not events:
    raise SystemExit("no ktrace events - see ktrace.err")
ts = [num(e.get("timestampns", e.get("timestamp", 0))) for e in events]
secs = max((max(ts) - min(ts)) / 1e9, 1.0)

vec = collections.Counter(); ipi_cpu = collections.Counter(); mp = collections.Counter(); sched = collections.Counter()
actions = collections.Counter()
for e in events:
    dbg = e.get("debugid", e.get("debugId"))
    dbg = num(dbg)
    if not dbg:
        continue
    code, fn = dbg & ~3, dbg & 3
    args = e.get("args") or []
    cpu = e.get("cpuid", e.get("cpu"))
    if (dbg >> 16) == 0x0105 and fn == 1 and args:
        v = num(args[0])
        vec[v] += 1
        if v == 0xde:
            ipi_cpu[cpu] += 1
    elif (dbg >> 16) == 0x0190 and fn != 2:
        sub = (code >> 2) & 0x3FFF
        mp[sub] += 1
        if sub == 3 and args:
            actions[sym(num(args[0]))] += 1
    elif (dbg >> 16) == 0x0140 and fn != 2:
        sub = (code >> 2) & 0x3FFF
        if sub in (0x17, 0x2f, 0x30):
            sched[sub] += 1

r = lambda n: f"{n / secs:7.1f}/s"
print(f"== {len(events)} events over {secs:.1f} s")
print(f"== IPIs (vector 0xde): {r(vec[0xde])}   timer (0xdd): {r(vec[0xdd])}   all interrupts: {r(sum(vec.values()))}")
print("   IPIs by CPU: " + "  ".join(f"cpu{c}:{n / secs:.0f}" for c, n in sorted(ipi_cpu.items(), key=lambda x: num(x[0]))))
names = {0: "TLB flush", 1: "cpus_call", 3: "cpus_call action", 4: "cpus_call noop", 5: "cpu fast start", 6: "cpu start", 7: "cpu deactivate"}
print("== x86 MP events")
for k, n in sorted(mp.items()):
    print(f"   {r(n)}  {names.get(k, hex(k))}")
print("   cpus_call actions: " + ("  ".join(f"{f} {n / secs:.1f}/s" for f, n in actions.most_common(8)) or "none"))
snames = {0x17: "remote AST (scheduler IPI)", 0x2f: "remote deferred AST", 0x30: "cancel remote deferred AST"}
print("== scheduler")
for k, n in sorted(sched.items()):
    print(f"   {r(n)}  {snames[k]}")
known = sched[0x17] + mp[1]
print(f"== IPIs not explained by remote AST + cpus_call (rendezvous, TLB, other): ~{max(vec[0xde] - known, 0) / secs:.0f}/s")
