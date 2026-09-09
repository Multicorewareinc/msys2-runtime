#!/bin/bash
#==============================================================================
# build-msys2-woarm64-all.sh
#
# ONE-SHOT builder for the MSYS2 Windows-on-ARM64 (aarch64-pc-msys) toolchain.
# Reproduces the full manual build, with every fix/workaround baked in:
#   * auto-clones the two source repos if missing
#   * mingw cross chain (8 pkgs) + the pthread-header bootstrap hack
#   * the mingw-gcc libgcc_s.a packaging-bug patch
#   * the $HOME/MSYS2-packages -> real repo symlink (recipes hardcode $HOME)
#   * the 5 cross-msysarm64-* packages
#   * TWO-PHASE runtime builds (newlib then winsup) via build_msys.sh/build-msys.sh
#   * stage1 removal before installing stage2 gcc (file-conflict avoidance)
#   * stage-2 runtime makedepends gcc-stage1 -> gcc swap
#   * benign "package_* command not found" handled by checking the real artifact
#   * final hello-world verification (PE32+ ARM64)
#
# IDEMPOTENT 3-way logic per package:
#   1) already INSTALLED            -> skip
#   2) BUILT (*.pkg.tar.zst) but not installed -> just pacman -U (no rebuild)
#   3) neither                      -> build, then install
#
# RUN FROM THE MSYS SHELL (MSYSTEM=MSYS) ON THE WINDOWS-ON-ARM64 MACHINE.
#
# Usage:
#   ./build-msys2-woarm64-all.sh [START_STEP]
# Env:
#   ROOT=/c/msys2-arm64-build     # parent dir for the two repos (default)
#   FORCE=1                       # force rebuild even if installed/built
#   LOGDIR=$HOME/woarm64-logs     # per-step logs
#   NO_CLONE=1                    # do not auto-clone missing repos
#
# Steps (pass the number as START_STEP to resume):
#    1 preflight (shell check, deps, auto-clone, $HOME symlink)
#    2 mingw headers     3 mingw binutils    4 mingw gcc-stage1
#    5 mingw windows-default-manifest        6 mingw crt (+pthread hack)
#    7 mingw winpthreads 8 mingw gcc (+libgcc_s.a fix, +stage1 removal)  9 mingw zlib
#   10 msys w32api-headers  11 msys runtime-devel  12 msys binutils  13 msys gcc-stage1
#   14 msys runtime stage1 (build_msys.sh)  15 msys gcc stage2 (+stage1 removal)
#   16 msys runtime stage2 (+gcc-stage1->gcc makedepend fix)  17 verify
#==============================================================================

set -uo pipefail

#------------------------------- config ---------------------------------------
ROOT="${ROOT:-/c/msys2-arm64-build}"
PKGS="$ROOT/MSYS2-packages"
DRIVER="$ROOT/msys2-woarm64-build"
LOGDIR="${LOGDIR:-$HOME/woarm64-logs}"
FORCE="${FORCE:-0}"
NO_CLONE="${NO_CLONE:-0}"
START_STEP="${1:-1}"
# STOP_AFTER=N stops cleanly (exit 0) once all steps <=N have run. 0 = no limit.
# Used to split the ~7-8h emulated bootstrap across two CI jobs (GitHub caps a
# single job at 6h): phase 1 runs STOP_AFTER=9 (mingw chain), phase 2 runs the
# rest (steps 1-9 fast install-prebuilt from cache, then build 10-17).
STOP_AFTER="${STOP_AFTER:-0}"

PKGS_REPO="${PKGS_REPO:-https://github.com/Multicorewareinc/MSYS2-packages.git}"
PKGS_BRANCH="${PKGS_BRANCH:-woarm64}"
DRIVER_REPO="${DRIVER_REPO:-https://github.com/Windows-on-ARM-Experiments/msys2-woarm64-build.git}"
DRIVER_BRANCH="${DRIVER_BRANCH:-native-mingw-toolchain-2}"

MINGW_LIBDIR="/opt/aarch64-w64-mingw32/lib"
MSYS_SYSROOT="/usr/aarch64-pc-msys"

mkdir -p "$LOGDIR"

#------------------------------- helpers --------------------------------------
c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_0="\033[0m"
log()  { echo -e "${c_b}[build]$(date +%H:%M:%S) $*${c_0}"; }
ok()   { echo -e "${c_g}[ ok ] $*${c_0}"; }
warn() { echo -e "${c_y}[warn] $*${c_0}"; }
die()  { echo -e "${c_r}[FAIL] $*${c_0}" >&2; echo -e "${c_r}       logs in: $LOGDIR${c_0}" >&2; exit 1; }

