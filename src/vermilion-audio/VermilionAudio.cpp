// SPDX-License-Identifier: MIT
//
// VermilionAudio.kext: a Lilu plugin that lets Apple's AppleGFXHDA (the DP / HDMI audio driver real Macs use for AMD
// GPUs) accept the RX 7900 XTX's audio function, PCI 1002:ab30.
//
// AppleGFXHDAController::probe reads the controller's vendor and device ID from PCI config space and looks them up in
// a table of 12 supported controllers (0x2c bytes each: vendor, device, quirks). Navi 31's ab30 is not in it, so the
// probe returns nothing even when a personality matches. When AppleGFXHDA loads, this plugin rewrites the device ID of
// one entry, 1002:ab20, to ab30, keeping that entry's quirks (the same as Navi 21's ab28, which Apple supports on the
// Mac Pro). It patches only when the machine has a 1002:ab30 function, no 1002:ab20 one, and its GPU (1002:744c) is an RX 7900 XTX
// (PCI revision 0xc8, PhxGpuId.h); on any other board AppleGFXHDA stays as Apple ships it.
//
// Then, with the ATI codec 1002:aa01, AppleGFXHDAFunctionGroupFactory::createAppleHDAFunctionGroup and
// AppleGFXHDAWidgetFactory::createAppleHDAWidget pick their classes by the controller's device ID: for ab20-ab38 a bit
// mask, 0x01000101 = ab20, ab28, ab38. Without ab30 there the codec gets no function group and the driver stops (seen
// 2026-11-24, "Sound assertion in AppleGFXHDAFunctionGroupFactory at line 94"). The second patch sets bit 16 in both
// masks (0x01010101), so ab30 gets what ab28 gets (ATI_Tahiti, Widget_1002AAA0).
//
// Third: AppleGFXHDA finds the display through a matching notification on AppleDisplay, registered while the controller
// starts (locateAssociatedGraphicsController). For a display that already exists, IOKit calls the handler at once,
// inside addMatchingNotification, before AppleGFXHDA has stored the notifier it compares against; the handler drops
// the call as not its own. On a Mac the controller starts before any display; here the display is up long before the
// personality is added, so AppleGFXHDA never sees it (2026-11-24: no "audio-selector" on PhxAMDFB, no engine). After
// adding the personality, this plugin delivers that notification again once the notifier is stored: the same call
// IOKit makes for a display that appears later, through AppleGFXHDA's own _gfxMatchedHandler.
//
// Fourth: AppleGFXHDA's framebuffer event handler reads the framebuffer's "connector-type" (IOGraphics
// kConnectorDisplayPort 0x400 / kConnectorHDMI 0x800), "av-signal-type" (kIOFBAVSignalTypeDP 0x10 / HDMI 0x08) and
// "AAPL,DisplayPipe", as AMD's Mac framebuffers publish them. PhxAMDFB publishes none of them yet, so before adding the
// personality this plugin sets them on every PhxAMDFB that lacks them, from the head: head 0 is driven by the DP
// plans (DIG1 on the XTX machine, DP on the upstream XT), head 1 by the HDMI engine (m7, DIG3 / PHY D). They belong in
// PhxAMDFB itself (VermilionAccel); here until that moves.
//
// Fifth: the same handler takes "audio-codec-info" from the framebuffer: byte 0 the codec address, byte 1 the function
// group node, byte 2 the pin node (AppleGFXHDAEngineOutputDP::supportsSinkWithCodecInfo hands the three to the path
// set; both upper bytes must be non-zero). Which pin a head uses follows from the codec endpoint the display engine
// programs for its DIG (Linux: DIG1 -> endpoint 1); the 1002:aa01 codec's pins are nodes 3, 5, 7, ... (endpoint n ->
// 3 + 2n, unverified). Prototype: user space writes the value to debug.phxaudio_codecinfo (root), which puts it on
// head 0's PhxAMDFB at once; 0 removes it.
//
// The patch alone changes nothing: AppleGFXHDA's personalities don't list ab30. The personality that matches it is
// added at run time, after the GPU bring-up, by writing 1 to debug.phxaudio_match (root; tools/phxctl/audio_match.sh).
// User space can't do this itself: IOCatalogueSendData from root returns success but the kernel refuses it ("Not
// entitled", macOS 26.7.1, 2026-11-24).
//
// The attach is one-way, once per boot. When a driver leaves an IOPCIDevice that stays (a terminate),
// IOPCIDevice::detachFromChild marks the nub "needing hardware reset", and the next match on it resets the function:
// FLR if it has one, else a hot reset of the link. The ab30 function has no FLR, so that is a hot reset of the whole
// GPU: XTX machine 2026-11-24 07:55, `debug.phxaudio_match=0` then `=1`: "Performing hot reset on nub HDAU", VRAM
// mappings failed, OTG0 off, the SMU silent, WindowServer crashed, the machine needed a power-off. So the personality
// is removed again as soon as the controller is up (nothing can match ab30 a second time), the controller is never
// terminated, and any further write returns EBUSY.
//
// Sixth: the engine. AppleGFXHDA starts its DP output engine from a framebuffer event, not at the attach: on the XTX
// machine none came within 10 s of the attach at boot (2026-11-24 18:08), while a display sleep / wake brought it. A
// kdebug trace of AppleGFXHDAController::framebufferEventHandler (ktrace, subclass 0x0524, 2026-11-24 18:26) shows what
// a display sleep / wake hands it: WindowServer's defer events 90 / 92 and 91 / 93 and, between them, 1 and 2
// (kIOFBNotifyDisplayModeWillChange / DidChange, info 0) from the mode WindowServer sets again on wake; not 7 / 8
// (PhxAMDFB's handleEvent calls are off IOFramebuffer's power thread, so IOFramebuffer drops them). Delivered by hand, 7
// and 8 reached the handler and started nothing. A write of 1, 2, 7 or 8 to debug.phxaudio_event (root, after the
// attach) delivers that event on head 0's PhxAMDFB through IOFramebuffer::deliverFramebufferNotification (resolved when
// IOGraphicsFamily loads), inside the framebuffer controller's work-loop gate, info 0, as IOFramebuffer does; nothing
// on the display changes. Mode-change listeners hear 1 / 2 too (IODisplay re-applies its parameters, as after any mode
// set); tools/phxctl/audio_match.sh sends 1 then 2.
//
// Table layout and contents read from AppleGFXHDA 550.1 of macOS 26.7.1 (25G241), 2026-11-24.
//
// Boot-args: -phxaudiooff (the plugin doesn't start), -phxaudiodbg (Lilu debug output), -phxaudiobeta (Lilu's switch
// for kernels newer than the plugin allows; unverified).
// Sysctls: debug.phxaudio_stat (read-only: the patch, the attach and the last delivered event), debug.phxaudio_match
// (1 once the attach ran this boot), debug.phxaudio_codecinfo ("Fifth"), debug.phxaudio_event ("Sixth").

