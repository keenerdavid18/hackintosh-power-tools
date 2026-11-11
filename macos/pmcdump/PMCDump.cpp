// PMCDump: read-only. Maps the PCH Power Management Controller (PWRMBASE 0xFE000000, 0x2000 bytes,
// Linux pmc_core's default/LPIT address on Tiger/Alder/Raptor Lake-P) and every 5 s copies only the
// registers Linux pmc_core reads into the "pmc-regs" property: PM_CFG, SLP_S0 counter, LTR_IGNORE,
// the per-IP LTR table, LPM status/live status, PPFEAR power-gating status.
// One write path, for experiments only: sysctl debug.pmcdump.ltr_ignore (root) sets the PMC's
// LTR_IGNORE register (bit n = ltr_show index n, 23 IP bits), like Linux pmc_core's ltr_ignore file.
// The PMC resets it on reboot.
// 1.2: also samples CPU MSRs (package/core C-state config + residency counters, the ones Linux
// turbostat reads on Alder/Raptor Lake) with rdmsr_carefully, so a missing MSR is skipped, not a #GP.
// Published as "msr-regs": entries of {u32 msr, u32 ok, u64 value}, first entry = TSC.
// 1.3: the MSRs are read on CPU 0 (a P-core), like turbostat - read from an E-core the package
// residency counters looked stale - via mp_rendezvous_no_intrs.
// 1.4: every CPU also records its own core residency (0x3FC C3, 0x3FD C6, 0x3FE C7, 0x664 Atom module
// C6), TSC and core type (CPUID 0x1A: 0x40 Core/P, 0x20 Atom/E) into "core-regs".
// 1.5: experiment-only sysctl debug.pmcdump.power_ctl (root): reads MSR 0x1FC (CPU 0); a write changes
// ONLY bit 19 (disable energy-efficiency optimization) and bit 20 (disable race-to-halt optimization)
// on every CPU (plain wrmsr after a successful rdmsr_carefully of the same MSR), all other bits kept. Not persistent (XCPM/XE-PM/reboot may reset).
// 1.6: read-only GPU display registers for the watermark comparison with Linux i915 (NootedGreen issue #34): finds the
// iGPU (pcidebug 0:2:0), maps its BAR0 (from "assigned-addresses") read-only and uncached, and every
// sample copies the ranges in kGpuRanges (32-bit loads only) into "gpu-regs" (u32 values, ranges in
// order). Nothing is ever written to the GPU.
#include <IOKit/IOService.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>
#include <libkern/c++/OSData.h>
#include <sys/sysctl.h>
#include <sys/errno.h>

static constexpr uint64_t kPmcBase = 0xFE000000ULL, kPmcLen = 0x2000;
static const struct { uint32_t from, to; } kRanges[] = {
	{0x1818, 0x181C},   // PM_CFG (bit 22 = read disable)
	{0x193C, 0x1940},   // SLP_S0 residency counter
	{0x1B0C, 0x1B10},   // LTR_IGNORE
	{0x1B50, 0x1C0C},   // LTR: current platform, aggregated, per-IP (SPA ... THC1)
	{0x1C34, 0x1C84},   // LPM latch enable, status (6), live status (6), en, pri, residency
	{0x1D90, 0x1D9C},   // PPFEAR0A..: power-gating status, 9 buckets of 8 bits
};

extern "C" int rdmsr_carefully(uint32_t msr, uint32_t *lo, uint32_t *hi);
extern "C" void mp_rendezvous_no_intrs(void (*action_func)(void *), void *arg);
extern "C" int cpu_number(void);
static constexpr uint32_t kPowerCtl = 0x1FC, kPowerCtlBits = (1u << 19) | (1u << 20);
static uint32_t gPowerCtlWant;
static void setPowerCtlBits(void *) {
	uint32_t lo = 0, hi = 0;
	if (rdmsr_carefully(kPowerCtl, &lo, &hi) != 0) return;   // only write a register we could read
	lo = (lo & ~kPowerCtlBits) | (gPowerCtlWant & kPowerCtlBits);   // bits 19/20 only (wrmsr_carefully isn't exported)
	asm volatile("wrmsr" : : "c"(kPowerCtl), "a"(lo), "d"(hi));
}

