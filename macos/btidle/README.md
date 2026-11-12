# BTIdle

On a hackintosh with an Intel USB Bluetooth controller, BTIdle lets the controller **idle-suspend**, as Linux `btusb` autosuspend does.

Without it, the controller is never suspended while Bluetooth is on. `bluetoothd` keeps an HCI event read pending at all times, so the xHCI controller polls the device every millisecond, and the CPU package can't go below PC3.

## Results

Measured on a Core 7 240H with an AX211 (`8087:0033`), idle, Bluetooth on:

| | Package | PC6 | PC8 |
|---|---|---|---|
| Without | 4.8 W | 0 % | 0 % |
| With BTIdle + the IntelBluetoothFirmware patch | 3.2 W | 41 % | 2.7 % |

AirDrop (iPhone ↔ Mac) still works.

## Two parts, both needed

Both come from Apple's `IOUSBHostFamily.h`, section "Idle suspend".

1. **`IntelBluetoothFirmware-power-child-lowpower.patch`.** IntelBluetoothFirmware stays in the device's power tree with an "on" state that requires `kIOPMPowerOn`, and Apple says that disables idle suspend. The patch changes that state's input requirement to `kIOPMLowPower`, which is one value in the power-state table. Apply it to the IntelBluetoothFirmware source and rebuild.
   - Rebuilding produces a different binary. If you'd rather patch an existing binary, the table is the 192-byte pattern `{1,0,0,0,…}{1,2,2,2,0,…}` (twelve 8-byte fields per state). Change the second state's fourth field from `2` to `0x10000`, then re-sign it ad hoc (`codesign -f -s -`).
2. **`BTIdle.kext`.** Every 5 s it finds the controller (`8087:0033`, edit `kVendor`/`kProduct` for others). It acts only if the device's configuration descriptor advertises remote wake:
   - sets `IOUSBHostInterface::setIdlePolicy(100)` on its interfaces;
   - sets `IOUSBHostPipe::setIdlePolicy(100)` on its bulk/interrupt IN pipes ("pausing IO", so it can suspend with the event read pending);
   - applies them again whenever `bluetoothd` reopens the pipes.

## Use

- **Build:** `bash macos/btidle/build.sh`. Add `BTIdle.kext` to OpenCore `Kernel/Add` after the Bluetooth kexts. It needs nothing but IOUSBHostFamily.
- **Check:** `ioreg -r -c BTIdle -d1 | grep btidle-status` should show something like `ms=100 rw=1 if0=100 p81=100 p82=100 if1=0`. The device's `IOPowerManagement` should show `CurrentPowerState = 1` while idle.
- **Off at runtime:** `sudo sysctl debug.btidle.ms=0`. To start disabled, use the boot arg `-btidleoff`.

## Not tested

System sleep (the test laptop has no S3), Bluetooth audio, other Intel Bluetooth devices. Test from a USB stick first.
