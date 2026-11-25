#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# linux_display_capture.py: the Linux side of "1440p at 120/144/240 Hz and HDR on the XTX" (findings
# 2026-11-19-refresh-and-hdr.md, plan step 2). Run as root on Linux (Omarchy / Hyprland), booted directly.
#
# For each step it switches the monitor with hyprctl (Linux's own amdgpu DC does the mode set and link training), traces
# every register write DC makes during the switch (ftrace amdgpu_dm:amdgpu_dc_wreg), lets it settle, then READS:
# amdgpu_dm_dtn_log, the connector's debugfs state (link_settings, output_bpc, DSC), DPCD over /dev/drm_dp_auxN, the
# steady value of every register DC wrote plus a fixed list (debugfs amdgpu_regs), clocks, DMUB trace and firmware info.
# Since 2026-11-20 it also records every DMUB inbox command DC queues during the switch (a kprobe on dmub_srv_cmd_queue
# fetching the 64-byte command: TRANSMITTER_CONTROL for the PHY / link rate, DP_AUX_ACCESS for DPCD), in order with the
# register writes, so the HBR3 link training at 240 Hz can be read byte for byte (DC sends both through the DMCUB).
# Nothing is written to the GPU by this script itself except through amdgpu: hyprctl mode sets, and in the "hbr2"
# steps the debugfs link_settings preference (Linux retrains its own link; undone by a power-off).
#
# Steps (each can be picked with --steps):
#   base            what is running now (no switch)
#   60 120 144 240  2560x1440 at that rate, 8 bpc, VRR off, Linux's own link choice (HBR3 most likely)
#   hbr2-60 hbr2-120 hbr2-144   the same with the link forced to HBR2 x4 (what the GOP leaves macOS on) [--hbr2]
#   hbr2-120-10     120 Hz at 10 bpc on HBR2 x4 [--hbr2]
#   hdr-60 hdr-120  HDR on (Hyprland cm,hdr, 10 bpc) [--hdr]: the HDR infoframe / colorimetry / regamma writes
#   240-10 hdr-240  240 Hz at 10 bpc, and with HDR on (DSC at 10 bpc) [--r240]
#   240-nodsc       240 Hz at 8 bpc with DSC forced off (debugfs dsc_clock_en = 2, back to 0 after): does Linux light
#                   1440p240 on HBR3 without DSC? If the mode set fails, that is the answer [--r240]
#   --dpms (v5, 2026-11-23)  display sleep: for each 1440p rate, SDR and HDR: the mode set, then `hyprctl dispatch dpms
#                   off` (traced: trace-dpms-off.txt), 5 s off with the state read (regs-off.txt, DPCD), then `dpms on`
#                   (traced: trace-dpms-on.txt) and the state read again. Linux's own DPMS sequence (stream off, blank,
#                   dp_disable_link_phy; link up, unblank) for macOS's display sleep (thread 01)
# At the end the monitor goes back to the config file (hyprctl reload). Forced link settings stay until power-off.
#
# Output: <outdir>/display-<date>/<step>/... and a summary.txt. Monitor serials are stripped from the EDID copy (base
# block serial + 0xFF descriptor + DisplayID product block serial). Register dumps carry no serials. Never git it.
#
# Usage:  sudo python3 tools/capture/linux_display_capture.py /boot/vermilion/capture [--hbr2] [--hdr] [--steps a,b]
#         --dry-run lists what would run, touches nothing (no root needed).
import argparse, datetime, glob, json, os, re, shutil, subprocess, sys, time

