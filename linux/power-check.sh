#!/bin/bash
# Idle power / package C-state check on Ubuntu, to compare with macOS.
# Run on battery, apps closed, same screen brightness as the macOS test, then leave the laptop alone.
#   sudo bash power-check.sh            -> writes ~/power-check-<date>.txt
#   sudo bash power-check.sh 600        -> also measures whole-system battery drain for 600 s
#                                          (same method as macOS: charge drop over time)
set -u
drain=${1:-0}
out=${SUDO_USER:+/home/$SUDO_USER}/power-check-$(date +%F-%H%M).txt
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
command -v turbostat >/dev/null || apt-get install -y linux-tools-common "linux-tools-$(uname -r)" >/dev/null
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
p=/sys/kernel/debug/pmc_core
{
  echo "== $(date)  kernel $(uname -r)"
  cat /sys/class/power_supply/BAT*/status 2>/dev/null
  echo "== ASPM policy: $(cat /sys/module/pcie_aspm/parameters/policy)"
  echo "== EPP / governor (cpu0): $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null) / $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  echo "== battery draw (W): $(awk '{printf "%.2f", $1/1e6}' /sys/class/power_supply/BAT*/power_now 2>/dev/null)"
  for b in /sys/class/backlight/*; do echo "== backlight $(basename $b): $(cat $b/brightness) / $(cat $b/max_brightness)"; done
  echo "== idle 15 s before measuring"; sleep 15
  echo "== turbostat (6 x 5 s)"
  turbostat --quiet --interval 5 --num_iterations 6 \
    --show PkgWatt,CorWatt,GFXWatt,Pkg%pc2,Pkg%pc3,Pkg%pc6,Pkg%pc7,Pkg%pc8,Pkg%pc9,Pk%pc10,CPU%c7,GFX%rc6,SYS%LPI 2>&1
  echo "== battery draw after (W): $(awk '{printf "%.2f", $1/1e6}' /sys/class/power_supply/BAT*/power_now 2>/dev/null)"
  if (( drain > 0 )); then
    B=$(ls -d /sys/class/power_supply/BAT* | head -1)
    e() { if [[ -r $B/energy_now ]]; then cat $B/energy_now; else echo $(( $(cat $B/charge_now) * $(cat $B/voltage_now) / 1000000 )); fi; }  # uWh
    echo "== whole-system drain over $drain s (charge drop; power_now every 30 s)"
    t0=$(date +%s); e0=$(e); n=0; sum=0
    while (( $(date +%s) - t0 < drain )); do
      sleep 30; w=$(cat $B/power_now 2>/dev/null || echo 0); sum=$((sum + w)); n=$((n + 1))
      echo "  $(( $(date +%s) - t0 )) s  energy $(e) uWh  power_now $(awk -v w=$w 'BEGIN{printf "%.2f", w/1e6}') W"
    done
    t1=$(date +%s); e1=$(e)
    awk -v de=$((e0 - e1)) -v dt=$((t1 - t0)) -v s=$sum -v n=$n 'BEGIN{printf "== DRAIN RESULT: %.1f W from charge drop over %d s; mean power_now %.1f W\n", de/1e6/(dt/3600), dt, (n ? s/n/1e6 : 0)}'
  fi
  for f in package_cstate_show ltr_show substate_requirements substate_residencies pll_status slp_s0_residency_usec; do
    [[ -r $p/$f ]] && { echo "== pmc_core/$f"; cat $p/$f; }
  done
  echo "== PCIe link power (ASPM) per device"
  lspci -vvv 2>/dev/null | grep -E '^[0-9a-f]{2}:|LnkCap:|LnkCtl:|L1SubCtl1:'
  echo "== GPU (i915) DC states / PSR"
  for f in /sys/kernel/debug/dri/*/i915_dmc_info /sys/kernel/debug/dri/*/i915_edp_psr_status /sys/kernel/debug/dri/*/eDP-*/i915_psr_status; do
    [[ -r $f ]] && { echo "-- $f"; cat $f; }
  done
} > "$out" 2>&1
chown "${SUDO_USER:-root}" "$out"
echo "saved $out"
