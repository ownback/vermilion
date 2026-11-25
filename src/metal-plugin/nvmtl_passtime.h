// SPDX-License-Identifier: MIT
/* nvmtl_passtime.h: when a process arms the per-pass GPU timer (nvmtl_pt_armed in nvmtl_vk.c).
   Kernel- and Vulkan-free: tests/plugin/test_passtime.c runs it on a host.

   A touch of NVMTL_PT_REQUEST_PATH arms every rendering process ONCE. Before 2026-11-25, the first process to see
   the file unlinked it. WindowServer runs as _windowserver and cannot unlink the owner's file in the sticky /tmp, so it
   armed again every 250 ms for as long as the file existed. In the Maps capture of 2026-11-25 that was ~2 minutes and
   496 windows of 400 passes, and the other processes (Maps, the Dock) raced it for the file. Now nobody unlinks it. A
   process arms when the request is new to it (another inode or mtime than the one it last armed for) and recent (mtime
   at most NVMTL_PT_MAX_AGE_NS old). Touch the file again for another window. */
#pragma once
#include <stdint.h>

#define NVMTL_PT_REQUEST_PATH "/tmp/nvmtl-passtime-request"
#define NVMTL_PT_PASSES       400                      /* render passes timed per arm (one window) */
#define NVMTL_PT_POLL_NS      250000000ull             /* a disarmed process stats the request at most this often */
#define NVMTL_PT_MAX_AGE_NS   (15ull * 1000000000ull)
#define NVMTL_PT_STR_(x) #x
#define NVMTL_PT_STR(x)  NVMTL_PT_STR_(x)

typedef struct { uint64_t ino, mtime_ns; } nvmtl_pt_req;

/* exists: the request file is there; ino and mtime_ns from its stat; now_ns on the same clock as mtime (CLOCK_REALTIME);
   last: the request this process last armed for (zero before the first), updated when this returns 1. */
static inline int nvmtl_pt_should_arm(int exists, uint64_t ino, uint64_t mtime_ns, uint64_t now_ns, nvmtl_pt_req *last)
{
    if (!exists || !last) return 0;
    if (last->ino == ino && last->mtime_ns == mtime_ns) return 0;   /* this request armed us already */
    if (mtime_ns + NVMTL_PT_MAX_AGE_NS < now_ns) return 0;          /* an old touch: a process started long after it */
    last->ino = ino; last->mtime_ns = mtime_ns;
    return 1;
}