static const uint32_t kMsrs[] = {
	0xE2,   // MSR_PKG_CST_CONFIG_CONTROL: package C-state limit, auto-demotion, lock
	0x1FC,  // MSR_POWER_CTL: C1E, EE turbo
	0x60D,  // MSR_PKG_C2_RESIDENCY
	0x3F8,  // MSR_PKG_C3_RESIDENCY
	0x3F9,  // MSR_PKG_C6_RESIDENCY
	0x3FA,  // MSR_PKG_C7_RESIDENCY
	0x630,  // MSR_PKG_C8_RESIDENCY
	0x631,  // MSR_PKG_C9_RESIDENCY
	0x632,  // MSR_PKG_C10_RESIDENCY
	0x3FC,  // MSR_CORE_C3_RESIDENCY (this core)
	0x3FD,  // MSR_CORE_C6_RESIDENCY (this core)
	0x3FE,  // MSR_CORE_C7_RESIDENCY (this core)
	0x606,  // MSR_RAPL_POWER_UNIT
	0x611,  // MSR_PKG_ENERGY_STATUS
	0x1A0,  // IA32_MISC_ENABLE
	0x1AD,  // MSR_TURBO_RATIO_LIMIT
};
struct MsrEntry { uint32_t msr, ok; uint64_t value; };
static constexpr uint32_t kMaxCpus = 64;
struct CoreEntry { uint32_t valid, type; uint64_t tsc, c3, c6, c7, mc6; };   // 48 bytes, ~0 = not readable

// Display MMIO ranges [from, to) in BAR0, the same list as linux/gpu-regs.py and gpu-wm.py.
struct GpuRange { uint32_t from, to; };
static constexpr GpuRange kGpuRanges[] = {
	{0x44FE0, 0x45040},   // DBUF_CTL_S2 0x44FE8, ARB_CTL 0x45000, DBUF_CTL_S1 0x45008, MBUS_ABOX_CTL 0x45038
	{0x45270, 0x45280},   // WM_LINETIME A-D
	{0x45500, 0x45530},   // DC_STATE_EN 0x45504, DC_STATE_DEBUG 0x45520
	{0x60000, 0x60080},   // transcoder A timings
	{0x61000, 0x61080},   // transcoder B timings
	{0x70000, 0x70600},   // pipe A: cursor (CUR_WM 0x70140..), planes 1-4 (PLANE_WM 0x70240.., BUF_CFG 0x7027C)
	{0x71000, 0x71600},   // pipe B
	{0x72000, 0x72600},   // pipe C
	{0x73000, 0x73600},   // pipe D
	{0x101080, 0x101090}, // DMC debug: DC5 count 0x101084, DC6 count 0x101088
};
static constexpr uint32_t kGpuMapOff = 0x44000, kGpuMapLen = 0x102000 - 0x44000;
static constexpr uint32_t gpuRegCount() {
	uint32_t n = 0;
	for (auto &r : kGpuRanges) n += (r.to - r.from) / 4;
	return n;
}

static constexpr uint32_t kLtrIgnore = 0x1B0C, kLtrIgnoreMask = 0x007FFFFF;

class PMCDump : public IOService {
	OSDeclareDefaultStructors(PMCDump)
public:
	IOMemoryDescriptor *md {nullptr};
	IOMemoryMap *map {nullptr};
	IOWorkLoop *wl {nullptr};
	IOTimerEventSource *timer {nullptr};
	uint32_t samples {0};
	uint8_t buf[kPmcLen] {};
	MsrEntry msrs[1 + sizeof(kMsrs) / sizeof(kMsrs[0])] {};
	CoreEntry cores[kMaxCpus] {};   // in the object (heap), not on the small kernel stack
	IOMemoryDescriptor *gpuMd {nullptr};
	IOMemoryMap *gpuMap {nullptr};
	uint64_t gpuBar {0};
	uint32_t gpuTries {0};
	uint32_t gpuRegs[gpuRegCount()] {};
	void sampleGpu();
	bool findGpu();
	void sample();
	void readMsrs();
	void readCore(int cpu);
	static void readOnEachCpu(void *arg) {
		auto self = static_cast<PMCDump *>(arg);
		int cpu = cpu_number();
		if (cpu == 0) self->readMsrs();
		if (cpu >= 0 && cpu < (int)kMaxCpus) self->readCore(cpu);
	}
	volatile uint32_t *regs() { return reinterpret_cast<volatile uint32_t *>(map->getVirtualAddress()); }
	static void fire(OSObject *owner, IOTimerEventSource *) {
		auto self = static_cast<PMCDump *>(owner);
		self->sample();
		self->timer->setTimeoutMS(5000);
	}
	bool start(IOService *provider) override;
	void stop(IOService *provider) override;
};

