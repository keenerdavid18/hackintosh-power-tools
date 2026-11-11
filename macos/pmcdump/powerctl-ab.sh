#!/bin/zsh
# powerctl-ab.sh (sudo): interleaved A/B/C test of MSR 0x1FC bits 19/20 (PMCDump 1.5+).
#   A = macOS default (both set), B = bit 20 (race-to-halt off) cleared, C = both cleared (= Linux)
# Cycles A,B,C several times with short windows so background noise hits all three equally, then
# prints per-setting averages of package power and PC2/PC6/PC8. Restores the original value at the end.
#   sudo zsh powerctl-ab.sh [cycles=3] [seconds=30]
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
cycles=${1:-3}; secs=${2:-30}
R=${0:A:h}/residency.py
orig=$(sysctl -n debug.pmcdump.power_ctl) || { echo "PMCDump 1.5+ not loaded"; exit 1; }
trap 'sysctl -q -w debug.pmcdump.power_ctl=$orig; printf "== restored POWER_CTL 0x%x\n" $(sysctl -n debug.pmcdump.power_ctl)' EXIT INT TERM
typeset -A val=(A $(( orig | (1 << 19) | (1 << 20) )) B $(( (orig | (1 << 19)) & ~(1 << 20) )) C $(( orig & ~((1 << 19) | (1 << 20)) )))
log=$(mktemp)
print "== $(date)  $(pmset -g batt | head -1)  cycles $cycles x ${secs}s"
for i in {1..$cycles}; do
	for s in A B C; do
		sysctl -q -w debug.pmcdump.power_ctl=${val[$s]}
		sleep 3
		line=$(python3 $R $secs "$s cycle $i" | head -1)
		print -r -- "$(printf '0x%06x' $(sysctl -n debug.pmcdump.power_ctl)) $line" | tee -a $log
	done
done
print "== averages (A = macOS default 0xfc005b-style, B = race-to-halt opt. on, C = both on = Linux)"
for s in A B C; do
	grep " $s cycle " $log | python3 -c "
import re, sys
rows = [l for l in sys.stdin]
def avg(k):
    v = [float(re.search(k + r' ([\d.]+)', r).group(1)) for r in rows]
    return sum(v) / len(v)
print(f'   $s: package {avg(\"package\"):.2f} W   PC2 {avg(\"PC2\"):.1f}%   PC6 {avg(\"PC6\"):.1f}%   PC8 {avg(\"PC8\"):.1f}%   idle {avg(\"idle\"):.1f}%   (n={len(rows)})')"
done
rm -f $log