# Never read: reads with side effects. MMVM_INVALIDATE_ENG*_SEM (a read takes the semaphore), the DC_I2C engine and the
# DP AUX engines (reading SW_DATA advances the FIFO index). Absolute dwords (DCN 3.2, segment 2 = 0x34C0).
DENY = [(0x1A751, 0x1A762), (0x34C0 + 0x1E98, 0x34C0 + 0x1EB8), (0x34C0 + 0x1F50, 0x34C0 + 0x1F50 + 5 * 0x1C)]
# Always read (beyond what DC wrote): the registers macOS read on 2026-11-19 and the pipe-0 engine's fingerprint.
FIXED = {
    0x056C8: "DP1_DP_LINK_CNTL", 0x056C9: "DP1_DP_PIXEL_FORMAT", 0x056CA: "DP1_DP_MSA_COLORIMETRY", 0x056CB: "DP1_DP_CONFIG",
    0x056CC: "DP1_DP_VID_STREAM_CNTL", 0x056CE: "DP1_DP_MSA_MISC", 0x056D0: "DP1_DP_VID_TIMING", 0x056D1: "DP1_DP_VID_N",
    0x056D2: "DP1_DP_VID_M", 0x056EB: "DP1_DP_SEC_CNTL", 0x0564B: "DIG1_DIG_FE_CNTL", 0x05651: "DIG1_DIG_FIFO_CTRL0",
    0x05671: "DIG1_DIG_BE_CNTL", 0x05672: "DIG1_DIG_BE_EN_CNTL", 0x04FEA: "OTG0_OTG_H_TOTAL", 0x04FEF: "OTG0_OTG_V_TOTAL",
    0x05001: "OTG0_OTG_CONTROL", 0x0500C: "OTG0_OTG_STATUS_FRAME_COUNT", 0x00141: "DP_DTO0_PHASE", 0x00142: "DP_DTO0_MODULO",
    0x00124: "DENTIST_DISPCLK_CNTL", 0x0397B: "DCHUBBUB_DET0_CTRL", 0x0397C: "DCHUBBUB_DET1_CTRL", 0x0397D: "DCHUBBUB_DET2_CTRL",
    0x0397E: "DCHUBBUB_DET3_CTRL", 0x039BC: "DCHUBBUB_ARB_DRAM_STATE_CNTL", 0x039BE: "ARB_DATA_URGENCY_WATERMARK_A",
    0x039C1: "ARB_ALLOW_SR_ENTER_WATERMARK_A", 0x039C2: "ARB_ALLOW_SR_EXIT_WATERMARK_A", 0x039C3: "ARB_UCLK_PSTATE_WATERMARK_A",
    0x039C4: "ARB_FCLK_PSTATE_WATERMARK_A", 0x036A4: "DMCUB_SCRATCH1", 0x03AA5: "HUBP0_DCSURF_SURFACE_CONFIG",
    0x03AB3: "HUBP0_DCHUBP_CNTL", 0x04F8A: "ODM0_OPTC_INPUT_GLOBAL_CONTROL", 0x039EE: "VTG0_CONTROL",
}
STEPS = {   # name: (refresh Hz, or a "WxH@rate" mode string, or None; bpc; link "auto"/"hbr2"/"nodsc"; hdr[; vrr])
    "base": (None, None, "auto", False),
    "60": (60, 8, "auto", False), "120": (120, 8, "auto", False), "144": (144, 8, "auto", False), "240": (240, 8, "auto", False),
    "hbr2-60": (60, 8, "hbr2", False), "hbr2-120": (120, 8, "hbr2", False), "hbr2-144": (144, 8, "hbr2", False),
    "hbr2-120-10": (120, 10, "hbr2", False),
    "hdr-60": (60, 10, "auto", True), "hdr-120": (120, 10, "auto", True),
    "240-10": (240, 10, "auto", False), "hdr-240": (240, 10, "auto", True), "240-nodsc": (240, 8, "nodsc", False),
}
DEFAULT = ["base", "60", "120", "144", "240"]
HBR2 = ["hbr2-60", "hbr2-120", "hbr2-144", "hbr2-120-10"]
HDR = ["hdr-60", "hdr-120"]
R240 = ["240-10", "hdr-240", "240-nodsc"]
DPCD_RANGES = [(0x0000, 0x100), (0x0100, 0x100), (0x0200, 0x100), (0x0300, 0x10), (0x0600, 0x1), (0x2200, 0x100)]
TRACE = "/sys/kernel/tracing"
EVENT = "amdgpu_dm/amdgpu_dc_wreg"
# DMUB inbox commands: kprobe on the queue function (arg 2 = const union dmub_rb_cmd *, 64 bytes = 16 dwords), x86-64.
KPROBE_SYMS = ["dmub_srv_cmd_queue", "dmub_srv_fb_cmd_queue"]
KPROBE_FETCH = " ".join(f"c{i}=+{4 * i}(%si):x32" for i in range(16))