# On a runtime build failure the real reason (e.g. configure's "cannot run C
# compiled programs") lives in config.log, which is on the runner FS and not
# otherwise captured. Surface it to the job log.
#
# IMPORTANT: a plain `tail -45` is NOT enough. For the "cannot run C compiled
# programs" abort the decisive evidence -- the conftest command line, the
# linker output, and the EXEC error (exit status / "cannot execute" / loader
# message) -- sits in the "whether we are cross compiling" stanza roughly
# mid-file, while the file's tail is just autoconf's variable/confdefs dump.
# So we print BOTH: the cross-compiling stanza with generous context, AND the
# tail. This is what tells host-runtime/loader failures apart from a flag leak.
dump_cfglogs() {  # $1=dir to search
  local cl
  find "$1" -name config.log 2>/dev/null | while read -r cl; do
    if grep -qiE "cannot run|configure: error" "$cl"; then
      echo -e "${c_y}----- $cl : cross-compiling / conftest stanza -----${c_0}" >&2
      # The conftest that aborted: 40 lines of context around the probe so we
      # capture the exact compile+link command and the runtime error string.
      grep -niE -A40 "whether we are cross compiling" "$cl" >&2 \
        || echo "  (no 'cross compiling' stanza found)" >&2
      echo -e "${c_y}----- $cl : conftest error lines -----${c_0}" >&2
      grep -niE "cannot run|cannot execute|exec format|configure: error|conftest|exit code|Permission denied" "$cl" >&2 \
        || true
      echo -e "${c_y}----- $cl (last 45 lines) -----${c_0}" >&2
      tail -45 "$cl" >&2
    fi
  done
}

installed()  { pacman -Q "$1" &>/dev/null; }
have_built() { ls "$PKGS/$1/"*.pkg.tar.zst &>/dev/null; }   # any built package file present?

CUR=0
step() {
  CUR="$1"; local name="$2"
  (( STOP_AFTER > 0 && CUR > STOP_AFTER )) && { ok "STOP_AFTER=$STOP_AFTER reached -- stopping before step $CUR"; exit 0; }
  (( CUR < START_STEP )) && return 1
  echo; log "===== STEP $CUR : $name ====="
  return 0
}

run_make() {  # $1=pkgdir  $2..=makepkg args ; returns makepkg's real exit
  local dir="$1"; shift
  [[ -d "$PKGS/$dir" ]] || die "package dir not found: $PKGS/$dir"
  local attempt rc
  # Build with automatic retries. Three distinct flaky failure modes are handled:
  #   1. STALE lock from an interrupted prior run: makepkg reuses $startdir/src/,
  #      and a killed `git clone` ("Creating working copy") leaves a .git/index.lock
  #      that makes the next extract fatal. Cleared up-front (find -delete below).
  #   2. TRANSIENT mid-clone lock: while makepkg clones the huge gcc tree (~141k
  #      files) under slow x86 emulation, git intermittently fails with
  #      "Unable to create '.../.git/index.lock': File exists" *during* checkout.
  #      Mostly prevented by disabling gc.auto in preflight; the retry is a backstop.
  #   3. The retry's own fresh clone can re-race, so we WIPE src/ before EVERY
  #      attempt (not just after the first) and pause to let any lingering git
  #      background process exit and release the lock.
  for attempt in 1 2 3; do
    # Wipe any partial/locked working copy from a prior attempt, then clear stale
    # locks belonging to whatever src/ makepkg may legitimately reuse.
    if (( attempt > 1 )); then
      rm -rf "$PKGS/$dir/src" 2>/dev/null || true
      sleep 5
    fi
    find "$PKGS/$dir/src" -name '*.lock' -path '*/.git/*' -delete 2>/dev/null || true
    ( cd "$PKGS/$dir" && makepkg "$@" ) 2>&1 | tee "$LOGDIR/${dir}.log"
    rc="${PIPESTATUS[0]}"
    (( rc == 0 )) && return 0
    (( attempt < 3 )) && warn "$dir build failed (rc=$rc) -- wiping working copy and retrying ($attempt/3 done)"
  done
  return "$rc"
}

install_built() {  # pacman -U every built package file in a dir
  pacman -U --noconfirm "$PKGS/$1/"*.pkg.tar.zst
}

# --nocheck: never run a package's check() (e.g. binutils' gas/gdb testsuite —
# hundreds of check-gdb .exp cases, ~2h of emulated runtime — which we do not
# need to bootstrap a toolchain). -s installs makedepends.
mkflags() { if [[ "$FORCE" == "1" ]]; then echo "-sif --nocheck"; else echo "-si --nocheck"; fi; }

