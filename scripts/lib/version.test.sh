#!/usr/bin/env bash
# Unit test for derive_build_number. Run: bash scripts/lib/version.test.sh
set -euo pipefail
source "$(dirname "$0")/version.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

eq "$(derive_build_number 1.0.0)" 1000000
eq "$(derive_build_number 1.0.1)" 1000001
eq "$(derive_build_number 1.1.0)" 1001000
eq "$(derive_build_number 2.0.0)" 2000000
eq "$(derive_build_number 10.20.30)" 10020030

# strictly increasing across a realistic release sequence
prev=0
for v in 1.0.0 1.0.1 1.0.9 1.1.0 1.2.0 2.0.0 10.0.0; do
  n="$(derive_build_number "$v")"
  (( n > prev )) || fail "$v -> $n not greater than previous $prev"
  prev="$n"
done

# rejects malformed input
if derive_build_number 1.2 2>/dev/null; then fail "accepted '1.2'"; fi
if derive_build_number 1.0.x 2>/dev/null; then fail "accepted '1.0.x'"; fi
if derive_build_number 1.0.1000 2>/dev/null; then fail "accepted patch >= 1000"; fi
if derive_build_number 1.1000.0 2>/dev/null; then fail "accepted minor >= 1000"; fi

echo "version.test.sh: OK"
