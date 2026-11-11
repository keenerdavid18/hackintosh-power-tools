#!/usr/bin/env python3
"""Summarise ~/Desktop/wake-trace (from wake-trace.sh): who causes the timer wake-ups.

- Timer callouts per second by function (kernel symbol or kext+offset) and by CPU.
- Interrupts per second by vector and CPU.
- kernel_task threads from the spindump whose stacks contain kext frames (what thread_call
  timers run), with sample counts.
  python3 wake-attrib.py [dir]
"""
import bisect
import collections
import json
import os
import re
import sys

d = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Desktop/wake-trace")

# --- symbolication: kernel symbols (unslid) and kext ranges from kextstat (unslid load addresses)
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


# Timer-callout addresses are unslid addresses of the kernel inside the boot kernel collection, which
# sits KC_OFFSET above the same function in /System/Library/Kernels/kernel (0xe8000 on 25G241:
# _thread_call_delayed_timer 0x...2d4150 in the file shows up as 0x...3bc150).
KC_OFFSET = int(os.environ.get("KC_OFFSET", "0xe8000"), 16)


def sym(addr):
    for base, size, name in kexts:
        if base <= addr < base + size:
            return f"{name}+0x{addr - base:x}"
    i = bisect.bisect_right(saddr, addr - KC_OFFSET) - 1
    if i >= 0 and addr - KC_OFFSET - saddr[i] < 0x10000:
        off = addr - KC_OFFSET - saddr[i]
        return f"kernel:{syms[i][1]}" + (f"+0x{off:x}" if off else "")
    return hex(addr)


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
ts = [int(e.get("timestampns", e.get("timestamp", 0))) for e in events]
span_ns = (max(ts) - min(ts)) or 1
secs = span_ns / 1e9 if span_ns > 1e6 else 15.0


def g(e, *keys):
    for k in keys:
        if k in e:
            return e[k]
    return None


callouts = collections.Counter(); per_cpu = collections.Counter(); intr = collections.Counter(); vec = collections.Counter()
by_cpu_func = collections.Counter()
for e in events:
    dbg = g(e, "debugid", "debugId")
    if isinstance(dbg, str):
        dbg = int(dbg, 16)
    if dbg is None:
        continue
    code = dbg & ~0x3          # strip DBG_FUNC start/end
    cpu = g(e, "cpuid", "cpu")
    if code == 0x01090008 and (dbg & 3) == 1:          # DECR_TIMER_CALLOUT start
        args = e.get("args") or []
        func = args[1] if len(args) > 1 else g(e, "arg2")
        func = int(func, 0) if isinstance(func, str) else func
        callouts[sym(func)] += 1
        per_cpu[cpu] += 1
        by_cpu_func[(cpu, sym(func))] += 1
    elif (dbg >> 16) == 0x0105 and (dbg & 3) == 1:      # interrupt start
        intr[cpu] += 1
        args = e.get("args") or []
        if args:
            vec[int(args[0], 0) if isinstance(args[0], str) else args[0]] += 1

print(f"== {len(events)} events over {secs:.1f} s")
print("== timer callouts/s by function (top 25)")
for f, n in callouts.most_common(25):
    print(f"   {n / secs:7.1f}/s  {f}")
print("== timer callouts/s by CPU: " + "  ".join(f"cpu{c}:{n / secs:.0f}" for c, n in sorted(per_cpu.items())))
print("== CPU 0 callouts/s by function: " + "  ".join(f"{f} {n / secs:.0f}" for (c, f), n in by_cpu_func.most_common() if c == 0)[:600])
print("== interrupt arg0 (vector?) top: " + "  ".join(f"{v:#x}:{n / secs:.0f}" for v, n in vec.most_common(8)))
print("== interrupts/s by CPU:     " + "  ".join(f"cpu{c}:{n / secs:.0f}" for c, n in sorted(intr.items())))

# --- spindump: kernel_task threads with kext frames
sp = os.path.join(d, "kernel_task.spindump.txt")
if os.path.exists(sp):
    text = open(sp, errors="replace").read()
    print("== kernel_task threads running kext code (spindump samples)")
    for block in re.split(r"\n\s*Thread 0x", text)[1:]:
        head = block.splitlines()[0]
        m = re.search(r"(\d+) samples", head)
        frames = re.findall(r"\d+\s+(\S+)\s+\+\s+\d+\s+\(([^)]+)\)", block)
        kx = [f"{fn} ({mod})" for fn, mod in frames if not mod.startswith("kernel") and mod not in ("com.apple.kernel",)]
        if kx and m:
            print(f"   {m.group(1):>5} samples  {head[:60].strip()}  -> {'; '.join(dict.fromkeys(kx).keys())[:240]}")