OSDefineMetaClassAndStructors(PMCDump, IOService)

static PMCDump *gSelf;

static int ltrIgnoreHandler(struct sysctl_oid *oidp, void *, int, struct sysctl_req *req) {
	if (!gSelf || !gSelf->map) return ENOENT;
	int v = static_cast<int>(gSelf->regs()[kLtrIgnore / 4]);
	int err = sysctl_handle_int(oidp, &v, 0, req);
	if (err || !req->newptr) return err;
	gSelf->regs()[kLtrIgnore / 4] = static_cast<uint32_t>(v) & kLtrIgnoreMask;
	IOLog("PMCDump: LTR_IGNORE set to 0x%08x\n", gSelf->regs()[kLtrIgnore / 4]);
	return 0;
}

static int powerCtlHandler(struct sysctl_oid *oidp, void *, int, struct sysctl_req *req) {
	uint32_t lo = 0, hi = 0;
	rdmsr_carefully(kPowerCtl, &lo, &hi);
	int v = static_cast<int>(lo);
	int err = sysctl_handle_int(oidp, &v, 0, req);
	if (err || !req->newptr) return err;
	gPowerCtlWant = static_cast<uint32_t>(v);
	mp_rendezvous_no_intrs(setPowerCtlBits, nullptr);
	rdmsr_carefully(kPowerCtl, &lo, &hi);
	IOLog("PMCDump: POWER_CTL bits 19/20 set to %u/%u (now 0x%08x)\n", (lo >> 19) & 1, (lo >> 20) & 1, lo);
	return 0;
}

SYSCTL_DECL(_debug);
SYSCTL_NODE(_debug, OID_AUTO, pmcdump, CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, "PMCDump");
SYSCTL_PROC(_debug_pmcdump, OID_AUTO, ltr_ignore, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, 0,
            ltrIgnoreHandler, "I", "PMC LTR_IGNORE (bit n = ltr_show index n)");
SYSCTL_PROC(_debug_pmcdump, OID_AUTO, power_ctl, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, 0,
            powerCtlHandler, "I", "MSR 0x1FC; writes change only bits 19 (EEO off) and 20 (race-to-halt off)");

void PMCDump::sample() {
	auto regs = reinterpret_cast<volatile uint32_t *>(map->getVirtualAddress());
	for (auto &r : kRanges)
		for (uint32_t off = r.from; off < r.to; off += 4) {
			uint32_t v = regs[off / 4];
			memcpy(buf + off, &v, 4);
		}
	if (auto d = OSData::withBytes(buf, sizeof(buf))) {
		setProperty("pmc-regs", d);
		d->release();
	}
	mp_rendezvous_no_intrs(readOnEachCpu, this);
	if (auto d = OSData::withBytes(msrs, sizeof(msrs))) {
		setProperty("msr-regs", d);
		d->release();
	}
	if (auto d = OSData::withBytes(cores, sizeof(cores))) {
		setProperty("core-regs", d);
		d->release();
	}
	sampleGpu();
	setProperty("pmc-samples", ++samples, 32);
}

// BAR0 of 00:02.0 from its "assigned-addresses" (first entry, 64-bit memory BAR at config offset 0x10).
bool PMCDump::findGpu() {
	OSIterator *it = getMatchingServices(serviceMatching("IOPCIDevice"));
	if (!it) return false;
	while (auto e = OSDynamicCast(IORegistryEntry, it->getNextObject())) {
		auto dbg = OSDynamicCast(OSString, e->getProperty("pcidebug"));
		auto aa = OSDynamicCast(OSData, e->getProperty("assigned-addresses"));
		if (!dbg || !aa || !dbg->isEqualTo("0:2:0") || aa->getLength() < 20) continue;
		uint32_t w[5];
		memcpy(w, aa->getBytesNoCopy(), sizeof(w));
		if ((w[0] & 0xFF) == 0x10 && (w[0] & 0x02000000) && ((uint64_t)w[3] << 32 | w[4]) >= kGpuMapOff + kGpuMapLen)
			gpuBar = (uint64_t)w[1] << 32 | w[2];
		break;
	}
	it->release();
	return gpuBar != 0;
}

