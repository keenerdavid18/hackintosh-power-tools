# timer-coalesce

Applies wider macOS timer-coalescing windows at boot, so the kernel batches timers into fewer
CPU wake-ups. Measured with `macos/pmcdump/coalesce-ab.sh` (2026-11-10, battery, idle, cable out):

| Setting | Package | PC6 | PC8 | Package idle |
|---|---|---|---|---|
| macOS defaults | 3.01 W | 44.7 % | 2.1 % | 76 % |
| **this ("B")** | **2.33 W** | 53.5 % | 3.4 % | 84 % |
| aggressive ("C", 50-100 ms) | 2.21 W | 54.7 % | 3.8 % | 85 % |

Kernel/foreground/timeshare/tier-0 timers may move by up to half their interval, at most 10 ms
(default 1/8, at most 1 ms); tier-1 up to 20 ms. Real-time threads and hardware interrupts are not
coalesced. If anything feels laggy, uninstall (or reboot without the daemon - nothing persists).

## Install (sudo)

```sh
cd macos/timer-coalesce
sudo install -m 755 timer-coalesce.sh /usr/local/sbin/timer-coalesce
sudo install -m 644 local.timer-coalesce.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/local.timer-coalesce.plist
sysctl kern.timer_coalesce_kt_ns_max        # 10000000 = active
```

## Uninstall

```sh
sudo launchctl bootout system/local.timer-coalesce
sudo rm /Library/LaunchDaemons/local.timer-coalesce.plist /usr/local/sbin/timer-coalesce
```
Then reboot, or set the defaults back by hand: `kt/fp/ts/tier0` scale 3, ns_max 1000000; tier1 ns_max 5000000.
