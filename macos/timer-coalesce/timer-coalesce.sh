#!/bin/sh
# Widen macOS timer-coalescing windows so the kernel batches timers into fewer CPU wake-ups.
# Setting "B" from macos/pmcdump/coalesce-ab.sh (2026-11-10): idle package 3.01 W -> 2.33 W,
# package idle 76 % -> 84 %. Kernel-thread, foreground, timeshare and tier-0 timers may move by up to
# 1/2 of their interval, at most 10 ms (default 1/8, at most 1 ms); tier-1 up to 20 ms (default 5 ms).
# Real-time threads and hardware interrupts (audio, display refresh) are not coalesced.
for t in kt fp ts tier0; do
	sysctl -w kern.timer_coalesce_${t}_scale=1 kern.timer_coalesce_${t}_ns_max=10000000
done
sysctl -w kern.timer_coalesce_tier1_ns_max=20000000
