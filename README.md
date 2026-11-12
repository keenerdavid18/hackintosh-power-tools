# hackintosh-power-tools

Tools for measuring idle power on Intel hackintoshes, where `powermetrics` misreports package C-states. They read the real hardware counters instead: package and core C-state residency MSRs, RAPL energy, the PCH power-management controller, and the iGPU display registers. Each tool has a Linux counterpart, so you can compare macOS and Linux on the same laptop.

They were written for the idle-power investigation in [JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe#34](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe/issues/34) (macOS stays in PC6 where Linux reaches PC8).

> **Use at your own risk.** PMCDump is a kernel extension. Load it from a test EFI on a USB stick, not your only working EFI. The code was written with AI assistance and has been tested on one laptop only.

## Tested on

- **CPU:** Intel Core 7 240H (Raptor Lake-H), iGPU 8086:A7A8
- **macOS:** Tahoe 26.7.1 (25G241), OpenCore, [NootedGreen](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe)
- **Linux:** Ubuntu with kernel 6.17 (OEM), i915

The MSR and PMC addresses are the same on Tiger, Alder and Raptor Lake mobile, but the GPU display register layout is display version 12/13 only.

## PMCDump.kext (`macos/pmcdump/`)

PMCDump is a read-only kernel extension that publishes raw registers as IORegistry properties every 5 s. The Python scripts decode them.

| Property | Contents |
|---|---|
| `pmc-regs` | PCH PMC at `0xFE000000`: per-IP LTR table, LTR_IGNORE, PFEAR power-gating status, low-power-mode live status, SLP_S0 counter. These are the same registers Linux `pmc_core` reads. |
| `msr-regs` | Package and core C-state config and residency MSRs, RAPL energy, POWER_CTL. Read on CPU 0 via a rendezvous, like turbostat. Read from an E-core, the package counters look stale. |
| `core-regs` | Each CPU's own core residency (C3/C6/C7, Atom module C6), its TSC and its core type |
| `gpu-regs` | iGPU display registers from BAR0 of `00:02.0`: plane/cursor watermarks, DDB (`PLANE_BUF_CFG`), DBUF control, `DC_STATE_EN`, DMC DC5/DC6 counters |

PMCDump has two root-only sysctls, for experiments only. Nothing is written unless you write to them:
- `debug.pmcdump.ltr_ignore` sets the PMC's LTR_IGNORE (like `pmc_core/ltr_ignore`).
- `debug.pmcdump.power_ctl` changes only bits 19/20 of MSR `0x1FC`.

Neither change persists across a reboot.

**Build** (needs Xcode): `bash macos/pmcdump/build.sh`. Then add `PMCDump.kext` to `Kernel/Add` in a test OpenCore config.

## Scripts

| Script | Needs | What it does |
|---|---|---|
| `macos/pmcdump/residency.py [s] [label]` | PMCDump | Package power (RAPL), PC2–PC10 and per-core C-state residency over a window. This is the turbostat equivalent. |
| `macos/pmcdump/decode.py [ltr\|pfear\|lpm\|msr]` | PMCDump | PMC views laid out like Linux `pmc_core` (`ltr_show`, pfear, substate live status), plus the C-state MSRs |
| `macos/pmcdump/gpu-wm.py [mac] [linux]` | PMCDump 1.6 | Decodes and compares display watermarks, DDB and DC state, macOS against a `linux/gpu-regs.sh` dump |
| `macos/pmcdump/ipi-test.sh LABEL` | sudo, PMCDump | Residency, interrupt rates (`powermetrics`) and a ktrace, for A/B tests |
| `macos/pmcdump/ipi-split.py DIR` | | Splits IPIs by cause: scheduler remote AST, cpus_call (with the called function), TLB flush |
| `macos/pmcdump/wake-trace.sh` + `wake-attrib.py` | sudo | Timer callouts per second by function and CPU, plus the kernel threads running kext code |
| `macos/pmcdump/coalesce-ab.sh` | sudo, PMCDump | Interleaved A/B/C test of timer-coalescing windows |
| `macos/pmcdump/powerctl-ab.sh` | sudo, PMCDump | Interleaved A/B/C test of POWER_CTL bits 19/20 |
| `macos/btidle/` | OpenCore | Kext + IntelBluetoothFirmware patch that let an Intel USB Bluetooth controller idle-suspend. Saves ~1.6 W idle here with Bluetooth on; see its README. |
| `macos/timer-coalesce/` | sudo | LaunchDaemon that applies wider timer-coalescing windows at boot. It saved ~0.7 W idle here; see its README. |
| `linux/gpu-regs.sh` | sudo | The same display registers as PMCDump, read through `resource0`, plus i915 debugfs (WM latencies, DDB, DMC, SAGV) |
| `linux/power-check.sh` | sudo | turbostat package power and C-states, plus `pmc_core` views, for the Linux side of the comparison |
| `linux/wakeup-test.sh` | sudo | Linux idle wake-up rates, and adds synthetic timer/IPI wake-ups to find where PC8 turns into PC6 |

The macOS scripts and `linux/gpu-regs.sh` write to `macos/results/` and `linux/results/`. The other Linux scripts write to your home folder.

## What we found with them

On a Core 7 240H, macOS idle (cores individually as deep as on Linux):
- **Timer coalescing:** widening the windows took the package from 3.0 W to 2.3 W.
- **Ethernet:** a linked I219-V caps the package at PC3. Linux doesn't have this.
- **Display buffer (DDB):** watermark levels are the same as Linux, but Apple's TGL framebuffer gives the display plane a ~4× smaller buffer than i915 (984 vs 4054 blocks).
- **Bluetooth:** the Intel USB Bluetooth controller never idle-suspended while Bluetooth was on, which capped the package at PC3. BTIdle fixes it (4.8 W → 3.2 W).
- **SMCProcessor:** no measurable effect.

Details are in the issue thread.

## License

MIT, see [LICENSE](LICENSE).
