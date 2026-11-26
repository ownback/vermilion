// SPDX-License-Identifier: MIT
// c3_image_test.cpp: the C3 image arrives at run time (PhxC3Load.h imageSeal, PhxSha256.h), not from the binary.
//   Needs the firmware the build fetched (tools/firmware/fetch_firmware.sh into a scratch dir, never committed) and
//   src/vermilion-boot/phx_c3_hash.inc (python3 tools/firmware/c3_image.py --fw <dir>/dcn_3_2_0_dmcub.bin).
//   c++ -std=c++17 -Wall -Wextra -Werror -I src/vermilion-boot -o /tmp/c3_image_test tests/kext/c3_image_test.cpp
//   /tmp/c3_image_test <dir>/dcn_3_2_0_dmcub.bin [dump <file>]
//   `dump <file>` writes every command the kext would send for PHY D (1475 x 64 bytes) and for PHYs A and E (the DP path);
//   built with -DPHX_OLD_INLINE against a tree that still has phx_c3_image.inc (fork/main before this change) the same dump
//   comes from the compiled-in array, so `cmp` of the two files proves the bytes handed to the hardware are unchanged.
#include "PhxC3Phy.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

#ifndef PHX_OLD_INLINE
static void sha(const char *msg, size_t n, uint8_t out[32]) {
    phxsha::Sha256 s;
    phxsha::init(s);
    // feed in odd-sized pieces: the buffering must not matter
    for (size_t i = 0; i < n;) { size_t k = (i % 7) + 1; if (k > n - i) k = n - i; phxsha::update(s, reinterpret_cast<const uint8_t *>(msg) + i, k); i += k; }
    phxsha::final(s, out);
}
static bool hexeq(const uint8_t *d, const char *hex) {
    char b[65];
    for (int i = 0; i < 32; i++) snprintf(b + 2 * i, 3, "%02x", d[i]);
    return !strcmp(b, hex);
}
#endif

int main(int argc, char **argv) {
#ifndef PHX_OLD_INLINE
    uint8_t d[32];
    sha("", 0, d); CHECK(hexeq(d, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    sha("abc", 3, d); CHECK(hexeq(d, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    const char *m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    sha(m, strlen(m), d); CHECK(hexeq(d, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
#endif
    if (argc < 2) { printf("usage: c3_image_test <dcn_3_2_0_dmcub.bin> [dump <file>]\n"); return fails ? 1 : 2; }

    std::vector<uint8_t> fw;
    FILE *f = fopen(argv[1], "rb");
    if (!f) { printf("cannot open %s\n", argv[1]); return 2; }
    uint8_t tmp[4096];
    for (size_t n; (n = fread(tmp, 1, sizeof tmp, f)) > 0;) fw.insert(fw.end(), tmp, tmp + n);
    fclose(f);
    constexpr size_t kOff = 0xE200, kLen = 0xA000;   // the C3 slice of the file (tools/firmware/c3_image.py OFF, LEN)
    CHECK(fw.size() >= kOff + kLen);

#ifndef PHX_OLD_INLINE
    static_assert(phxc3::kImageBytes == kLen, "the slice length");
    // not installed: no image, the burst commands are refused, the prologue and the end command do not need it
    CHECK(phxc3::image() == nullptr);
    uint32_t c[phxdmub::kCmdDw];
    CHECK(!phxc3::loadCmd(phxc3::kProN, c));
    CHECK(phxc3::loadCmd(0, c) && phxc3::loadCmd(phxc3::kLast, c));
    CHECK(!phxc3p::loadCmdPhy(phxc3::kProN, 0, c));
    // wrong content: a flipped bit anywhere is refused (SHA-256), the image stays absent
    for (size_t at : {size_t(0), size_t(kLen / 2), size_t(kLen - 1)}) {
        memcpy(phxc3::imageBuf(), fw.data() + kOff, kLen);
        reinterpret_cast<uint8_t *>(phxc3::imageBuf())[at] ^= 0x10;
        CHECK(phxc3::imageSeal() == phxc3::kImgSha);
        CHECK(phxc3::image() == nullptr);
        CHECK(!phxc3::loadCmd(phxc3::kProN, c));
    }
    // a slice of another place in the file (the length is right, the content is not)
    memcpy(phxc3::imageBuf(), fw.data() + kOff - 2, kLen);
    CHECK(phxc3::imageSeal() == phxc3::kImgSha && phxc3::image() == nullptr);
    // the right slice: installed, and it is the file's bytes
    memcpy(phxc3::imageBuf(), fw.data() + kOff, kLen);
    CHECK(phxc3::imageSeal() == phxc3::kImgOk);
    CHECK(phxc3::image() && !memcmp(phxc3::image(), fw.data() + kOff, kLen));
    CHECK(phxc3::imageCrc(phxc3::image(), kPhxC3ImageWords) == kPhxC3ImageCrc32);
    // a failed re-install withdraws the image again
    reinterpret_cast<uint8_t *>(phxc3::imageBuf())[5] ^= 1;
    CHECK(phxc3::imageSeal() == phxc3::kImgSha && phxc3::image() == nullptr);
    memcpy(phxc3::imageBuf(), fw.data() + kOff, kLen);
    CHECK(phxc3::imageSeal() == phxc3::kImgOk);
#endif

    if (argc >= 4 && !strcmp(argv[2], "dump")) {
        FILE *o = fopen(argv[3], "wb");
        if (!o) return 2;
        unsigned n = 0;
        uint32_t c[phxdmub::kCmdDw];
        for (unsigned i = 0; phxc3::loadCmd(i, c); i++, n++) fwrite(c, sizeof c, 1, o);
        CHECK(n == phxc3::kLoadN);
        for (unsigned phy : {0u, 4u})
            for (unsigned i = 0; phxc3p::loadCmdPhy(i, phy, c); i++) fwrite(c, sizeof c, 1, o);
        fclose(o);
        printf("dumped %u PHY D commands + PHY A and E to %s\n", n, argv[3]);
    }
    printf("%s\n", fails ? "FAILED" : "c3_image_test: all passed");
    return fails ? 1 : 0;
}
