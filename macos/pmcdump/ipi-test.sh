#!/bin/zsh
# ipi-test.sh (sudo): idle residency + interrupt/IPI rates + IPI causes, for the SMCProcessor A/B (NootedGreen issue #34).
#   1. 20 s settle, then residency.py 60 s (needs PMCDump 1.4+)
#   2. powermetrics interrupts 15 s (IPIs and timer interrupts per CPU)
#   3. ktrace 15 s: interrupts (vector 0xde = IPI, 0xdd = timer), x86 MP events (DBG_MACH_MP 0x90: TLB flush,
#      cpus_call + the called function) and scheduler events (remote AST = scheduler IPI). ipi-split.py decodes it.
# Unplug Ethernet (it caps the package at PC3), quit apps, don't touch the laptop for ~2 minutes.
#   sudo zsh ipi-test.sh LABEL        (e.g. smcproc-on / smcproc-off)
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
label=${1:?label, e.g. smcproc-on}
here=${0:A:h}
user=${SUDO_USER:-root}
out=${here:h}/results/ipi-test-$label-$(date +%Y-%m-%d-%H%M)
mkdir -p $out
{
print "== $(date)  $label  $(pmset -g batt | head -1)  ethernet $(ifconfig en0 2>/dev/null | awk '/status/ {print $2}')"
print "== boot-args: $(nvram boot-args 2>/dev/null | cut -f2)"
print "== SMCProcessor loaded: $(kextstat 2>/dev/null | grep -c SMCProcessor)   timer coalescing kt ns_max $(sysctl -n kern.timer_coalesce_kt_ns_max)"
} | tee $out/info.txt
print "== settling 20 s - hands off"
sleep 20
print "== residency 60 s"
python3 $here/residency.py 60 $label | tee $out/residency.txt
print "== powermetrics interrupts 15 s"
powermetrics -s interrupts -i 15000 -n 1 > $out/powermetrics-interrupts.txt 2>&1
grep -E "CPU [0-9]+:|IPI|Timer|Total" $out/powermetrics-interrupts.txt | head -40
print "== ktrace 15 s"
ktrace trace -T 15s -f S0x0105,S0x0190,S0x0140 --ndjson > $out/ktrace.ndjson 2> $out/ktrace.err
kextstat > $out/kextstat.txt 2>/dev/null
nm -n /System/Library/Kernels/kernel 2>/dev/null | grep -E ' [tT] ' > $out/kernel.syms
chown -R $user $out
python3 $here/ipi-split.py $out | tee $out/ipi-split.txt
print "== saved $out"
