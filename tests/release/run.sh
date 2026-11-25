#!/bin/bash
# SPDX-License-Identifier: MIT
# run.sh: every hardware-free release test: the release scan, the OpenCore zip and snippet, the package scripts, the
# package build (macOS). Exit 0 only when all pass. Used by .github/workflows/release.yml.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
rc=0
for t in release_scan_test.sh oc_zip_test.sh pkg_scripts_test.sh pkg_build_test.sh; do
  echo "== $t"
  bash "$HERE/$t" || { echo "FAILED: $t"; rc=1; }
done
exit $rc
