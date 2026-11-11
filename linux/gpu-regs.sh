#!/bin/bash
# gpu-regs.sh (sudo): read-only dump of the iGPU display registers for the watermark comparison (NootedGreen issue #34),
# the same ranges PMCDump 1.6 reads on macOS. Plus i915 debugfs files (watermark latencies, DDB, DMC, SAGV).
# Leave the laptop idle on the desktop, internal screen only, nothing plugged into the display ports.
#   sudo bash linux/gpu-regs.sh
# Output: linux/results/gpu-regs-<date>.txt (decode on the Mac with macos/pmcdump/gpu-wm.py)
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
cd "$(dirname "$0")"
mkdir -p results
out=results/gpu-regs-$(date +%F-%H%M).txt
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
{
echo "== $(date)  kernel $(uname -r)  driver $(basename "$(readlink /sys/bus/pci/devices/0000:00:02.0/driver)")"
echo "== lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null)"
echo "== power: $(cat /sys/class/power_supply/AC*/online 2>/dev/null | head -1) (1 = AC)  brightness $(cat /sys/class/backlight/*/brightness 2>/dev/null | head -1)"
python3 -I - <<'EOF'
import mmap, os, subprocess
# Keep in sync with PMCDump.cpp kGpuRanges and gpu-wm.py RANGES.
RANGES = [(0x44FE0, 0x45040), (0x45270, 0x45280), (0x45500, 0x45530), (0x60000, 0x60080), (0x61000, 0x61080),
          (0x70000, 0x70600), (0x71000, 0x71600), (0x72000, 0x72600), (0x73000, 0x73600), (0x101080, 0x101090)]
offs = [o for a, b in RANGES for o in range(a, b, 4)]
vals = None
try:
    fd = os.open("/sys/bus/pci/devices/0000:00:02.0/resource0", os.O_RDONLY | os.O_SYNC)
    m = mmap.mmap(fd, 0x102000, mmap.MAP_SHARED, mmap.PROT_READ)
    # 32-bit loads through a read-only map: memoryview cast to 'I' (each item is one aligned 4-byte load).
    mv = memoryview(m).cast("I")
    vals = [mv[o // 4] for o in offs]
    print("== source: resource0 mmap")
except Exception as e:
    print(f"== resource0 mmap failed ({e}); trying intel_reg")
    try:
        out = subprocess.run(["intel_reg", "read"] + [hex(o) for o in offs], capture_output=True, text=True, check=True).stdout
        got = {}
        for line in out.splitlines():
            p = line.replace("(", " ").replace(")", " ").replace(":", " ").split()
            nums = [x for x in p if x.startswith("0x")]
            if len(nums) >= 2:
                got[int(nums[0], 16)] = int(nums[-1], 16)
        vals = [got.get(o, 0xDEADBEEF) for o in offs]
        print("== source: intel_reg")
    except Exception as e2:
        print(f"== intel_reg failed too ({e2}); install with: sudo apt install intel-gpu-tools")
if vals:
    print("== regs")
    for o, v in zip(offs, vals):
        print(f"{o:#08x} {v:#010x}")
EOF
for f in i915_pri_wm_latency i915_spr_wm_latency i915_cur_wm_latency i915_ddb_info i915_sagv_status i915_dmc_info \
         i915_display_info i915_edp_psr_status i915_fbc_status i915_power_domain_info; do
    p=/sys/kernel/debug/dri/0000:00:02.0/$f; [[ -r $p ]] || p=/sys/kernel/debug/dri/0/$f
    echo "== debugfs $f"; cat "$p" 2>&1 | head -150
done
} > "$out" 2>&1
chown "${SUDO_USER:-root}" "$out" 2>/dev/null
echo "saved $out"
grep -E "^== (source|resource0|intel_reg)" "$out"