# 3-way: skip-if-installed / install-if-built / else-build. For "simple" packages.
ensure_pkg() {  # $1=pkgdir  $2=pkgname-to-check
  local dir="$1" check="$2"
  if [[ "$FORCE" == "0" ]] && installed "$check"; then ok "$check already installed -- skip"; return 0; fi
  if [[ "$FORCE" == "0" ]] && have_built "$dir"; then
    log "$dir already built -- installing prebuilt (no rebuild)"
    install_built "$dir" || die "install of prebuilt $dir failed"
    installed "$check" || die "$check not installed after pacman -U"
    ok "$check installed from prebuilt"; return 0
  fi
  run_make "$dir" $(mkflags) --noconfirm --skippgpcheck || die "$dir build failed (see $LOGDIR/${dir}.log)"
  installed "$check" || die "$dir built but $check not installed"
  ok "$dir built+installed"
}

#==============================================================================
# STEP 1 -- preflight
#==============================================================================
if step 1 "preflight"; then
  [[ "${MSYSTEM:-}" == "MSYS" ]] || die "Must run in the MSYS shell (MSYSTEM=MSYS), got '${MSYSTEM:-unset}'"

  log "installing build prerequisites via pacman..."
  pacman -S --needed --noconfirm git autotools gcc make \
      gmp-devel mpc-devel isl-devel zlib-devel libzstd-devel \
      mpfr-devel gettext-devel libiconv-devel gperf lndir \
      2>&1 | tee "$LOGDIR/00-pacman-deps.log" || die "pacman deps failed"

  # Disable git's background auto-maintenance for ALL repos this build clones.
  # makepkg creates a "working copy" of the 141k-file gcc tree via `git clone`;
  # under slow x86 emulation, git's post-clone `gc --auto` / maintenance fires
  # in the BACKGROUND and grabs .git/index.lock while the clone's own checkout
  # still holds it -> "Unable to create '.../index.lock': File exists" mid-
  # checkout (seen ~2s after "Cloning... done"). It re-races on every fresh
  # clone, so retries alone don't help -- kill the background process instead.
  # --global so the freshly-cloned repos inherit it (they have no local config).
  git config --global gc.auto 0                || true
  git config --global maintenance.auto false   || true
  git config --global fetch.writeCommitGraph false || true
  # The 141k-file gcc working-copy checkout fails DETERMINISTICALLY (every attempt,
  # at a variable early %) with "Unable to create .../index.lock: File exists" even
  # with gc.auto off. Cause is a SECOND git operation touching the index mid-checkout:
  # the fsmonitor daemon and untracked-cache machinery start on the fresh clone and
  # write the index while checkout holds index.lock. Disable them; fscache batches
  # Windows FS ops so the big checkout doesn't thrash. These are the real fix; the
  # run_make retry is now only a backstop.
  git config --global core.fsmonitor false     || true
  git config --global core.untrackedCache false || true
  git config --global core.fscache true        || true
  git config --global checkout.workers 1       || true   # serial checkout: no worker races
  ok "hardened git (gc.auto=0, fsmonitor/untrackedCache off, fscache on, serial checkout)"

  # auto-clone the repos if missing (so a fresh machine works turnkey)
  if [[ ! -d "$PKGS" ]]; then
    [[ "$NO_CLONE" == "1" ]] && die "MSYS2-packages missing at $PKGS and NO_CLONE=1"
    log "cloning MSYS2-packages ($PKGS_BRANCH)..."
    git clone "$PKGS_REPO" --branch "$PKGS_BRANCH" "$PKGS" || die "clone of MSYS2-packages failed"
  fi
  if [[ ! -d "$DRIVER" ]]; then
    [[ "$NO_CLONE" == "1" ]] && die "msys2-woarm64-build missing at $DRIVER and NO_CLONE=1"
    log "cloning msys2-woarm64-build ($DRIVER_BRANCH)..."
    git clone "$DRIVER_REPO" "$DRIVER" || die "clone of msys2-woarm64-build failed"
    ( cd "$DRIVER" && git checkout "$DRIVER_BRANCH" ) || warn "could not checkout $DRIVER_BRANCH (using default)"
  fi

  # cross PKGBUILDs hardcode $HOME/MSYS2-packages -> make it resolve to $PKGS
  HP="$HOME/MSYS2-packages"
  if [[ "$(readlink -f "$HP" 2>/dev/null)" == "$(readlink -f "$PKGS")" ]]; then
    ok "\$HOME/MSYS2-packages already resolves to $PKGS"
  elif [[ ! -e "$HP" ]]; then
    MSYS=winsymlinks:nativestrict ln -s "$PKGS" "$HP" || die "could not symlink $HP -> $PKGS"
    ok "created symlink $HP -> $PKGS"
  else
    warn "\$HOME/MSYS2-packages exists and does not point to $PKGS."
    warn "Back it up and symlink manually, then re-run:"
    warn "  mv '$HP' '$HP.bak' && MSYS=winsymlinks:nativestrict ln -s '$PKGS' '$HP'"
    die  "refusing to clobber an existing \$HOME/MSYS2-packages"
  fi
  ok "preflight done"