def kprobe_write(line):
    """One raw write(2) to kprobe_events; Python's buffered text-mode append gets EINVAL from tracefs (Linux 7.2)."""
    fd = os.open(f"{TRACE}/kprobe_events", os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)


def denied(r):
    return any(a <= r <= b for a, b in DENY)


def strip_edid(e):
    """The EDID with the monitor's serials blanked: base block bytes 12-15, any 0xFF (serial) descriptor, and the
    serial of a DisplayID 1.x/2.x product identification block (tags 0x00 / 0x20). Checksums recomputed."""
    e = bytearray(e)
    if len(e) < 128:
        return bytes(e)
    e[12:16] = b"\0\0\0\0"
    for o in (54, 72, 90, 108):
        if e[o] == 0 and e[o + 1] == 0 and e[o + 3] == 0xFF:
            e[o + 5:o + 18] = b"\x0a" + b"\x20" * 12
    for b in range(128, len(e) - 127, 128):
        x = e[b:b + 128]
        if x[0] != 0x70:
            continue
        end = min(5 + x[2], 127)   # DisplayID section: header 1..4, data blocks from 5, section checksum at 5 + length
        i = 5
        while i + 3 <= end:
            tag, n = x[i], x[i + 2]
            if tag in (0x00, 0x20) and n >= 9:   # product identification: OUI 3, product code 2, serial 4, ...
                x[i + 3 + 5:i + 3 + 9] = b"\0\0\0\0"
            i += 3 + n
        if end < 127:
            x[end] = (-sum(x[1:end])) & 0xFF
        e[b:b + 128] = x
    for b in range(0, len(e) - 127, 128):
        e[b + 127] = (-sum(e[b:b + 127])) & 0xFF
    return bytes(e)


