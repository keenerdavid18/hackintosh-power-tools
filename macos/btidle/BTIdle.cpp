// BTIdle: lets an Intel USB Bluetooth controller (default 8087:0033, AX211) idle-suspend on macOS, the way
// Linux btusb autosuspends it. bluetoothd drives the controller from user space and never sets an idle
// policy, so the device stays active with an interrupt-IN read always pending; the xHCI then polls it every
// millisecond and the CPU package can't go below PC3 (~2 W at idle on a Raptor Lake laptop).
//
// Every 5 s it looks for the device and, only if its configuration descriptor advertises remote wake, applies
// Apple's documented idle-suspend policies (IOUSBHostFamily.h, "Idle suspend" / "Pausing IO"):
//   - IOUSBHostInterface::setIdlePolicy(ifMs) on each interface,
//   - IOUSBHostPipe::setIdlePolicy(pipeMs) on bulk/interrupt IN pipes (lets the device suspend with the
//     always-pending event read; the controller remote-wakes when it has data).
// It re-applies them when bluetoothd reopens the pipes (Bluetooth toggled, bluetoothd restarted).
// sysctl debug.btidle.ms (root): pipe and interface timeout in ms; 0 sets all policies back to 0 (off).
// Boot arg -btidleoff: start with 0. Status in the "btidle-status" property.
// Note: idle suspend is also vetoed by a power child of the device in a state needing kIOPMPowerOn; the
// IntelBluetoothFirmware build must use kIOPMLowPower (see IntelBluetoothFirmware-power-child-lowpower.patch).
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/usb/IOUSBHostDevice.h>
#include <IOKit/usb/IOUSBHostInterface.h>
#include <IOKit/usb/IOUSBHostPipe.h>
#include <IOKit/usb/StandardUSB.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSString.h>
#include <sys/sysctl.h>
#include <pexpert/pexpert.h>

static constexpr uint16_t kVendor = 0x8087, kProduct = 0x0033;
static int gIdleMs = 100;   // Apple recommends 50 ms or more for IN endpoints

class BTIdle : public IOService {
	OSDeclareDefaultStructors(BTIdle)
public:
	IOWorkLoop *wl {nullptr};
	IOTimerEventSource *timer {nullptr};
	uint32_t passes {0}, applied {0};
	bool start(IOService *provider) override;
	void stop(IOService *provider) override;
	void apply();
	static void fire(OSObject *owner, IOTimerEventSource *) {
		auto self = static_cast<BTIdle *>(owner);
		self->apply();
		self->timer->setTimeoutMS(5000);
	}
};

OSDefineMetaClassAndStructors(BTIdle, IOService)

// snprintf into status at len, never past the end (snprintf returns the length it wanted).
#define APPEND(...) do { if (len < (int)sizeof(status) - 1) { int n_ = snprintf(status + len, sizeof(status) - len, __VA_ARGS__); \
	if (n_ > 0) len = len + n_ < (int)sizeof(status) - 1 ? len + n_ : (int)sizeof(status) - 1; } } while (0)

static uint32_t num(IORegistryEntry *e, const char *key) {
	auto n = OSDynamicCast(OSNumber, e->getProperty(key));
	return n ? n->unsigned32BitValue() : 0xFFFFFFFF;
}

