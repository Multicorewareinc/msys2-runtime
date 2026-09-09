#!/bin/bash
# Stage the mingw64 winpthreads headers into the aarch64 sysroot so the ARM64
# crt builds. Vendored from msys2-woarm64-build (.github/scripts) so this repo
# needs no external driver clone.
set -eo pipefail

pacman -S --noconfirm mingw-w64-cross-mingw64-winpthreads
cp /opt/x86_64-w64-mingw32/include/pthread_signal.h /opt/aarch64-w64-mingw32/include/
cp /opt/x86_64-w64-mingw32/include/pthread_unistd.h /opt/aarch64-w64-mingw32/include/
cp /opt/x86_64-w64-mingw32/include/pthread_time.h /opt/aarch64-w64-mingw32/include/
cp /opt/x86_64-w64-mingw32/include/pthread_compat.h /opt/aarch64-w64-mingw32/include/
