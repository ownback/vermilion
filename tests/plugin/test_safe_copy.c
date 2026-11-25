// SPDX-License-Identifier: MIT
/* test_safe_copy.c - the readback's checks and copy into memory the plugin does not own (src/metal-plugin/nvmtl_safe_copy.h,
   used by nvmtl_vk_image_read). A destination that goes away must make the copy return an error, never fault.
   cc -I src/metal-plugin tests/plugin/test_safe_copy.c -o /tmp/test_safe_copy && /tmp/test_safe_copy */
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include "nvmtl_safe_copy.h"
static int fails;
static void arm(const char *w, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", w); if (!ok) fails++; }
static void *map(size_t n) {
    mach_vm_address_t a = 0;
    return mach_vm_allocate(mach_task_self(), &a, n, VM_FLAGS_ANYWHERE) == KERN_SUCCESS ? (void *)(uintptr_t)a : NULL;
}
static void unmap(void *p, size_t n) { mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)(uintptr_t)p, n); }
static void fill(uint8_t *p, size_t n, unsigned seed) { for (size_t i = 0; i < n; i++) p[i] = (uint8_t)(i * 7 + seed); }
static int rows_match(const uint8_t *dst, size_t row, const uint8_t *src, size_t tight, uint32_t rows) {
    for (uint32_t y = 0; y < rows; y++) if (memcmp(dst + y * row, src + y * tight, tight)) return 0;
    return 1;
}
// The Music case: the plane is freed by another thread while the copy runs, again and again.
struct race { void *dst; size_t size; volatile int go; };
static void *racer(void *arg) {
    struct race *r = arg;
    while (!r->go) ;
    usleep(200);
    unmap(r->dst, r->size);
    return NULL;
}
int main(void)
{
    const uint32_t W = 600, H = 600, BPP = 4; const size_t tight = W * BPP, plane = tight * H;   // Music's album art
    uint8_t *src = map(plane); fill(src, plane, 1);

    uint8_t *dst = map(plane); mach_vm_address_t bad = 1; int unmapped = 9;
    arm("a mapped writable plane passes the check", nvmtl_span_mapped(dst, tight, H, tight, VM_PROT_WRITE, &bad, &unmapped));
    arm("packed 600x600 BGRA (2400 B rows) copies through the kernel, every byte",
        nvmtl_copy_to_foreign(dst, tight, src, tight, H) == KERN_SUCCESS && !memcmp(dst, src, plane));
    {   // cost, for the record (host memory on both sides; the real source is a GPU staging buffer)
        const int N = 200; uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int i = 0; i < N; i++) nvmtl_copy_to_foreign(dst, tight, src, tight, H);
        uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int i = 0; i < N; i++) { memcpy(dst, src, plane); __asm__ volatile("" ::: "memory"); }
        uint64_t t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        printf("info  1.44 MB plane: kernel copy %.0f us, memcpy %.0f us\n", (t1 - t0) / 1e3 / N, (t2 - t1) / 1e3 / N);
    }
    unmap(dst, plane);

    const size_t row = 2560; uint8_t *sdst = map(row * H); memset(sdst, 0xAB, row * H);
    int pad = 1;
    arm("strided rows (2400 B of 2560) copy row by row", nvmtl_copy_to_foreign(sdst, row, src, tight, H) == KERN_SUCCESS
        && rows_match(sdst, row, src, tight, H));
    for (uint32_t y = 0; y < H; y++) for (size_t x = tight; x < row; x++) if (sdst[y * row + x] != 0xAB) pad = 0;
    arm("the padding past each row is not written", pad);
    unmap(sdst, row * H);

    const size_t wide = 3 * NVMTL_SAFE_COPY_CHUNK + 100, wrow = wide + 64; uint8_t *wsrc = map(wide * 3), *wdst = map(wrow * 3);
    fill(wsrc, wide * 3, 5);
    arm("a row longer than one kernel call (3 chunks + 100 B) copies whole", nvmtl_copy_to_foreign(wdst, wrow, wsrc, wide, 3) == KERN_SUCCESS
        && rows_match(wdst, wrow, wsrc, wide, 3));
    unmap(wsrc, wide * 3); unmap(wdst, wrow * 3);

    arm("zero rows: nothing to check, nothing copied", nvmtl_span_mapped((void *)16, 0, 0, 0, VM_PROT_WRITE, NULL, NULL)
        && nvmtl_copy_to_foreign((void *)16, 0, src, 0, 0) == KERN_SUCCESS);

    uint8_t *gone = map(plane); unmap(gone, plane);
    bad = 0; unmapped = 0;
    arm("NEGATIVE: a freed plane fails the check, as not mapped, at its base",
        !nvmtl_span_mapped(gone, tight, H, tight, VM_PROT_WRITE, &bad, &unmapped) && unmapped && bad == (mach_vm_address_t)(uintptr_t)gone);
    arm("NEGATIVE: the copy into a freed plane returns an error and does not fault",
        nvmtl_copy_to_foreign(gone, tight, src, tight, H) != KERN_SUCCESS);

    uint8_t *ro = map(plane); mach_vm_protect(mach_task_self(), (mach_vm_address_t)(uintptr_t)ro, plane, FALSE, VM_PROT_READ);
    unmapped = 1;
    arm("NEGATIVE: a read-only plane fails the check, as mapped without the access",
        !nvmtl_span_mapped(ro, tight, H, tight, VM_PROT_WRITE, &bad, &unmapped) && !unmapped);
    arm("NEGATIVE: the copy into a read-only plane returns an error and does not fault",
        nvmtl_copy_to_foreign(ro, tight, src, tight, H) != KERN_SUCCESS);
    unmap(ro, plane);

    const size_t pg = (size_t)vm_page_size; uint8_t *hsrc = map(4 * pg); fill(hsrc, 4 * pg, 9);   // first: made after the hole, it could fill it
    uint8_t *half = map(4 * pg); unmap(half + 2 * pg, 2 * pg);
    arm("NEGATIVE: a plane whose second half is gone fails the check at the first missing page",
        !nvmtl_span_mapped(half, 4 * pg, 1, 4 * pg, VM_PROT_WRITE, &bad, &unmapped) && bad == (mach_vm_address_t)(uintptr_t)(half + 2 * pg));
    arm("NEGATIVE: copying it returns an error; the pages before the hole got their bytes",
        nvmtl_copy_to_foreign(half, 4 * pg, hsrc, 4 * pg, 1) != KERN_SUCCESS && !memcmp(half, hsrc, 2 * pg));
    unmap(half, 2 * pg); unmap(hsrc, 4 * pg);

    int raced = 0, survived = 1;
    for (int k = 0; k < 20; k++) {
        struct race r = { map(plane), plane, 0 }; pthread_t t;
        pthread_create(&t, NULL, racer, &r);
        r.go = 1;
        for (int i = 0; i < 2000; i++) if (nvmtl_copy_to_foreign(r.dst, tight, src, tight, H) != KERN_SUCCESS) { raced++; break; }
        pthread_join(t, NULL);
        if (nvmtl_copy_to_foreign(r.dst, tight, src, tight, H) == KERN_SUCCESS) survived = 0;   // gone for good now
    }
    arm("RACE: a plane freed by another thread during the copies (20 rounds) ends in an error, never a fault", raced > 0 && survived);

    unmap(src, plane);
    printf("%s (%d failed)\n", fails ? "FAILED" : "ALL ARMS HOLD", fails);
    return fails != 0;
}