class Cap:
    def __init__(self, a):
        self.a = a
        self.dry = a.dry_run
        self.log = []
        self.kprobes = []

    def say(self, s):
        print(s, flush=True)
        self.log.append(s)

    # ---- discovery ----
    def find(self):
        self.card = self.dri = None
        for v in glob.glob("/sys/class/drm/card[0-9]*/device/vendor"):
            d = os.path.dirname(v)
            if open(v).read().strip() == "0x1002" and open(d + "/device").read().strip() == "0x744c":
                self.card = os.path.basename(os.path.dirname(d))
                self.pci = os.path.basename(os.path.realpath(d))
        if not self.card:
            sys.exit("no RX 7900 (1002:744c) card found")
        for n in glob.glob("/sys/kernel/debug/dri/*/name"):
            if self.pci in open(n).read():
                self.dri = os.path.dirname(n)
        self.rev = open(f"/sys/class/drm/{self.card}/device/revision").read().strip()
        # the replay plans are for the RX 7900 XTX only (src/vermilion-boot/PhxGpuId.h): refuse another board
        if self.rev.lower() != "0xc8":
            sys.exit(f"{self.pci}: PCI revision {self.rev} is not an RX 7900 XTX (0xc8): Vermilion supports the XTX only")
        self.conn = None
        for c in sorted(glob.glob(f"/sys/class/drm/{self.card}-DP-*")):
            if open(c + "/status").read().strip() == "connected":
                self.conn = c
                break
        if not self.conn:
            sys.exit("no connected DP connector on the card")
        self.cname = os.path.basename(self.conn).split("-", 1)[1]   # DP-1
        aux = glob.glob(self.conn + "/drm_dp_aux*")
        self.aux = "/dev/" + os.path.basename(aux[0]) if aux else None
        self.say(f"card {self.card} pci {self.pci} rev {self.rev} debugfs {self.dri} connector {self.cname} aux {self.aux}")

    # ---- hyprland ----
    def hypr(self, *args):
        user = os.environ.get("SUDO_USER") or os.environ.get("USER")
        uid = int(subprocess.run(["id", "-u", user], capture_output=True, text=True).stdout.strip() or 0)
        rd = f"/run/user/{uid}"
        sigs = sorted(glob.glob(rd + "/hypr/*/.socket.sock"), key=os.path.getmtime)
        if not sigs:
            raise RuntimeError("no Hyprland instance found")
        env = dict(os.environ, XDG_RUNTIME_DIR=rd, HYPRLAND_INSTANCE_SIGNATURE=os.path.basename(os.path.dirname(sigs[-1])))
        cmd = ["hyprctl", *args] if os.geteuid() == uid else ["sudo", "-u", user, "-E", "hyprctl", *args]
        return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=20).stdout

    @staticmethod
    def lua_monitor(rule):
        # Hyprland >= 0.55 reads Lua; "keyword" no longer works. Turn the legacy rule string into hl.monitor{}.
        f = rule.split(",")
        t = {"output": f[0], "mode": f[1], "position": f[2], "scale": f[3]}
        for k, v in zip(f[4::2], f[5::2]):
            t[k] = v
        body = ", ".join(f'{k} = {v}' if v.isdigit() or k == "scale" else f'{k} = "{v}"' for k, v in t.items())
        return "hl.monitor({ " + body + " })"

    def monitor(self):
        for m in json.loads(self.hypr("-j", "monitors") or "[]"):
            if m.get("name") == self.cname:
                return m
        return {}

    # ---- reads ----
    def readregs(self, regs):
        out = {}
        with open(self.dri + "/amdgpu_regs", "rb", buffering=0) as f:
            for r in sorted(regs):
                if denied(r):
                    continue
                try:
                    out[r] = int.from_bytes(os.pread(f.fileno(), 4, r * 4), "little")
                except OSError as e:
                    out[r] = f"err {e.errno}"
        return out

    def dpcd(self):
        res = {}
        if not self.aux:
            return res
        fd = os.open(self.aux, os.O_RDONLY)
        try:
            for base, n in DPCD_RANGES:
                b = bytearray()
                for o in range(base, base + n, 16):
                    try:
                        b += os.pread(fd, min(16, base + n - o), o)
                    except OSError:
                        b += b"\xee" * min(16, base + n - o)
                res[base] = bytes(b)
        finally:
            os.close(fd)
        return res

    def cat(self, path, dst):
        try:
            with open(path, "rb") as f:
                data = f.read(4 << 20)
            open(dst, "wb").write(data)
            return data
        except OSError as e:
            open(dst, "w").write(f"(unreadable: {e})\n")
            return b""

    # ---- ftrace ----
    def kprobes_add(self):
        """One kprobe per DMUB queue function the kernel has (group phxcap). Missing ones are skipped and logged."""
        self.kprobes = []
        try:
            funcs = set(open(f"{TRACE}/available_filter_functions").read().split())
        except OSError:
            funcs = set()
        for i, sym in enumerate(KPROBE_SYMS):
            if sym not in funcs:
                continue
            try:
                kprobe_write(f"p:phxcap/dmubcmd{i} {sym} {KPROBE_FETCH}\n")
                self.kprobes.append(f"phxcap/dmubcmd{i}")
            except OSError as e:
                self.say(f"kprobe on {sym} failed: {e}")
        self.say(f"DMUB command kprobes: {', '.join(self.kprobes) or 'none (DMUB payloads not recorded)'}")

    def kprobes_remove(self):
        for k in getattr(self, "kprobes", []):
            try:
                open(f"{TRACE}/events/{k}/enable", "w").write("0")
                kprobe_write(f"-:{k}\n")
            except OSError as e:
                self.say(f"kprobe {k} not removed: {e}")
        self.kprobes = []

    def trace_start(self):
        w = lambda p, v: open(f"{TRACE}/{p}", "w").write(v)
        w("tracing_on", "0"); w("trace", ""); w("buffer_size_kb", "65536")
        w(f"events/{EVENT}/enable", "1")
        for k in self.kprobes:
            w(f"events/{k}/enable", "1")
        w("tracing_on", "1")

    def trace_stop(self, dst):
        open(f"{TRACE}/tracing_on", "w").write("0")
        open(f"{TRACE}/events/{EVENT}/enable", "w").write("0")
        for k in self.kprobes:
            open(f"{TRACE}/events/{k}/enable", "w").write("0")
        shutil.copyfile(f"{TRACE}/trace", dst)
        regs, n = set(), 0
        for line in open(dst, errors="replace"):
            m = re.search(r"reg=0x([0-9a-fA-F]+)", line) or re.search(r"address=0x([0-9a-fA-F]+)", line)
            if m:
                regs.add(int(m.group(1), 16)); n += 1
        return regs, n

    # ---- one step ----
    def step(self, name, out):
        ent = STEPS[name]
        hz, bpc, link, hdr = ent[:4]
        vrr = ent[4] if len(ent) > 4 else 0
        d = os.path.join(out, name)
        rule = None
        if hz:
            mode = hz if isinstance(hz, str) else f"2560x1440@{hz}"
            # v4 (2026-11-21): an SDR step names SDR (bitdepth 8, cm srgb). v3 left both out, so Hyprland kept the previous
            # step's HDR: every "from-hdr" step stayed in HDR at 144 (10 bpc, the HDR infoframe on) and the capture had no
            # way back from HDR to SDR
            rule = f"{self.cname},{mode},0x0,1,vrr,{vrr}" + (f",bitdepth,{bpc},cm,hdr" if hdr else ",bitdepth,8,cm,srgb")
        self.say(f"== {name}: {rule or 'no switch'}{' (link forced HBR2 x4)' if link == 'hbr2' else ''}")
        if self.dry:
            return
        os.makedirs(d, exist_ok=True)
        if link == "hbr2" and not self.forced:
            self.trace_start()
            try:
                open(f"{self.dri}/{self.cname}/link_settings", "w").write("4 0x14")
            except OSError as e:
                self.say(f"   link_settings write failed: {e}")
            time.sleep(3)
            self.trace_stop(os.path.join(d, "trace-linkforce.txt"))
            self.forced = True
        written, n = set(), 0
        dsc = f"{self.dri}/{self.cname}/dsc_clock_en"
        if link == "nodsc":
            try:
                open(dsc, "w").write("2")   # DSC_CLK_FORCE_DISABLE, used at the next mode set
            except OSError as e:
                self.say(f"   dsc_clock_en write failed: {e}")
        if rule:
            self.trace_start()
            r = self.hypr("eval", self.lua_monitor(rule))
            time.sleep(4)
            written, n = self.trace_stop(os.path.join(d, "trace-modeset.txt"))
            ncmd = sum(1 for l in open(os.path.join(d, "trace-modeset.txt"), errors="replace") if "dmubcmd" in l)
            self.say(f"   hyprctl: {r.strip()[:80]}; {n} register writes traced, {len(written)} distinct registers; {ncmd} DMUB commands")
        if link == "nodsc":
            try:
                open(dsc, "w").write("0")   # back to DSC_CLK_FORCE_DEFAULT (applies at the next mode set)
            except OSError:
                pass
        if link == "dpms":
            self.dpms(d, written)
        time.sleep(2)
        m = self.monitor()
        json.dump(m, open(os.path.join(d, "hyprctl-monitor.json"), "w"), indent=1)
        f0 = self.readregs([0x0500C]).get(0x0500C, 0)
        time.sleep(1.0)
        f1 = self.readregs([0x0500C]).get(0x0500C, 0)
        regs = self.readregs(set(FIXED) | written)
        with open(os.path.join(d, "regs.txt"), "w") as f:
            f.write("# dword value name (steady state after the switch; names only for the fixed list)\n")
            for r, v in regs.items():
                f.write(f"0x{r:05X} {v if isinstance(v, str) else f'0x{v:08x}'} {FIXED.get(r, '')}\n")
        for p in ("amdgpu_dm_dtn_log", "amdgpu_dm_dmub_tracebuffer", "amdgpu_firmware_info", "amdgpu_pm_info", "amdgpu_dm_capabilities"):
            self.cat(f"{self.dri}/{p}", os.path.join(d, p + ".txt"))
        cd = f"{self.dri}/{self.cname}"
        with open(os.path.join(d, "connector.txt"), "w") as f:
            for p in sorted(glob.glob(cd + "/*")):
                b = os.path.basename(p)
                if b in ("dp_sdp_message", "test_pattern", "trigger_hotplug", "aux_dpcd_address", "aux_dpcd_size", "aux_dpcd_data") or not os.path.isfile(p):
                    continue
                try:
                    f.write(f"--- {b}\n{open(p, errors='replace').read(65536)}\n")
                except OSError as e:
                    f.write(f"--- {b}: {e}\n")
        for base, b in self.dpcd().items():
            open(os.path.join(d, f"dpcd-{base:04x}.bin"), "wb").write(b)
        for p in glob.glob(f"/sys/class/drm/{self.card}/device/pp_dpm_*"):
            self.cat(p, os.path.join(d, os.path.basename(p) + ".txt"))
        mv = regs.get(0x056D2, 0); nv = regs.get(0x056D1, 0); cfg = regs.get(0x056CB, 0); pf = regs.get(0x056C9, 0)
        self.say(f"   now: {m.get('width')}x{m.get('height')} @ {m.get('refreshRate')} Hz; OTG0 frames/s {(f1 - f0) & 0xffffffff}; "
                 f"lanes {(cfg & 3) + 1 if isinstance(cfg, int) else '?'}; VID_M/N 0x{mv:x}/0x{nv:x}; DP_PIXEL_FORMAT 0x{pf:08x}")

    def dpms_cmd(self, state):
        r = self.hypr("dispatch", "dpms", state, self.cname)
        if "ok" not in r.lower():   # Hyprland with a Lua config: the dispatcher through eval
            r += " | eval: " + self.hypr("eval", f'hl.dispatch("dpms", "{state} {self.cname}")')
        return r.strip()[:120]

    def dpms(self, d, written):
        """v5: DPMS off and on at the mode just set, each traced; the state read while off and after on."""
        time.sleep(3)
        self.trace_start()
        r = self.dpms_cmd("off")
        time.sleep(3)
        woff, n = self.trace_stop(os.path.join(d, "trace-dpms-off.txt"))
        written |= woff
        self.say(f"   dpms off: {r}; {n} register writes traced, {len(woff)} distinct")
        time.sleep(2)
        f0 = self.readregs([0x0500C]).get(0x0500C, 0)
        time.sleep(1.0)
        f1 = self.readregs([0x0500C]).get(0x0500C, 0)
        regs = self.readregs(set(FIXED) | woff)
        with open(os.path.join(d, "regs-off.txt"), "w") as f:
            f.write("# dword value name (while DPMS off)\n")
            for rg, v in regs.items():
                f.write(f"0x{rg:05X} {v if isinstance(v, str) else f'0x{v:08x}'} {FIXED.get(rg, '')}\n")
        for base, b in self.dpcd().items():
            open(os.path.join(d, f"dpcd-off-{base:04x}.bin"), "wb").write(b)
        self.say(f"   while off: OTG0_CONTROL 0x{regs.get(0x05001, 0):08x}, OTG0 frames/s {(f1 - f0) & 0xffffffff}")
        self.trace_start()
        r = self.dpms_cmd("on")
        time.sleep(4)
        won, n = self.trace_stop(os.path.join(d, "trace-dpms-on.txt"))
        written |= won
        ncmd = sum(1 for l in open(os.path.join(d, "trace-dpms-on.txt"), errors="replace") if "dmubcmd" in l)
        self.say(f"   dpms on: {r}; {n} register writes traced, {len(won)} distinct; {ncmd} DMUB commands")

    def dpms_steps(self, rates=None):
        """v5 (2026-11-23): DPMS off / on at every 1440p rate, SDR (8 bpc) and HDR (10 bpc)."""
        if rates is None:
            m = self.monitor()
            rates = sorted({x.replace("Hz", "").strip().split("@")[1] for x in m.get("availableModes", []) if x.startswith("2560x1440@")}, key=float)
        self.say(f"1440p rates: {' '.join(rates)}")
        steps = ["base"]
        for r in rates:
            STEPS[f"dpms-{r}"] = (f"2560x1440@{r}", 8, "dpms", False, 0)
            STEPS[f"dpms-hdr-{r}"] = (f"2560x1440@{r}", 10, "dpms", True, 0)
            steps += [f"dpms-{r}", f"dpms-hdr-{r}"]
        return steps

    def all_modes(self):
        """v3 (2026-11-20): every mode the monitor offers, each from the 144 Hz hub and back, then Adaptive Sync (vrr 1) and
        HDR at every 1440p rate, each from the hub and back. Step names: to-<mode> / from-<mode> (the hub after it)."""
        m = self.monitor()
        modes = []
        for x in m.get("availableModes", []):
            x = x.replace("Hz", "").strip()
            if re.match(r"^\d+x\d+@[\d.]+$", x) and x not in modes:
                modes.append(x)
        self.say(f"available modes ({len(modes)}): {' '.join(modes)}")
        hub = "2560x1440@144"
        rates = sorted({x.split("@")[1] for x in modes if x.startswith("2560x1440@")}, key=float)
        steps = ["base", "hub"]
        STEPS["hub"] = (hub, 8, "auto", False, 0)
        def pair(name, ent):
            STEPS["to-" + name] = ent
            STEPS["from-" + name] = (hub, 8, "auto", False, 0)
            steps.extend(["to-" + name, "from-" + name])
        for x in modes:
            if x.startswith("2560x1440@144"):
                continue
            pair(x, (x, 8, "auto", False, 0))
        for r in rates:
            pair(f"vrr-{r}", (f"2560x1440@{r}", 8, "auto", False, 1))
        for r in rates:
            pair(f"hdr-{r}", (f"2560x1440@{r}", 10, "auto", True, 0))
        return steps

    def hdr_pairs(self, rates=None):
        """v4 (2026-11-21): HDR only: the SDR 144 Hz hub, then for each 1440p rate SDR hub -> HDR at that rate (to-hdr-<r>)
        and back to the SDR hub (from-hdr-<r>); each step's monitor rule names its colour mode, so every from-hdr ends in SDR."""
        if rates is None:
            m = self.monitor()
            rates = sorted({x.replace("Hz", "").strip().split("@")[1] for x in m.get("availableModes", []) if x.startswith("2560x1440@")}, key=float)
        self.say(f"1440p rates: {' '.join(rates)}")
        hub = "2560x1440@144"
        STEPS["hub"] = (hub, 8, "auto", False, 0)
        steps = ["base", "hub"]
        for r in rates:
            STEPS[f"to-hdr-{r}"] = (f"2560x1440@{r}", 10, "auto", True, 0)
            STEPS[f"from-hdr-{r}"] = (hub, 8, "auto", False, 0)
            steps += [f"to-hdr-{r}", f"from-hdr-{r}"]
        return steps

    def run(self):
        steps = self.a.steps.split(",") if self.a.steps else (DEFAULT + (HBR2 if self.a.hbr2 else []) + (HDR if self.a.hdr else [])
                                                             + (R240 if self.a.r240 else []))
        for s in steps:
            if s not in STEPS:
                sys.exit(f"unknown step {s}; known: {', '.join(STEPS)}")
        # the forced-HBR2 steps run last (the forced link stays until power-off)
        steps = [s for s in steps if not s.startswith("hbr2")] + [s for s in steps if s.startswith("hbr2")]
        self.forced = False
        if self.dry:
            self.cname = "DP-?"
            if self.a.hdr_pairs:   # the live list needs root and Hyprland: the LG's rates (capture v3) stand in
                steps = self.hdr_pairs(["59.95", "120.00", "143.99", "239.97"])
            elif self.a.dpms:
                steps = self.dpms_steps(["59.95", "120.00", "143.99", "239.97"])
            for s in steps:
                self.step(s, "/nonexistent")
            return
        if os.geteuid() != 0:
            sys.exit("run as root (sudo)")
        self.find()
        if self.a.all_modes:
            steps = self.all_modes()
        elif self.a.hdr_pairs:
            steps = self.hdr_pairs()
        elif self.a.dpms:
            steps = self.dpms_steps()
        need = (512 if self.a.all_modes else 64) << 20
        st = shutil.disk_usage(self.a.outdir if os.path.isdir(self.a.outdir) else os.path.dirname(self.a.outdir.rstrip("/")) or "/")
        if st.free < need:
            sys.exit(f"{self.a.outdir}: less than {need >> 20} MiB free")
        if not os.path.exists(f"{TRACE}/events/{EVENT}/enable"):
            sys.exit(f"no ftrace event {EVENT} (tracefs at {TRACE}?)")
        out = os.path.join(self.a.outdir, "display-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.makedirs(out)
        self.say(f"out {out}; kernel {os.uname().release}; steps {','.join(steps)}")
        try:
            e = open(self.conn + "/edid", "rb").read()
            open(os.path.join(out, "edid-noserial.bin"), "wb").write(strip_edid(e))
            self.say(f"EDID {len(e)} bytes (serials stripped in the copy)")
        except OSError as e:
            self.say(f"EDID unreadable: {e}")
        self.kprobes_add()
        try:
            for s in steps:
                try:
                    self.step(s, out)
                except Exception as ex:   # keep going: one failed step must not leave the monitor half-switched
                    self.say(f"   step {s} failed: {ex!r}")
        finally:
            self.kprobes_remove()
            if self.a.dpms:
                try:
                    self.say(f"restore: dpms on -> {self.dpms_cmd('on')}")
                except Exception as ex:
                    self.say(f"dpms on failed: {ex!r} (run 'hyprctl dispatch dpms on' by hand)")
            try:
                self.say(f"restore: hyprctl reload -> {self.hypr('reload').strip()[:60]}")
            except Exception as ex:
                self.say(f"restore failed: {ex!r} (run 'hyprctl reload' by hand)")
            if self.forced:
                self.say("the link stays forced to HBR2 x4 until power-off (Linux only; nothing persists)")
            open(os.path.join(out, "summary.txt"), "w").write("\n".join(self.log) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1] if __doc__ else "")
    ap.add_argument("outdir")
    ap.add_argument("--hbr2", action="store_true", help="add the steps with the link forced to HBR2 x4")
    ap.add_argument("--hdr", action="store_true", help="add the HDR steps (Hyprland cm,hdr)")
    ap.add_argument("--r240", action="store_true", help="add 240-10, hdr-240 and 240-nodsc")
    ap.add_argument("--all-modes", action="store_true", help="v3: every available mode from the 144 hub and back, VRR and HDR at every 1440p rate")
    ap.add_argument("--hdr-pairs", action="store_true", help="v4: HDR only, SDR 144 hub -> HDR at each 1440p rate -> SDR hub")
    ap.add_argument("--dpms", action="store_true", help="v5: DPMS off / on at every 1440p rate, SDR and HDR (display sleep)")
    ap.add_argument("--steps", help="comma list, overrides the default set")
    ap.add_argument("--dry-run", action="store_true")
    Cap(ap.parse_args()).run()


if __name__ == "__main__":
    main()