fi

#==============================================================================
# MINGW CROSS CHAIN (steps 2-9)
#==============================================================================
if step 2 "mingw: headers";                  then ensure_pkg mingw-w64-cross-mingwarm64-headers                  mingw-w64-cross-mingwarm64-headers; fi
if step 3 "mingw: binutils";                 then ensure_pkg mingw-w64-cross-mingwarm64-binutils                 mingw-w64-cross-mingwarm64-binutils; fi
if step 4 "mingw: gcc-stage1";               then ensure_pkg mingw-w64-cross-mingwarm64-gcc-stage1               mingw-w64-cross-mingwarm64-gcc-stage1; fi
if step 5 "mingw: windows-default-manifest"; then ensure_pkg mingw-w64-cross-mingwarm64-windows-default-manifest mingw-w64-cross-mingwarm64-windows-default-manifest; fi

# step 6: crt (pthread-header hack only needed when BUILDING)
if step 6 "mingw: crt (+pthread hack)"; then
  D=mingw-w64-cross-mingwarm64-crt
  if [[ "$FORCE" == "0" ]] && installed "$D"; then ok "crt already installed -- skip"
  elif [[ "$FORCE" == "0" ]] && have_built "$D"; then
    log "crt already built -- installing prebuilt"; install_built "$D" || die "crt install failed"; ok "crt installed from prebuilt"
  else
    BEFORE="$DRIVER/.github/scripts/pthread-headers-hack-before.sh"
    AFTER="$DRIVER/.github/scripts/pthread-headers-hack-after.sh"
    [[ -f "$BEFORE" ]] || die "missing $BEFORE"
    "$BEFORE" 2>&1 | tee "$LOGDIR/06-pthread-before.log" || die "pthread before-hack failed"
    [[ -f /opt/aarch64-w64-mingw32/include/pthread_compat.h ]] || die "pthread_compat.h not staged"
    run_make "$D" $(mkflags) --noconfirm --skippgpcheck || die "crt build failed"
    [[ -f "$AFTER" ]] && { "$AFTER" 2>&1 | tee "$LOGDIR/06-pthread-after.log" || warn "after-hack nonzero (ok)"; }
    installed "$D" || die "crt not installed"; ok "crt installed"
  fi
fi

# step 7: winpthreads (clean leftover staged headers first when building)
if step 7 "mingw: winpthreads"; then
  D=mingw-w64-cross-mingwarm64-winpthreads
  if [[ "$FORCE" == "0" ]] && installed "$D"; then ok "winpthreads already installed -- skip"
  elif [[ "$FORCE" == "0" ]] && have_built "$D"; then
    install_built "$D" || die "winpthreads install failed"; ok "winpthreads installed from prebuilt"
  else
    rm -f /opt/aarch64-w64-mingw32/include/pthread_{signal,unistd,time,compat}.h 2>/dev/null || true
    pacman -R --noconfirm mingw-w64-cross-mingw64-winpthreads 2>/dev/null || true
    run_make "$D" $(mkflags) --noconfirm --skippgpcheck || die "winpthreads build failed"
    installed "$D" || die "winpthreads not installed"; ok "winpthreads installed"
  fi
fi