void BTIdle::apply() {
	char status[256];
	int len = 0;
	const uint32_t ms = static_cast<uint32_t>(gIdleMs < 0 ? 0 : gIdleMs);
	OSIterator *it = getMatchingServices(serviceMatching("IOUSBHostDevice"));
	IOUSBHostDevice *dev = nullptr;
	if (it) {
		while (OSObject *o = it->getNextObject()) {
			auto e = OSDynamicCast(IOUSBHostDevice, o);
			if (e && num(e, "idVendor") == kVendor && num(e, "idProduct") == kProduct) { dev = e; dev->retain(); break; }
		}
		it->release();
	}
	passes++;
	if (!dev) {
		snprintf(status, sizeof(status), "no %04x:%04x (pass %u)", kVendor, kProduct, passes);
		setProperty("btidle-status", status);
		return;
	}
	const StandardUSB::ConfigurationDescriptor *cfg = dev->getConfigurationDescriptor();
	const bool remoteWake = cfg && (cfg->bmAttributes & StandardUSB::kConfigurationDescriptorAttributeRemoteWakeCapable);
	APPEND("ms=%u rw=%d", ms, remoteWake);
	if (!remoteWake && ms) {
		APPEND(" - no remote wake, left alone");
		setProperty("btidle-status", status);
		dev->release();
		return;
	}
	OSIterator *kids = dev->getChildIterator(gIOServicePlane);
	if (kids) {
		while (OSObject *kid = kids->getNextObject()) {
			auto intf = OSDynamicCast(IOUSBHostInterface, kid);   // other children (e.g. IntelBluetoothFirmware) are skipped
			if (!intf) continue;
			const StandardUSB::InterfaceDescriptor *ifd = intf->getInterfaceDescriptor();
			const StandardUSB::ConfigurationDescriptor *icfg = intf->getConfigurationDescriptor();
			if (!ifd || !icfg) continue;
			if (intf->getIdlePolicy() != ms && intf->setIdlePolicy(ms) == kIOReturnSuccess) applied++;
			APPEND(" if%u=%u", ifd->bInterfaceNumber, intf->getIdlePolicy());
			const StandardUSB::EndpointDescriptor *ep = nullptr;
			while ((ep = StandardUSB::getNextEndpointDescriptor(icfg, ifd, ep))) {
				const uint8_t type = ep->bmAttributes & 3;
				if (!(ep->bEndpointAddress & 0x80) || (type != 2 && type != 3)) continue;   // bulk/interrupt IN only
				IOUSBHostPipe *pipe = intf->copyPipe(ep->bEndpointAddress);
				if (!pipe) {
					APPEND(" p%02x=-", ep->bEndpointAddress);
					continue;
				}
				if (pipe->getIdlePolicy() != ms && pipe->setIdlePolicy(ms) == kIOReturnSuccess) applied++;
				APPEND(" p%02x=%u", ep->bEndpointAddress, pipe->getIdlePolicy());
				pipe->release();
			}
		}
		kids->release();
	}
	setProperty("btidle-status", status);
	setProperty("btidle-applied", applied, 32);
	setProperty("btidle-power", OSDynamicCast(OSDictionary, dev->getProperty("IOPowerManagement")));
	dev->release();
}

static int msHandler(struct sysctl_oid *oidp, void *, int, struct sysctl_req *req) {
	int v = gIdleMs;
	int err = sysctl_handle_int(oidp, &v, 0, req);
	if (err || !req->newptr) return err;
	if (v < 0 || v > 10000) return EINVAL;
	gIdleMs = v;
	IOLog("BTIdle: idle policy %d ms\n", v);
	return 0;
}

SYSCTL_DECL(_debug);
SYSCTL_NODE(_debug, OID_AUTO, btidle, CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, "BTIdle");
SYSCTL_PROC(_debug_btidle, OID_AUTO, ms, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, 0, msHandler, "I",
            "Bluetooth USB idle policy in ms (0 = off)");

bool BTIdle::start(IOService *provider) {
	if (!IOService::start(provider)) return false;
	int dummy;
	if (PE_parse_boot_argn("-btidleoff", &dummy, sizeof(dummy))) gIdleMs = 0;
	wl = getWorkLoop();
	timer = IOTimerEventSource::timerEventSource(this, fire);
	if (!wl || !timer || wl->addEventSource(timer) != kIOReturnSuccess) return false;
	timer->setTimeoutMS(5000);
	sysctl_register_oid(&sysctl__debug_btidle);
	sysctl_register_oid(&sysctl__debug_btidle_ms);
	registerService();
	IOLog("BTIdle: started, idle policy %d ms\n", gIdleMs);
	return true;
}

void BTIdle::stop(IOService *provider) {
	sysctl_unregister_oid(&sysctl__debug_btidle_ms);
	sysctl_unregister_oid(&sysctl__debug_btidle);
	if (timer) { timer->cancelTimeout(); if (wl) wl->removeEventSource(timer); timer->release(); timer = nullptr; }
	IOService::stop(provider);
}
