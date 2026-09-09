# ARM64 CI in this repo

This repo drives both halves of the ARM64 pipeline:

- **`.github/workflows/toolchain.yml`** — bootstraps the `aarch64-pc-msys` cross
  toolchain (3 chained jobs: `arm64-mingw` → `arm64-msys` → `arm64-runtime`,
  ~7–8h emulated) and publishes it as the `toolchain-arm64-latest` release **on
  this repo**. Manual / nightly dispatch only.
- **`.github/workflows/cygwin.yml`** (`windows-build-arm64` job) — downloads that
  release **from this same repo**, builds the runtime from the commit under test,
  and runs the winsup testsuite.
- **`build-msys2-woarm64-all.sh`, `apply-crt0-fix.sh`** — build drivers invoked by
  `toolchain.yml`.

## Before the toolchain build can go green

These external dependencies are intentionally left pointing at their current
sources; provision them in this repo's settings first:

1. **`CI_TOKEN` secret** — a PAT with read access to the PKGBUILD source the
   toolchain build clones:
   - `qcom-eng-691/MSYS2-packages` (PKGBUILDs, branch `ci/cross-runtime-packaging`)
   Without it the private clone fails. The release download itself uses the job
   token (same repo), so `CI_TOKEN` is only needed for that clone. The old
   `msys2-woarm64-build` driver is no longer cloned — the only pieces the build
   used from it (the pthread-header hack scripts) are vendored under
   `.github/arm64/scripts/`.
2. **`qcom-eng-691/setup-msys2`** action — the org fork used by every job. Ensure
   this repo can resolve it (make it accessible, or vendor/replace the reference).
3. **Runner** — jobs target `windows-11-arm` (GitHub-hosted ARM64). Confirm the
   hosted ARM64 runner is available/enabled for this repo, or override via the
   `arm64_runner` workflow_dispatch input with a self-hosted label.

Once these are in place: Actions → **Toolchain (ARM64)** → Run workflow (publishes
the release), after which `cygwin.yml`'s `windows-build-arm64` consumes it per push/PR.