void PMCDump::sampleGpu() {
	if (!gpuMap) {
		if (gpuTries > 60 || (!gpuBar && !findGpu())) { ++gpuTries; return; }
		gpuMd = IOMemoryDescriptor::withPhysicalAddress(gpuBar + kGpuMapOff, kGpuMapLen, kIODirectionIn);
		gpuMap = gpuMd ? gpuMd->map(kIOMapInhibitCache | kIOMapReadOnly) : nullptr;
		if (!gpuMap) { ++gpuTries; return; }
		setProperty("gpu-bar0", gpuBar, 64);
		IOLog("PMCDump: mapped GPU BAR0 0x%llx + 0x%x\n", gpuBar, kGpuMapOff);
	}
	auto g = reinterpret_cast<volatile uint32_t *>(gpuMap->getVirtualAddress());
	uint32_t n = 0;
	for (auto &r : kGpuRanges)
		for (uint32_t off = r.from; off < r.to; off += 4)
			gpuRegs[n++] = g[(off - kGpuMapOff) / 4];
	if (auto d = OSData::withBytes(gpuRegs, sizeof(gpuRegs))) {
		setProperty("gpu-regs", d);
		d->release();
	}
}

// Runs on CPU 0 with interrupts off: TSC first, then each MSR; a failed read is marked ok = 0 (no #GP).
void PMCDump::readMsrs() {
	uint32_t lo, hi;
	asm volatile("rdtsc" : "=a"(lo), "=d"(hi));
	msrs[0] = {0x10, 1, (uint64_t)hi << 32 | lo};
	for (size_t i = 0; i < sizeof(kMsrs) / sizeof(kMsrs[0]); i++) {
		lo = hi = 0;
		int err = rdmsr_carefully(kMsrs[i], &lo, &hi);
		msrs[i + 1] = {kMsrs[i], err == 0, err == 0 ? ((uint64_t)hi << 32 | lo) : 0};
	}
}

// Runs on each CPU with interrupts off: its TSC, core type and core residency counters.
void PMCDump::readCore(int cpu) {
	auto rd = [](uint32_t msr) -> uint64_t {
		uint32_t lo = 0, hi = 0;
		return rdmsr_carefully(msr, &lo, &hi) == 0 ? ((uint64_t)hi << 32 | lo) : ~0ULL;
	};
	uint32_t lo, hi, a, b, c, d;
	asm volatile("rdtsc" : "=a"(lo), "=d"(hi));
	asm volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0x1A), "c"(0));
	cores[cpu] = {1, a >> 24, (uint64_t)hi << 32 | lo, rd(0x3FC), rd(0x3FD), rd(0x3FE), rd(0x664)};
}

bool PMCDump::start(IOService *provider) {
	if (!IOService::start(provider)) return false;
	md = IOMemoryDescriptor::withPhysicalAddress(kPmcBase, kPmcLen, kIODirectionInOut);
	map = md ? md->map(kIOMapInhibitCache) : nullptr;
	if (!map) { IOLog("PMCDump: cannot map PMC at 0x%llx\n", kPmcBase); return false; }
	setProperty("pmc-base", kPmcBase, 64);
	sample();
	wl = getWorkLoop();
	timer = IOTimerEventSource::timerEventSource(this, fire);
	if (wl && timer && wl->addEventSource(timer) == kIOReturnSuccess) timer->setTimeoutMS(5000);
	gSelf = this;
	sysctl_register_oid(&sysctl__debug_pmcdump);
	sysctl_register_oid(&sysctl__debug_pmcdump_ltr_ignore);
	sysctl_register_oid(&sysctl__debug_pmcdump_power_ctl);
	registerService();
	IOLog("PMCDump: mapped PMC at 0x%llx\n", kPmcBase);
	return true;
}

void PMCDump::stop(IOService *provider) {
	sysctl_unregister_oid(&sysctl__debug_pmcdump_power_ctl);
	sysctl_unregister_oid(&sysctl__debug_pmcdump_ltr_ignore);
	sysctl_unregister_oid(&sysctl__debug_pmcdump);
	gSelf = nullptr;
	if (timer) { timer->cancelTimeout(); if (wl) wl->removeEventSource(timer); timer->release(); timer = nullptr; }
	if (gpuMap) { gpuMap->release(); gpuMap = nullptr; }
	if (gpuMd) { gpuMd->release(); gpuMd = nullptr; }
	if (map) { map->release(); map = nullptr; }
	if (md) { md->release(); md = nullptr; }
	IOService::stop(provider);
}