# step 8: mingw gcc (libgcc_s.a fix; remove stage1 before install)
if step 8 "mingw: gcc (+libgcc_s.a fix)"; then
  D=mingw-w64-cross-mingwarm64-gcc
  # NB: mingw-w64-cross-mingwarm64-gcc-stage1 declares provides=(mingw-w64-cross-mingwarm64-gcc),
  # so a bare `installed mingw-w64-cross-mingwarm64-gcc` is TRUE while only stage1 is installed ->
  # step 8 would wrongly SKIP and the full mingw gcc never gets built. Then its *.pkg.tar.zst is
  # absent from the release, and the consumer (build-test-arm64) can't satisfy the stage-2 runtime
  # makedepend on it. The full gcc and stage1 are mutually exclusive (step removes stage1 before
  # install), so only treat it as present when stage1 is GONE. (Same fix as step 15 for the msys gcc.)
  if [[ "$FORCE" == "0" ]] && installed "$D" && ! installed mingw-w64-cross-mingwarm64-gcc-stage1; then ok "mingw gcc already installed -- skip"
  else
    if ! { [[ "$FORCE" == "0" ]] && have_built "$D"; }; then
      GF="$PKGS/$D/PKGBUILD"
      if grep -qE '^[[:space:]]*mv[[:space:]].*/lib/libgcc_s\.a[[:space:]]' "$GF"; then
        cp -n "$GF" "$GF.bak.autoscript"
        sed -i -E 's|^([[:space:]]*)(mv[[:space:]].*/lib/libgcc_s\.a[[:space:]].*)$|\1#\2|' "$GF"
        ok "patched libgcc_s.a mv in mingw gcc PKGBUILD"
      fi
      run_make "$D" -s --nocheck $([[ "$FORCE" == "1" ]] && echo -f) --noconfirm --skippgpcheck || die "mingw gcc build failed"
    else
      log "mingw gcc already built -- installing prebuilt"
    fi
    pacman -R --noconfirm mingw-w64-cross-mingwarm64-gcc-stage1 2>/dev/null || true
    install_built "$D" || die "mingw gcc install failed"
    installed "$D" || die "mingw gcc not installed"; ok "mingw gcc installed"
  fi
fi

if step 9 "mingw: zlib"; then ensure_pkg mingw-w64-cross-mingwarm64-zlib mingw-w64-cross-mingwarm64-zlib; fi

if (( START_STEP <= 9 )); then
  # At this point (before step 10) the Win32 import libs live in the mingw sysroot
  # /opt (built by the mingw crt in step 6). Step 10's cross-msysarm64-w32api-runtime
  # package then installs them into the cross sysroot /usr/aarch64-pc-msys/lib/.
  # Accept either location so the check is robust to a re-run that already packaged them.
  for L in kernel32 user32 advapi32 shell32 ntdll; do
    [[ -f "$MINGW_LIBDIR/lib$L.a" || -f "$MSYS_SYSROOT/lib/lib$L.a" ]] \
      || die "missing Win32 import lib lib$L.a (looked in $MINGW_LIBDIR and $MSYS_SYSROOT/lib)"
  done
  ok "Win32 import libs present"
fi

#==============================================================================
# MSYS CROSS CHAIN (steps 10-16)
#==============================================================================
if step 10 "msys: w32api-headers + w32api-runtime"; then
  ensure_pkg cross-msysarm64-w32api-headers cross-msysarm64-w32api-headers
  [[ "$(grep -c "__aarch64__" "$MSYS_SYSROOT/include/basetsd.h" 2>/dev/null || echo 0)" -gt 0 ]] \
      || warn "basetsd.h __aarch64__ patch not detected"
  # Win32 import libs (libkernel32/user32/advapi32/shell32/ntdll.a) now come from a
  # real package into the cross sysroot /usr/aarch64-pc-msys/lib/ -- no more copying
  # from /opt (issue #3). Depends on w32api-headers (just installed) + the mingw
  # cross chain (steps 2-9, installed). Only build/install if the package dir exists.
  if [[ -d "$PKGS/cross-msysarm64-w32api-runtime" ]]; then
    ensure_pkg cross-msysarm64-w32api-runtime cross-msysarm64-w32api-runtime
  else
    warn "no cross-msysarm64-w32api-runtime pkg dir -- Win32 libs will fall back to /opt copies in the runtime PKGBUILDs"
  fi
fi
if step 11 "msys: runtime-devel"; then
  ensure_pkg cross-msysarm64-runtime-devel cross-msysarm64-runtime-devel
  [[ "$(grep -c "__aarch64__" "$MSYS_SYSROOT/include/cygwin/signal.h" 2>/dev/null || echo 0)" -gt 0 ]] \
      || warn "cygwin/signal.h has no __aarch64__ (wrong source branch?)"
fi
if step 12 "msys: binutils";   then ensure_pkg cross-msysarm64-binutils   cross-msysarm64-binutils;   fi
if step 13 "msys: gcc-stage1"; then ensure_pkg cross-msysarm64-gcc-stage1 cross-msysarm64-gcc-stage1; fi

