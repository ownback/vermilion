// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
/* Our code (Vermilion): checks on a destination the plugin does not own, pure (Mach calls only) so a host test can run
   them (tests/plugin/test_safe_copy.c). An IOSurface's plane in an app's address space can be another framework's
   memory, which that framework frees on its own schedule (Music on the XTX machine, finding
   2026-11-25-plugin-crashes-root-cause.md). */
#ifndef NVMTL_SAFE_COPY_H
#define NVMTL_SAFE_COPY_H
#include <stddef.h>
#include <stdint.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

/* Whether rows rows of tight bytes, row bytes apart from base, are mapped in this process with the access need.
   One mach_vm_region per VM region the span covers. On NO, *bad is the first address that fails and *unmapped is 1 when
   it is in no region, 0 when it is mapped without the access. */
static inline int nvmtl_span_mapped(const void *base, size_t row, uint32_t rows, size_t tight, vm_prot_t need,
                                    mach_vm_address_t *bad, int *unmapped)
{
    if (!rows) return 1;
    mach_vm_address_t a = (mach_vm_address_t)(uintptr_t)base;
    const mach_vm_address_t end = a + (mach_vm_size_t)(rows - 1) * row + (mach_vm_size_t)tight;
    while (a < end) {
        mach_vm_address_t ra = a; mach_vm_size_t rs = 0; mach_port_t obj = MACH_PORT_NULL;
        vm_region_basic_info_data_64_t info; mach_msg_type_number_t n = VM_REGION_BASIC_INFO_COUNT_64;
        const kern_return_t kr = mach_vm_region(mach_task_self(), &ra, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &n, &obj);
        if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
        if (kr != KERN_SUCCESS || ra > a || (info.protection & need) != need || !rs) {
            if (bad) *bad = a;
            if (unmapped) *unmapped = kr != KERN_SUCCESS || ra > a;
            return 0;
        }
        a = ra + rs;
    }
    return 1;
}

/* Largest piece one kernel call copies. Up to msg_ool_size_small (two pages on x86_64) XNU's vm_map_copyin goes through
   a kernel buffer: copyin from the source, copyout into the destination. Neither mapping is then made copy-on-write or
   has its pages replaced, which matters because the source is a GPU-visible staging buffer and the destination an
   IOSurface's pages (from XNU's source, unverified on the XTX machine). */
#define NVMTL_SAFE_COPY_CHUNK 8192u

/* Copies rows rows of tight bytes from src (packed) to dst (row bytes apart) through the kernel. A destination that is
   no longer mapped writable makes this return the kernel's error (KERN_INVALID_ADDRESS, KERN_PROTECTION_FAILURE)
   instead of faulting the process. The rows before a failure may have landed. Packed rows (row == tight) go as one
   span. */
static inline kern_return_t nvmtl_copy_to_foreign(void *dst, size_t row, const void *src, size_t tight, uint32_t rows)
{
    const int packed = row == tight;
    const size_t spans = packed ? (rows ? 1 : 0) : rows, len = packed ? tight * rows : tight;
    for (size_t y = 0; y < spans; y++) {
        const uint8_t *s = (const uint8_t *)src + y * tight;
        uint8_t *d = (uint8_t *)dst + y * row;
        for (size_t off = 0; off < len; ) {
            const size_t n = len - off < NVMTL_SAFE_COPY_CHUNK ? len - off : NVMTL_SAFE_COPY_CHUNK;
            mach_vm_size_t got = 0;
            const kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(uintptr_t)(s + off), n,
                                                            (mach_vm_address_t)(uintptr_t)(d + off), &got);
            if (kr != KERN_SUCCESS) return kr;
            if (got != n) return KERN_FAILURE;
            off += n;
        }
    }
    return KERN_SUCCESS;
}
#endif
