#!/bin/bash
# Does wake-up frequency explain macOS's PC6-instead-of-PC8? (Measured on macOS 2026-11-10: every core is
# individually deep - P-cores C7+ 87-98 %, E-cores 99.9 % - but the package sits in PC6 ~42 % / PC8 ~2 %,
# with ~500 interrupts/s: IPIs 264/s, timers 200/s, of which CPU 0's timer 136/s.)
# 1. Measures Linux's own idle wake-ups per CPU and type (/proc/interrupts) with package C-states.
# 2. Adds synthetic wake-ups - per-CPU timers and cross-CPU wake-ups (IPIs) - at increasing rates,
#    including a macOS-like mix, to find where PC8 turns into PC6.
# Run idle with the Ethernet cable UNPLUGGED (macOS reference was measured without it), screen on,
# don't touch the laptop (~8 min).
#   sudo bash wakeup-test.sh            -> ~/wakeup-test-<date>.txt
set -u
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
out=${SUDO_USER:+/home/$SUDO_USER}/wakeup-test-$(date +%F-%H%M).txt
SECS=30
pids=()
cleanup() { [[ ${#pids[@]} -gt 0 ]] && kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

irqsnap() { cat /proc/interrupts; }

# Per-CPU and per-type interrupt rates between two /proc/interrupts snapshots.
irqdiff() {  # $1 before-file $2 after-file $3 seconds
	python3 - "$1" "$2" "$3" <<'EOF'
import sys
def parse(f):
    lines = open(f).read().splitlines()
    ncpu = len(lines[0].split())
    d = {}
    for l in lines[1:]:
        p = l.split()
        if not p or not p[0].endswith(':'):
            continue
        name = p[0][:-1]
        vals = []
        for x in p[1:1 + ncpu]:
            if not x.isdigit():
                break
            vals.append(int(x))
        if len(vals) == ncpu:
            desc = ' '.join(p[1 + ncpu:])
            d[name] = (vals, desc)
    return ncpu, d
n, a = parse(sys.argv[1]); _, b = parse(sys.argv[2]); s = float(sys.argv[3])
cat = {'LOC': 'timer', 'RES': 'IPI-resched', 'CAL': 'IPI-call', 'TLB': 'IPI-tlb', 'IWI': 'IPI-irqwork'}
percpu = [0.0] * n; types = {}
for k, (v1, desc) in b.items():
    if k not in a: continue
    v0 = a[k][0]
    delta = [(y - x) / s for x, y in zip(v0, v1)]
    if sum(delta) <= 0: continue
    label = cat.get(k, f'dev:{desc.split()[-1] if desc else k}' if k.isdigit() else k)
    types[label] = types.get(label, 0) + sum(delta)
    for i, x in enumerate(delta): percpu[i] += x
print('   interrupts/s by type: ' + '  '.join(f'{k} {v:.0f}' for k, v in sorted(types.items(), key=lambda x: -x[1])) + f'  => total {sum(types.values()):.0f}/s')
print('   per CPU: ' + ' '.join(f'cpu{i}:{x:.0f}' for i, x in enumerate(percpu)))
EOF
}

measure() {  # $1 label
	sleep 3
	local f0 f1; f0=$(mktemp); f1=$(mktemp)
	irqsnap > "$f0"
	turbostat --quiet --Summary --interval $SECS --num_iterations 1 \
		--show PkgWatt,CorWatt,Pkg%pc2,Pkg%pc3,Pkg%pc6,Pkg%pc8,Pk%pc10,CPU%c7 2>/dev/null |
		awk -v l="$1" 'NR==1 {for (i=1;i<=NF;i++) h[i]=$i; next}
		     NR==2 {line=sprintf("%-40s", l); for (i=1;i<=NF;i++) line=line sprintf(" %s %s", h[i], $i); print line}' | tee -a "$out"
	irqsnap > "$f1"
	irqdiff "$f0" "$f1" $SECS | tee -a "$out"
	rm -f "$f0" "$f1"
}

# A thread pinned to one CPU waking every 1/rate s (each wake = a timer interrupt on that CPU).
timer_on() {  # $1 cpu $2 rate/s
	python3 -c "
import os, time
os.sched_setaffinity(0, {$1}); p = 1 / $2
while True: time.sleep(p)" & pids+=($!)
}
# A pinned writer on CPU A waking a reader blocked on CPU B (cross-CPU wake-up = IPI on B).
ipi_pair() {  # $1 cpuA $2 cpuB $3 rate/s
	python3 -c "
import os, time
r, w = os.pipe()
if os.fork() == 0:
    os.sched_setaffinity(0, {$2}); os.close(w)
    while os.read(r, 1): pass
os.sched_setaffinity(0, {$1}); os.close(r); p = 1 / $3
while True: time.sleep(p); os.write(w, b'x')" & pids+=($!)
}
stop_all() { cleanup; pids=(); sleep 2; }

ncpu=$(nproc)
{
	echo "== $(date)  kernel $(uname -r)  $(cat /sys/class/power_supply/BAT*/status 2>/dev/null)  CPUs $ncpu"
	ip -br link | awk '$1 ~ /^(en|eth)/ {print "== ethernet " $1 " " $2}'
	for b in /sys/class/backlight/*; do echo "== backlight $(cat $b/brightness)/$(cat $b/max_brightness)"; done
} | tee "$out"

measure "0 Linux idle baseline"

timer_on 0 136;                                     measure "1 CPU0 timer 136/s (macOS cpu0)";      stop_all
for c in $(seq 0 $((ncpu - 1))); do timer_on $c 30; done;  measure "2 every CPU timer 30/s (~${ncpu}x30)";  stop_all
for c in $(seq 0 $((ncpu - 1))); do timer_on $c 100; done; measure "3 every CPU timer 100/s";             stop_all
ipi_pair 1 2 65; ipi_pair 3 4 65; ipi_pair 5 6 65; ipi_pair 7 8 65; measure "4 cross-CPU wakeups 4x65/s (~260 IPI)"; stop_all

# macOS-like mix: CPU0 timer 136/s, ~260 IPIs/s onto even P-threads, light timers elsewhere
timer_on 0 136
ipi_pair 1 2 48; ipi_pair 3 4 47; ipi_pair 5 6 36; ipi_pair 7 8 24; ipi_pair 9 10 18
for c in 2 4; do timer_on $c 20; done; for c in 6 8 10; do timer_on $c 5; done
measure "5 macOS-like mix (~500/s)"; stop_all

measure "6 Linux idle baseline again"
echo "== done $(date)" | tee -a "$out"
chown "${SUDO_USER:-root}" "$out"
echo "saved $out"