# step 14: runtime stage 1 (two-phase; package() commented out -> check artifact)
if step 14 "msys: runtime stage 1"; then
  RT="$PKGS/msys2-runtime-aarch64"
  if [[ "$FORCE" == "0" && -f "$RT/src/runtime-build/cygwin/libmsys-2.0.a" ]] && find "$RT" -name msys-2.0.dll | grep -q .; then
    ok "runtime stage1 already built (msys-2.0.dll present) -- skip"
  else
    [[ -f "$RT/build_msys.sh" ]] || die "missing $RT/build_msys.sh"
    ( cd "$RT" && bash build_msys.sh ) 2>&1 | tee "$LOGDIR/14-runtime-stage1.log" || true
    [[ -f "$RT/src/runtime-build/cygwin/libmsys-2.0.a" ]] || { dump_cfglogs "$RT"; die "runtime stage1: libmsys-2.0.a missing"; }
    find "$RT" -name msys-2.0.dll | grep -q . || { dump_cfglogs "$RT"; die "runtime stage1: msys-2.0.dll missing"; }
    ok "runtime stage1 built"
  fi
fi

# step 15: msys gcc stage 2 (build with stage1, then remove stage1, then install)
if step 15 "msys: gcc stage 2"; then
  D=cross-msysarm64-gcc
  # NB: cross-msysarm64-gcc-stage1 declares `provides=(cross-msysarm64-gcc)`, so a bare
  # `installed cross-msysarm64-gcc` is TRUE while only stage1 is installed -> step 15 would
  # wrongly SKIP and the real stage-2 gcc (the only one with libstdc++.a) never gets built,
  # leaving the runtime built by the bootstrap stage1 compiler. The real gcc and stage1 are
  # mutually exclusive (file-conflict on the gcc binaries), so only treat stage2 as present
  # when stage1 is GONE.
  if [[ "$FORCE" == "0" ]] && installed "$D" && ! installed cross-msysarm64-gcc-stage1; then ok "msys gcc stage2 already installed -- skip"
  else
    if ! { [[ "$FORCE" == "0" ]] && have_built "$D"; }; then
      for L in runtime-build/cygwin/libmsys-2.0.a newlib/libc.a newlib/libm.a newlib/libg.a; do
        [[ -f "$HOME/MSYS2-packages/msys2-runtime-aarch64/src/$L" ]] || die "stage2 prereq missing: $L"
      done
      run_make "$D" -s --nocheck $([[ "$FORCE" == "1" ]] && echo -f) --noconfirm --skippgpcheck \
        || die "gcc stage2 build failed -- if log shows undefined _Unwind_Resume/__gxx_personality_seh0, the SEH line-347 sed no-op'd."
    else
      log "msys gcc stage2 already built -- installing prebuilt"
    fi
    pacman -R --noconfirm cross-msysarm64-gcc-stage1 2>/dev/null || true
    install_built "$D" || die "gcc stage2 install failed"
    installed "$D" || die "gcc stage2 not installed"; ok "msys gcc stage2 installed"
  fi
fi

