#!/bin/zsh
# wake-trace.sh (sudo): record what wakes the CPUs at idle, for wake-attrib.py.
#  1. ktrace: every timer callout (DECR_TIMER_CALLOUT 0x01090008, subclass DBG_MACH_EXCP_DECI) with the
#     called function (unslid) and CPU, plus interrupts (DBG_MACH_EXCP_INTR) for 15 s.
#  2. spindump of kernel_task for 10 s: the stacks of kernel threads that actually run (thread_call
#     workers show the driver behind IOTimerEventSource / thread_call timers - those callouts are only
#     traced on Apple's DEVELOPMENT kernels).
#  3. kextstat (unslid load addresses + sizes) and the kernel's symbols for symbolication.
# Leave the laptop idle (~40 s). Output: ~/Desktop/wake-trace/
#   sudo zsh wake-trace.sh
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
user=${SUDO_USER:-root}
out=$(eval echo ~$user)/Desktop/wake-trace
rm -rf $out; mkdir -p $out
print "== $(date)  $(pmset -g batt | head -1)  ethernet $(ifconfig en0 2>/dev/null | awk '/status/ {print $2}')"
print "== timer coalescing kt ns_max $(sysctl -n kern.timer_coalesce_kt_ns_max)"
sleep 5
print "== ktrace 15 s (timer callouts + interrupts)"
ktrace trace -T 15s -f S0x0109,S0x0105 --ndjson > $out/ktrace.ndjson 2> $out/ktrace.err
print "   $(wc -l < $out/ktrace.ndjson) events"
print "== spindump kernel_task 10 s"
spindump kernel_task 10 10 -file $out/kernel_task.spindump.txt >/dev/null 2>&1
kextstat > $out/kextstat.txt 2>/dev/null
nm -n /System/Library/Kernels/kernel 2>/dev/null | grep -E ' [tT] ' > $out/kernel.syms
chown -R $user $out
print "== saved $out"