#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>
#include <Headers/kern_util.hpp>

#include <IOKit/IOCatalogue.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <libkern/libkern.h>
#include <sys/sysctl.h>

#include "../vermilion-boot/PhxGpuId.h"   // the board gate: only an RX 7900 XTX (1002:744c rev c8)

namespace {

const char *kGfxHdaPaths[] {"/System/Library/Extensions/AppleGFXHDA.kext/Contents/MacOS/AppleGFXHDA"};
const char *kIOGraphicsPaths[] {"/System/Library/Extensions/IOGraphicsFamily.kext/IOGraphicsFamily"};
// IOGraphicsFamily only for one symbol (deliverFramebufferNotification, see "Sixth" in the header): it is in the System
// KC, and a kext OpenCore injects into the boot KC can't link against it (1.7.0 with it in OSBundleLibraries did not
// load, XTX machine 2026-11-24 18:16).
KernelPatcher::KextInfo kKexts[] {
	{"com.apple.driver.AppleGFXHDA", kGfxHdaPaths, arrsize(kGfxHdaPaths), {true}, {}, KernelPatcher::KextInfo::Unloaded},
	{"com.apple.iokit.IOGraphicsFamily", kIOGraphicsPaths, arrsize(kIOGraphicsPaths), {true}, {}, KernelPatcher::KextInfo::Unloaded},
};
KernelPatcher::KextInfo &kGfxHda = kKexts[0];
KernelPatcher::KextInfo &kIOGraphics = kKexts[1];
// IOFramebuffer::deliverFramebufferNotification(IOIndex, void *), non-virtual: called as a function with this first
using DeliverFn = IOReturn (*)(void *fb, int event, void *info);
DeliverFn gDeliver;
// IOFramebuffer.h: kIOFBNotifyDisplayModeWillChange / DidChange, kIOFBNotifyWillPowerOff / DidPowerOn
constexpr int kEvModeWillChange = 1, kEvModeDidChange = 2, kEvWillPowerOff = 7, kEvDidPowerOn = 8;

// PCI IDs: AMD, Navi 31's audio function, and the table entry that is rewritten for it.
constexpr uint32_t kVendorAmd = 0x1002, kDevNavi31Audio = 0xab30, kDevTableEntry = 0xab20;
// What publishFbProps gives a head ("Fourth" in the header): IOGraphics kConnectorDisplayPort / kConnectorHDMI,
// kIOFBAVSignalTypeDP / kIOFBAVSignalTypeHDMI.
constexpr uint32_t kConnDisplayPort = 0x400, kConnHdmi = 0x800, kAvSignalDp = 0x10, kAvSignalHdmi = 0x08;
// redeliverDisplays polls for the controller's AppleDisplay notifier: 100 x 50 ms = 5 s.
constexpr int kNotifierPolls = 100, kNotifierPollMs = 50;
// findRedelivery: the bytes of gfxMatchedHandler it scans, and the range a notifier offset is accepted in.
constexpr size_t kHandlerScanBytes = 0x60;
constexpr uint32_t kNotifierOffMin = 0x100, kNotifierOffEnd = 0x10000;

// The 1002:ab20 entry of the controller table, whole (unique in AppleGFXHDA 550.1), and the same with ab30.
constexpr uint8_t kFind[] {
	0x02, 0x10, 0x20, 0xab, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
	0x28, 0x00, 0x28, 0x00, 0x28, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00,
};
constexpr uint8_t kReplace[] {
	0x02, 0x10, 0x30, 0xab, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
	0x28, 0x00, 0x28, 0x00, 0x28, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00,
};
static_assert(sizeof(kFind) == 0x2c && sizeof(kReplace) == 0x2c, "one table entry is 0x2c bytes");

// In both factories: leal -0xab20(%rax),%ecx; cmpl $0x18,%ecx; ja +10; movl $0x01000101,%edx; btl %ecx,%edx
// (twice in AppleGFXHDA 550.1, nowhere else), and the same with the mask 0x01010101.
constexpr uint8_t kFindMask[] {
	0x8d, 0x88, 0xe0, 0x54, 0xff, 0xff, 0x83, 0xf9, 0x18, 0x77, 0x0a, 0xba, 0x01, 0x01, 0x00, 0x01, 0x0f, 0xa3, 0xca,
};
constexpr uint8_t kReplaceMask[] {
	0x8d, 0x88, 0xe0, 0x54, 0xff, 0xff, 0x83, 0xf9, 0x18, 0x77, 0x0a, 0xba, 0x01, 0x01, 0x01, 0x01, 0x0f, 0xa3, 0xca,
};
static_assert(sizeof(kFindMask) == sizeof(kReplaceMask), "same length");

char gStat[160] = "waiting for AppleGFXHDA to load\n";
char gMatchStat[160] = "";
char gEventStat[64] = "";

// AppleGFXHDAController::_gfxMatchedHandler(void *target, void *ref, IOService *, IONotifier *), and the offset of the
// controller's AppleDisplay notifier, read from the handler's first instruction that compares against it.
using GfxMatched = bool (*)(void *target, void *ref, IOService *service, IONotifier *notifier);
GfxMatched gGfxMatched;
uint32_t gNotifierOff;
int gCodecInfo;     // audio-codec-info for head 0, 0 = none (debug.phxaudio_codecinfo)
int gPropsSet;      // PhxAMDFBs given connector-type / av-signal-type / AAPL,DisplayPipe by matchOn
bool gPatched;      // the table entry reads ab30
int gMatch;         // 1 once the attach ran this boot (one-way; see the header)
IOLock *gMatchLock;

constexpr const char *kMatchKey = "PhxAudioMatch";
constexpr const char *kMatchTag = "VermilionAudio: AppleGFXHDA on the RX 7900 audio function 1002:ab30";

void redeliverDisplays();

void setStat(const char *s) {
	strlcpy(gStat, s, sizeof(gStat));
	IOLog("VermilionAudio: %s", s);
}

// The registered IOPCIDevice with this vendor / device ID (read from its registry properties), retained, or null.
IORegistryEntry *findPci(uint32_t vendor, uint32_t device) {
	OSDictionary *m = IOService::serviceMatching("IOPCIDevice");
	if (!m) return nullptr;
	IORegistryEntry *found = nullptr;
	if (OSIterator *it = IOService::getMatchingServices(m)) {
		while (OSObject *o = it->getNextObject()) {
			auto *e = OSDynamicCast(IORegistryEntry, o);
			if (!e) continue;
			auto *v = OSDynamicCast(OSData, e->getProperty("vendor-id"));
			auto *d = OSDynamicCast(OSData, e->getProperty("device-id"));
			if (!v || !d || v->getLength() < 2 || d->getLength() < 2) continue;
			const auto *vb = static_cast<const uint8_t *>(v->getBytesNoCopy());
			const auto *db = static_cast<const uint8_t *>(d->getBytesNoCopy());
			if ((vb[0] | vb[1] << 8) == vendor && (db[0] | db[1] << 8) == device) { e->retain(); found = e; break; }
		}
		it->release();
	}
	m->release();
	return found;
}

bool havePci(uint32_t vendor, uint32_t device) {
	IORegistryEntry *e = findPci(vendor, device);
	if (e) e->release();
	return e != nullptr;
}

// True when the registered 1002:744c function is an RX 7900 XTX: its "revision-id" registry property (4 bytes, little
// endian, from the PCI config read at enumeration) is 0xc8. A missing property, another revision or no 744c refuses.
bool haveXtx() {
	IORegistryEntry *e = findPci(phxgpu::kVendorAmd, phxgpu::kDeviceNavi31);
	if (!e) return false;
	uint32_t rev = ~0u;
	if (auto *r = OSDynamicCast(OSData, e->getProperty("revision-id")))
		if (r->getLength() >= 1) rev = static_cast<const uint8_t *>(r->getBytesNoCopy())[0];
	e->release();
	return phxgpu::supported(phxgpu::classify(phxgpu::kVendorAmd, phxgpu::kDeviceNavi31, rev));
}

// cmpq disp32(%rdi), %rcx: 48 3b 8f <disp32>, in AppleGFXHDAEGController::gfxMatchedHandler (550.1: 0x1c48, at +0x32).
void findRedelivery(KernelPatcher &kp, size_t index) {
	gGfxMatched = reinterpret_cast<GfxMatched>(
		kp.solveSymbol(index, "__ZN21AppleGFXHDAController18_gfxMatchedHandlerEPvS0_P9IOServiceP10IONotifier"));
	const auto h = kp.solveSymbol(index, "__ZN23AppleGFXHDAEGController17gfxMatchedHandlerEPvP9IOServiceP10IONotifier");
	kp.clearError();
	if (!h) return;
	const auto *c = reinterpret_cast<const uint8_t *>(h);
	for (size_t i = 0; i + 7 <= kHandlerScanBytes; i++)
		if (c[i] == 0x48 && c[i + 1] == 0x3b && c[i + 2] == 0x8f) {
			const uint32_t off = static_cast<uint32_t>(c[i + 3]) | static_cast<uint32_t>(c[i + 4]) << 8 |
			                     static_cast<uint32_t>(c[i + 5]) << 16 | static_cast<uint32_t>(c[i + 6]) << 24;
			if (off >= kNotifierOffMin && off < kNotifierOffEnd) gNotifierOff = off;
			return;
		}
}

// Lilu's load callback for both kexts of kKexts: IOGraphicsFamily gives the symbol, AppleGFXHDA gets the patches.
void onGfxHdaLoad(void *, KernelPatcher &kp, size_t index, mach_vm_address_t, size_t) {
	if (index == kIOGraphics.loadIndex) {
		gDeliver = reinterpret_cast<DeliverFn>(kp.solveSymbol(index, "__ZN13IOFramebuffer30deliverFramebufferNotificationEiPv"));
		kp.clearError();
		return;
	}
	if (index != kGfxHda.loadIndex) return;
	if (!havePci(kVendorAmd, kDevNavi31Audio)) { setStat("skipped: no 1002:ab30 audio function\n"); return; }
	if (!haveXtx()) { setStat("skipped: the GPU is not an RX 7900 XTX (1002:744c rev c8); AppleGFXHDA left as Apple ships it\n"); return; }
	if (havePci(kVendorAmd, kDevTableEntry)) { setStat("skipped: a 1002:ab20 audio function needs its own table entry\n"); return; }
	const KernelPatcher::LookupPatch table {&kGfxHda, kFind, kReplace, sizeof(kFind), 1};
	const KernelPatcher::LookupPatch masks {&kGfxHda, kFindMask, kReplaceMask, sizeof(kFindMask), 2};
	kp.clearError();
	kp.applyLookupPatch(&table);
	const auto e1 = kp.getError();
	kp.clearError();
	if (e1 == KernelPatcher::Error::NoError) kp.applyLookupPatch(&masks);
	const auto e2 = kp.getError();
	char b[160];
	if (e1 != KernelPatcher::Error::NoError)
		snprintf(b, sizeof(b), "not patched: Lilu error %d on the controller table (the ab20 entry not found?)\n", static_cast<int>(e1));
	else if (e2 != KernelPatcher::Error::NoError)
		snprintf(b, sizeof(b), "half patched: table ab30, but Lilu error %d on the factory masks (personality refused)\n", static_cast<int>(e2));
	else {
		gPatched = true;
		snprintf(b, sizeof(b), "patched: controller table entry ab20 -> ab30, factory masks + ab30 (2)\n");
		findRedelivery(kp, index);
		if (!gGfxMatched || !gNotifierOff)
			strlcat(b, "  (no display re-delivery: AppleGFXHDA's handler or notifier offset not found)\n", sizeof(b));
	}
	setStat(b);
	kp.clearError();
}

// The personality AppleGFXHDA would carry for ab30, the same as its own AMD one (AppleGFXHDAEGController) but for the ID.
OSDictionary *makePersonality() {
	OSDictionary *d = OSDictionary::withCapacity(8);
	if (!d) return nullptr;
	auto str = [d](const char *k, const char *v) {
		if (OSString *o = OSString::withCString(v)) { d->setObject(k, o); o->release(); }
	};
	str("CFBundleIdentifier", "com.apple.driver.AppleGFXHDA");
	str("IOClass", "AppleGFXHDAEGController");
	str("IOProviderClass", "IOPCIDevice");
	str("IOPCIMatch", "0xAB301002");
	d->setObject("IOPCITunnelCompatible", kOSBooleanTrue);
	d->setObject("IOPCIUseDeviceMapper", kOSBooleanTrue);
	str(kMatchKey, kMatchTag);
	return d;
}

// The framebuffer properties AppleGFXHDA reads (see the top), on every PhxAMDFB without them. Returns how many it set.
int publishFbProps() {
	int n = 0;
	OSDictionary *m = IOService::serviceMatching("IOFramebuffer");
	if (!m) return 0;
	if (OSIterator *it = IOService::getMatchingServices(m)) {
		while (OSObject *o = it->getNextObject()) {
			auto *fb = OSDynamicCast(IOService, o);
			if (!fb || !fb->metaCast("PhxAMDFB") || fb->getProperty("connector-type")) continue;
			auto *h = OSDynamicCast(OSNumber, fb->getProperty("phx-head"));
			const uint32_t head = h ? h->unsigned32BitValue() : 0;
			if (head > 1) continue;
			const uint32_t conn = head ? kConnHdmi : kConnDisplayPort, sig = head ? kAvSignalHdmi : kAvSignalDp;
			auto data = [fb](const char *k, uint32_t v) {
				if (OSData *d = OSData::withBytes(&v, sizeof(v))) { fb->setProperty(k, d); d->release(); }
			};
			data("connector-type", conn);
			data("av-signal-type", sig);
			data("AAPL,DisplayPipe", head);
			n++;
		}
		it->release();
	}
	m->release();
	return n;
}

// Puts gCodecInfo on head 0's PhxAMDFB (removes the property for 0). Returns the framebuffers changed.
int applyCodecInfo() {
	int n = 0;
	OSDictionary *m = IOService::serviceMatching("IOFramebuffer");
	if (!m) return 0;
	if (OSIterator *it = IOService::getMatchingServices(m)) {
		while (OSObject *o = it->getNextObject()) {
			auto *fb = OSDynamicCast(IOService, o);
			if (!fb || !fb->metaCast("PhxAMDFB") || fb->getProperty("phx-head")) continue;   // head 1 carries phx-head
			if (!gCodecInfo) fb->removeProperty("audio-codec-info");
			else if (OSData *d = OSData::withBytes(&gCodecInfo, sizeof(gCodecInfo))) { fb->setProperty("audio-codec-info", d); d->release(); }
			n++;
		}
		it->release();
	}
	m->release();
	return n;
}

IOReturn deliverAction(OSObject *owner, void *ev, void *, void *, void *) {
	return gDeliver(owner, static_cast<int>(reinterpret_cast<uintptr_t>(ev)), nullptr);
}

// Delivers framebuffer event ev on head 0's PhxAMDFB (see "Sixth" in the header). Returns an errno.
int deliverHead0(int ev) {
	int err = ENODEV;
	OSDictionary *m = IOService::serviceMatching("IOFramebuffer");
	if (!m) return ENOMEM;
	if (OSIterator *it = IOService::getMatchingServices(m)) {
		while (OSObject *o = it->getNextObject()) {
			auto *fb = OSDynamicCast(IOService, o);   // a PhxAMDFB is an IOFramebuffer; getWorkLoop is its override
			if (!fb || !fb->metaCast("PhxAMDFB") || fb->getProperty("phx-head")) continue;   // head 1 carries phx-head
			IOWorkLoop *wl = fb->getWorkLoop();
			if (!wl) break;
			const IOReturn r = wl->runAction(deliverAction, fb, reinterpret_cast<void *>(static_cast<uintptr_t>(ev)));
			snprintf(gEventStat, sizeof(gEventStat), "event: %d delivered on head 0 -> 0x%08x\n", ev, r);
			err = r == kIOReturnSuccess ? 0 : EIO;
			break;
		}
		it->release();
	}
	m->release();
	return err;
}

int eventSysctl SYSCTL_HANDLER_ARGS {
	(void)oidp; (void)arg1; (void)arg2;
	int v = 0;
	int err = SYSCTL_OUT(req, &v, sizeof(v));
	if (err || !req->newptr) return err;
	if ((err = SYSCTL_IN(req, &v, sizeof(v)))) return err;
	if (v != kEvModeWillChange && v != kEvModeDidChange && v != kEvWillPowerOff && v != kEvDidPowerOn) return EINVAL;
	if (!gDeliver) return ENOSYS;               // IOFramebuffer's symbol not found
	IOLockLock(gMatchLock);
	err = gMatch ? deliverHead0(v) : ENOENT;    // only after the attach
	IOLockUnlock(gMatchLock);
	return err;
}
SYSCTL_PROC(_debug, OID_AUTO, phxaudio_event, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, 0, eventSysctl, "I",
            "VermilionAudio: write 1, 2 (display mode will / did change), 7 or 8 (power) to deliver that framebuffer event on head 0 (root, after the attach)");

int codecInfoSysctl SYSCTL_HANDLER_ARGS {
	(void)oidp; (void)arg1; (void)arg2;
	int v = gCodecInfo;
	int err = SYSCTL_OUT(req, &v, sizeof(v));
	if (err || !req->newptr) return err;
	if ((err = SYSCTL_IN(req, &v, sizeof(v)))) return err;
	if (v < 0 || v > 0xffffff) return EINVAL;
	IOLockLock(gMatchLock);
	gCodecInfo = v;
	applyCodecInfo();
	IOLockUnlock(gMatchLock);
	return 0;
}
SYSCTL_PROC(_debug, OID_AUTO, phxaudio_codecinfo, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, 0, codecInfoSysctl, "I",
            "VermilionAudio: head 0's audio-codec-info (codec address | function group << 8 | pin << 16), 0 = none");

// Takes the ab30 personality out of the catalogue again. doNubMatching false: a driver already attached stays.
void removePersonality() {
	OSDictionary *m = OSDictionary::withCapacity(1);
	if (!m) return;
	if (OSString *o = OSString::withCString(kMatchTag)) { m->setObject(kMatchKey, o); o->release(); }
	gIOCatalogue->removeDrivers(m, false);
	m->release();
	IOLog("VermilionAudio: ab30 personality removed\n");
}

// The attach: the framebuffer properties, the personality (the catalogue starts matching it at once), the display
// re-delivery, then the personality out again. Returns an errno.
int matchOn() {
	if (!gPatched) return ENOENT;    // the probe would reject ab30
	gPropsSet = publishFbProps();
	if (gCodecInfo) applyCodecInfo();
	OSDictionary *d = makePersonality();
	const OSObject *objs[] {d};
	OSArray *a = d ? OSArray::withObjects(objs, 1) : nullptr;
	const bool ok = a && gIOCatalogue->addDrivers(a, true);
	if (a) a->release();
	if (d) d->release();
	if (!ok) return EIO;
	IOLog("VermilionAudio: ab30 personality added\n");
	redeliverDisplays();
	removePersonality();    // the controller is up or not: either way no second match on ab30 (see the header)
	return 0;
}

// The AppleGFXHDA controller on ab30, retained, or null.
IOService *findController() {
	IOService *found = nullptr;
	if (IORegistryEntry *pci = findPci(kVendorAmd, kDevNavi31Audio)) {
		if (OSIterator *it = pci->getChildIterator(gIOServicePlane)) {
			while (OSObject *o = it->getNextObject())
				if (auto *s = OSDynamicCast(IOService, o); s && s->metaCast("AppleGFXHDAController")) { s->retain(); found = s; break; }
			it->release();
		}
		pci->release();
	}
	return found;
}

// Waits up to 5 s for the controller to store its AppleDisplay notifier, then hands it every AppleDisplay.
void redeliverDisplays() {
	if (!gGfxMatched || !gNotifierOff) { strlcpy(gMatchStat, "match: no display re-delivery (see above)\n", sizeof(gMatchStat)); return; }
	IOService *ctrl = nullptr;
	IONotifier *n = nullptr;
	for (int i = 0; i < kNotifierPolls && !n; i++) {
		if (!ctrl) ctrl = findController();
		if (ctrl) n = *reinterpret_cast<IONotifier *const *>(reinterpret_cast<const uint8_t *>(ctrl) + gNotifierOff);
		if (!n) IOSleep(kNotifierPollMs);
	}
	if (!n) {
		snprintf(gMatchStat, sizeof(gMatchStat), "match: %s, no display notifier after 5 s\n", ctrl ? "controller up" : "no controller");
		if (ctrl) ctrl->release();
		IOLog("VermilionAudio: %s", gMatchStat);
		return;
	}
	int count = 0;
	if (OSDictionary *m = IOService::serviceMatching("AppleDisplay")) {
		if (OSIterator *it = IOService::getMatchingServices(m)) {
			while (OSObject *o = it->getNextObject())
				if (auto *d = OSDynamicCast(IOService, o)) { gGfxMatched(ctrl, nullptr, d, n); count++; }
			it->release();
		}
		m->release();
	}
	ctrl->release();
	snprintf(gMatchStat, sizeof(gMatchStat),
	         "match: framebuffer properties set on %d PhxAMDFB, AppleDisplay notification re-delivered for %d display(s)\n",
	         gPropsSet, count);
	IOLog("VermilionAudio: %s", gMatchStat);
}

int matchSysctl SYSCTL_HANDLER_ARGS {
	(void)oidp; (void)arg1; (void)arg2;
	int v = gMatch;
	int err = SYSCTL_OUT(req, &v, sizeof(v));
	if (err || !req->newptr) return err;
	if ((err = SYSCTL_IN(req, &v, sizeof(v)))) return err;
	if (v != 0 && v != 1) return EINVAL;
	IOLockLock(gMatchLock);
	if (v != gMatch) err = gMatch ? EBUSY : matchOn();    // one-way: no detach, no second attach (see the header)
	if (!err) gMatch = v;
	IOLockUnlock(gMatchLock);
	return err;
}
SYSCTL_PROC(_debug, OID_AUTO, phxaudio_match, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, 0, matchSysctl, "I",
            "VermilionAudio: 1 = AppleGFXHDA was attached to 1002:ab30 this boot (write 1 once, root, after the GPU bring-up)");

int statSysctl SYSCTL_HANDLER_ARGS {
	(void)oidp; (void)arg1; (void)arg2;
	if (req->newptr) return EPERM;
	char b[sizeof(gStat) + sizeof(gMatchStat) + sizeof(gEventStat)];
	strlcpy(b, gStat, sizeof(b));
	strlcat(b, gMatchStat, sizeof(b));
	strlcat(b, gEventStat, sizeof(b));
	return SYSCTL_OUT(req, b, strlen(b) + 1);
}
SYSCTL_PROC(_debug, OID_AUTO, phxaudio_stat, CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, statSysctl, "A",
            "VermilionAudio: whether AppleGFXHDA's controller table accepts 1002:ab30");

void pluginStart() {
	gMatchLock = IOLockAlloc();
	sysctl_register_oid(&sysctl__debug_phxaudio_stat);
	if (gMatchLock) {
		sysctl_register_oid(&sysctl__debug_phxaudio_match);
		sysctl_register_oid(&sysctl__debug_phxaudio_codecinfo);
		sysctl_register_oid(&sysctl__debug_phxaudio_event);
	}
	lilu.onKextLoadForce(kKexts, arrsize(kKexts), onGfxHdaLoad);
}

const char *bootargOff[] {"-phxaudiooff"};
const char *bootargDebug[] {"-phxaudiodbg"};
const char *bootargBeta[] {"-phxaudiobeta"};

} // namespace

PluginConfiguration ADDPR(config) {
	xStringify(PRODUCT_NAME),
	parseModuleVersion(xStringify(MODULE_VERSION)),
	LiluAPI::AllowNormal | LiluAPI::AllowSafeMode,
	bootargOff, arrsize(bootargOff),
	bootargDebug, arrsize(bootargDebug),
	bootargBeta, arrsize(bootargBeta),
	KernelVersion::Tahoe,
	KernelVersion::Tahoe,
	pluginStart
};
