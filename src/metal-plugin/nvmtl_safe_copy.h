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
#endif
