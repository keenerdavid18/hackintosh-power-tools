#!/bin/zsh
# coalesce-ab.sh (sudo): interleaved A/B/C test of macOS timer-coalescing windows vs package C-states.
#   A = defaults; B = moderate (kernel/foreground timers: 1/2 of interval, max 10 ms; tier1 20 ms);
#   C = aggressive (1/1 of interval, max 50 ms; tier1/2 100 ms). Wider windows let the kernel batch
#   timers into fewer wake-ups. Cycles A,B,C so background noise hits all three equally; restores the
#   original values at the end (also on Ctrl-C). Needs PMCDump 1.4+ for residency.py.
#   sudo zsh coalesce-ab.sh [cycles=3] [seconds=30]
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
cycles=${1:-3}; secs=${2:-30}
R=${0:A:h}/residency.py
keys=(kern.timer_coalesce_kt_scale kern.timer_coalesce_kt_ns_max kern.timer_coalesce_fp_scale kern.timer_coalesce_fp_ns_max
      kern.timer_coalesce_ts_scale kern.timer_coalesce_ts_ns_max kern.timer_coalesce_tier0_scale kern.timer_coalesce_tier0_ns_max
      kern.timer_coalesce_tier1_scale kern.timer_coalesce_tier1_ns_max kern.timer_coalesce_tier2_ns_max)
typeset -A orig
for k in $keys; do orig[$k]=$(sysctl -n $k) || { echo "missing $k"; exit 1; }; done
apply() {  # $1 = A | B | C
	local k
	for k in $keys; do sysctl -q -w $k=${orig[$k]}; done
	case $1 in
	B) for t in kt fp ts tier0; do sysctl -q -w kern.timer_coalesce_${t}_scale=1 kern.timer_coalesce_${t}_ns_max=10000000; done
	   sysctl -q -w kern.timer_coalesce_tier1_ns_max=20000000 ;;
	C) for t in kt fp ts tier0; do sysctl -q -w kern.timer_coalesce_${t}_scale=0 kern.timer_coalesce_${t}_ns_max=50000000; done
	   sysctl -q -w kern.timer_coalesce_tier1_scale=0 kern.timer_coalesce_tier1_ns_max=100000000 kern.timer_coalesce_tier2_ns_max=100000000 ;;
	esac
}
trap 'apply A; print "== restored defaults (kt ns_max $(sysctl -n kern.timer_coalesce_kt_ns_max), kt scale $(sysctl -n kern.timer_coalesce_kt_scale))"' EXIT INT TERM
log=$(mktemp)
print "== $(date)  $(pmset -g batt | head -1)  ethernet $(ifconfig en0 2>/dev/null | awk '/status/ {print $2}')  cycles $cycles x ${secs}s"
for i in {1..$cycles}; do
	for s in A B C; do
		apply $s; sleep 3
		print -r -- "$(python3 $R $secs "$s cycle $i" | head -1)" | tee -a $log
	done
done
print "== averages (A = defaults, B = moderate, C = aggressive coalescing)"
for s in A B C; do
	grep " $s cycle " $log | python3 -c "
import re, sys
rows = list(sys.stdin)
avg = lambda k: sum(float(re.search(k + r' ([\d.]+)', r).group(1)) for r in rows) / len(rows)
print(f'   $s: package {avg(\"package\"):.2f} W   PC2 {avg(\"PC2\"):.1f}%   PC6 {avg(\"PC6\"):.1f}%   PC8 {avg(\"PC8\"):.1f}%   idle {avg(\"idle\"):.1f}%   (n={len(rows)})')"
done
rm -f $log
