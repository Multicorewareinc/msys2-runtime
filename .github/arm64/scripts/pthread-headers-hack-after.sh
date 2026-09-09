#!/bin/bash
# Undo pthread-headers-hack-before.sh: remove the staged headers and the
# temporary mingw64 winpthreads. Vendored from msys2-woarm64-build.
set -eo pipefail

pacman -R --noconfirm mingw-w64-cross-mingw64-winpthreads || true
rm -rf /opt/aarch64-w64-mingw32/include/pthread_signal.h
rm -rf /opt/aarch64-w64-mingw32/include/pthread_unistd.h
rm -rf /opt/aarch64-w64-mingw32/include/pthread_time.h
rm -rf /opt/aarch64-w64-mingw32/include/pthread_compat.h
