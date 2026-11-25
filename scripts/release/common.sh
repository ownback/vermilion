# SPDX-License-Identifier: MIT
# common.sh: shared by make-pkg.sh and make-oc-zip.sh (sourced; POSIX sh).

# usage: print the calling script's header comment (line 3 up to `set -eu`) and exit 2
usage() { sed -n '3,/^set -eu/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2; }

# check_version <script name> <version>: exit 2 unless <version> is <major>.<minor>.<patch>[-suffix]
check_version() {
  echo "$2" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$' ||
    { echo "$1: version '$2' is not <major>.<minor>.<patch>[-suffix]" >&2; exit 2; }
}
