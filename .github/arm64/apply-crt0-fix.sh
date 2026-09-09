#!/usr/bin/env bash
# apply-crt0-fix.sh — RETIRED (issue #3).
#
# This script used to work around a packaging defect: the stage-2 runtime
# package_*() was commented out, so the real crt0.o (which calls msys_crt0 ->
# _msys_crt0_common) never overwrote the bootstrap STUB crt0.o (mainCRTStartup ==
# `nop; ret`) in the sysroot. With the stub, __cygwin_user_data.main stayed NULL
# and every linked exe hung at startup.
#
# That defect is now fixed at the source: the cross-msysarm64-runtime package()
# is enabled and STRICT (it refuses to package a stub crt0.o), and the build
# orchestrator (build-msys2-woarm64-all.sh step 16) `pacman -U`'s that package so
# the REAL crt0.o ships through pacman. There is nothing left for this script to
# patch. It is kept only as a no-op shim + sysroot sanity check so any external
# caller / CI reference does not break.
set -euo pipefail

SYSROOT_LIB="/usr/aarch64-pc-msys/lib"

cat <<'MSG'
apply-crt0-fix.sh is RETIRED (issue #3).
The real crt0.o now ships via the cross-msysarm64-runtime package, installed by
build-msys2-woarm64-all.sh step 16 (pacman -U). No manual crt0 staging is needed.
MSG

# Sanity check only: confirm the installed crt0.o is the real one. This does NOT
# patch anything — it just reports, so the retirement is verifiable.
if [[ -f "$SYSROOT_LIB/crt0.o" ]]; then
  if aarch64-pc-msys-nm "$SYSROOT_LIB/crt0.o" 2>/dev/null | grep -q "U msys_crt0"; then
    echo "OK: $SYSROOT_LIB/crt0.o is the REAL crt0 (U msys_crt0) — packaging path is healthy."
  else
    echo "WARNING: $SYSROOT_LIB/crt0.o has no 'U msys_crt0' (looks like the STUB)."
    echo "         Install the cross-msysarm64-runtime package (build step 16) to fix it."
  fi
else
  echo "note: $SYSROOT_LIB/crt0.o not present yet (runtime package not installed)."
fi
echo "DONE (no changes made)."