# step 16: runtime stage 2 (gcc-stage1->gcc makedepend fix; hyphenated build-msys.sh)
if step 16 "msys: runtime stage 2"; then
  RT2="$PKGS/msys2-runtime-aarch64-stage-2"
  if [[ ! -d "$RT2" ]]; then warn "no msys2-runtime-aarch64-stage-2 dir -- skipping"
  elif [[ "$FORCE" == "0" ]] && find "$RT2" -name msys-2.0.dll 2>/dev/null | grep -q .; then
    ok "runtime stage2 already built -- skip"
  else
    # stage1 was removed in step 15; swap the stale makedepend to the full gcc.
    for P in "$RT2/PKGBUILD" "$RT2/newlib-pkgbuild/PKGBUILD" "$RT2/newlib_pkgbuild/PKGBUILD"; do
      if [[ -f "$P" ]] && grep -q "cross-msysarm64-gcc-stage1" "$P"; then
        cp -n "$P" "$P.bak.autoscript"
        sed -i 's/cross-msysarm64-gcc-stage1/cross-msysarm64-gcc/g' "$P"
        ok "patched gcc-stage1 -> gcc in $(basename "$(dirname "$P")")/PKGBUILD"
      fi
    done
    if   [[ -f "$RT2/build-msys.sh" ]]; then ( cd "$RT2" && bash build-msys.sh ) 2>&1 | tee "$LOGDIR/16-runtime-stage2.log" || true
    elif [[ -f "$RT2/build_msys.sh" ]]; then ( cd "$RT2" && bash build_msys.sh ) 2>&1 | tee "$LOGDIR/16-runtime-stage2.log" || true
    else ( cd "$RT2" && makepkg -s --noconfirm --skippgpcheck ) 2>&1 | tee "$LOGDIR/16-runtime-stage2.log" || true
    fi
    find "$RT2" -name msys-2.0.dll | grep -q . || { dump_cfglogs "$RT2"; die "runtime stage2: msys-2.0.dll missing (see config.log dump above)"; }
    ok "runtime stage2 built"
  fi
  # build-msys.sh stubs the compiler's bits/c++config.h (needed only to compile winsup). Restore
  # the REAL target-specific c++config.h so the toolchain can compile normal C++ (<iostream> etc.).
  # Resolve the gcc private dir from the compiler -- do NOT hardcode "15"; the installed dir is
  # versioned (e.g. 15.0.1) and a wrong path silently no-ops the restore.
  GCC_PRIV="$(dirname "$(aarch64-pc-msys-gcc -print-libgcc-file-name 2>/dev/null)" 2>/dev/null)"
  [[ -z "$GCC_PRIV" || ! -d "$GCC_PRIV" ]] && GCC_PRIV="/usr/lib/gcc/aarch64-pc-msys/15"   # fallback
  REAL_CFG="${GCC_PRIV}/include/c++/aarch64-pc-msys/bits/c++config.h"
  STUB_CFG="${GCC_PRIV}/include/c++/bits/c++config.h"
  if [[ ! -f "$REAL_CFG" ]]; then
    REAL_CFG="$PKGS/cross-msysarm64-gcc/pkg/cross-msysarm64-gcc${GCC_PRIV}/include/c++/aarch64-pc-msys/bits/c++config.h"
  fi
  if [[ -f "$REAL_CFG" ]] && grep -q "_GLIBCXX_USE_BUILTIN_TRAIT" "$REAL_CFG"; then
    [[ -f "$STUB_CFG" ]] && cp -n "$STUB_CFG" "$STUB_CFG.stub.bak"
    cp "$REAL_CFG" "$STUB_CFG"
    ok "restored real bits/c++config.h (Step 7 had stubbed it)"
  else
    warn "could not find real c++config.h to restore; normal C++ compiles may fail until you do"
  fi

  # Install the REAL runtime package that build-msys.sh just produced. The stage-2
  # cross-msysarm64-runtime package() is now enabled and STRICT (issue #3): it ships
  # the real crt0.o (`bl msys_crt0`) + gcrt0.o + libmsys-2.0.a + libcygwin.a + newlib
  # libc/libm + msys-2.0.dll ALL under /usr/aarch64-pc-msys/ -- it is self-sufficient
  # for the sysroot, and REFUSES (exit 1) to package a bootstrap-stub crt0.o
  # (mainCRTStartup == `nop;ret`) that would make every exe hang at startup. Installing
  # the package -- instead of hand-copying crt0.o out of src/ -- is what retires
  # apply-crt0-fix.sh and puts the sysroot on the package-managed path.
  #
  # SAFETY GUARD (learned the hard way): only ever install a package whose name is
  # cross-msysarm64-* AND whose files live entirely under /usr/aarch64-pc-msys/. A
  # STALE stage-2 newlib-pkgbuild can emit HOST-named msys2-runtime/-devel packages;
  # `pacman -U`-ing those DOWNGRADES the host x86_64 MSYS2 runtime and bricks the shell
  # (0xC0000135). We install ONLY the collision-safe cross-msysarm64-runtime package and
  # refuse anything else. --overwrite is scoped to the cross sysroot (never the host).
  install_cross_sysroot_pkg() {  # $1 = .pkg.tar.zst ; dies unless provably host-safe
    local pkg="$1" name bad
    name="$(pacman -Qp "$pkg" 2>/dev/null | awk '{print $1}')"
    case "$name" in
      cross-msysarm64-*) : ;;
      *) die "REFUSING to install '$pkg': pkgname '$name' is not cross-msysarm64-* -- host-clobber risk (stale newlib-pkgbuild emitting host names?)";;
    esac
    bad="$(pacman -Qpl "$pkg" | awk '{print $2}' | grep -v '^/usr/aarch64-pc-msys/' | grep -v '/$' || true)"
    [[ -n "$bad" ]] && die "REFUSING to install '$pkg': it contains files OUTSIDE /usr/aarch64-pc-msys/ (host-clobber risk): $bad"
    pacman -U --noconfirm --overwrite '/usr/aarch64-pc-msys/*' "$pkg" \
      || die "pacman -U of $name failed (strict package() may have rejected a stub crt0.o -- see step-16 log)"
    ok "installed $name (host-safe: cross sysroot only)"
  }

  RT_PKG="$(ls "$RT2"/cross-msysarm64-runtime-*.pkg.tar.zst 2>/dev/null | head -1)"
  [[ -n "$RT_PKG" ]] || die "no cross-msysarm64-runtime package built in $RT2 -- cannot install the real crt0.o (build-msys.sh should have produced it now that package() is enabled)"
  install_cross_sysroot_pkg "$RT_PKG"
  installed cross-msysarm64-runtime || die "cross-msysarm64-runtime not installed after pacman -U"
  # Postcondition (what apply-crt0-fix.sh used to verify by hand): the installed
  # crt0.o must be the REAL one -- it references msys_crt0. A stub has no such ref.
  if aarch64-pc-msys-nm /usr/aarch64-pc-msys/lib/crt0.o 2>/dev/null | grep -q "U msys_crt0"; then
    ok "installed crt0.o is the REAL crt0 (U msys_crt0) -- apply-crt0-fix.sh no longer needed"
  else
    die "installed /usr/aarch64-pc-msys/lib/crt0.o still looks like the STUB (no 'U msys_crt0') -- packaging regression"
  fi
