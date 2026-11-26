#!/bin/sh
# SPDX-License-Identifier: MIT
# install-check.sh: the Installer's own check for Vermilion-<version>.pkg, run from distribution.xml's installCheck()
# (system.run) before the install is offered, as the user who opened the package. It makes no change and prints nothing;
# the exit code says why the package refuses, and distribution.xml words the message:
#   0  macOS build and GPU are right      1  another macOS build      2  no RX 7900 XTX (1002:744c, revision 0xC8)
#   3  another 1002:744c board is present (RX 7900 XT, GRE, 7900M, or an unknown revision)
# The same checks as the preinstall script (lib.sh: EXPECT_BUILD, check_gpu), which stays: it also covers
# `installer -pkg` from a terminal and is the one that runs as root.
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
# Replaces lib.sh's refuse(): no message, and check_gpu's GPU_FAIL picks the exit code.
refuse() { case ${GPU_FAIL:-} in none) exit 2 ;; other) exit 3 ;; *) exit 1 ;; esac; }
build=$(sw_vers -buildVersion 2>/dev/null)
[ "$build" = "$EXPECT_BUILD" ] || exit 1
check_gpu >/dev/null 2>&1 || exit $?
exit 0