fi

#==============================================================================
# STEP 17 -- verify
#==============================================================================
if step 17 "verify (hello-world -> PE32+ ARM64)"; then
  TMP="$(mktemp -d)"; H="$TMP/hello.cc"
  printf '#include <cstdio>\nint main(){ std::printf("hello from aarch64-pc-msys\\n"); return 0; }\n' > "$H"
  command -v aarch64-pc-msys-g++ >/dev/null || die "aarch64-pc-msys-g++ not on PATH"
  aarch64-pc-msys-g++ "$H" -o "$TMP/hello.exe" 2>&1 | tee "$LOGDIR/17-verify.log" || die "g++ failed"
  FT="$(file "$TMP/hello.exe")"; echo "$FT"
  echo "$FT" | grep -qiE 'ARM64|Aarch64' || die "produced binary is NOT ARM64: $FT"
  ok "VERIFY PASSED -- aarch64-pc-msys-g++ produces ARM64 PE executables"

  # Runtime smoke test: the binary must actually RUN and EXIT (catches the
  # bootstrap-stub crt0.o regression -- a stub makes the exe hang at startup,
  # so a clean `file` check alone is NOT enough). Only meaningful on an ARM64
  # host; skip the run elsewhere. Use a hard timeout so a hang can't wedge the
  # whole build script.
  HOST_ARCH="$(uname -m 2>/dev/null)"
  if echo "$HOST_ARCH" | grep -qiE 'aarch64|arm64'; then
    RT2="$PKGS/msys2-runtime-aarch64-stage-2"
    # Run beside the ARM64 msys-2.0.dll. Prefer the PACKAGE-INSTALLED copy (step 16
    # pacman -U'd it to /usr/aarch64-pc-msys/bin) so we validate the SHIPPED artifact.
    # Fall back to the build tree, where a clean winsup build leaves new-msys-2.0.dll
    # (the installed msys-2.0.dll name only exists after `make install`, which the
    # package build does not run) -- so accept new-msys-2.0.dll too.
    DLL="/usr/aarch64-pc-msys/bin/msys-2.0.dll"
    if [[ ! -f "$DLL" ]]; then
      DLL="$(find "$RT2" -name msys-2.0.dll -o -name new-msys-2.0.dll 2>/dev/null | head -1)"
    fi
    [[ -n "$DLL" && -f "$DLL" ]] || die "no ARM64 msys-2.0.dll found (installed or in $RT2) -- step 16 packaging likely failed"
    DLLDIR="$(dirname "$DLL")"
    # Run in a temp dir with the DLL named msys-2.0.dll beside the exe (the loader
    # needs that exact name; the build-tree copy may be new-msys-2.0.dll).
    RUNDIR="$(mktemp -d)"; cp -f "$TMP/hello.exe" "$RUNDIR/"; cp -f "$DLL" "$RUNDIR/msys-2.0.dll"
    if ( cd "$RUNDIR" && timeout 20 ./hello.exe ) | grep -q "hello from aarch64-pc-msys"; then
      ok "RUNTIME SMOKE TEST PASSED -- hello.exe ran and exited (packaged crt0.o + msys-2.0.dll from $DLLDIR)"
    else
      die "hello.exe did not run/exit -- likely the bootstrap STUB crt0.o is still in /usr/aarch64-pc-msys/lib (see crt0 staging in step 16)"
    fi
  else
    warn "host is $HOST_ARCH (not ARM64) -- skipping the run; cross-built exe verified by 'file' only"
  fi
fi


echo
ok "All requested steps completed. Logs: $LOGDIR"
