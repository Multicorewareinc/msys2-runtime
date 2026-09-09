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

Provision one secret in this repo's settings (Settings → Secrets and variables →
Actions):

1. **`CI_TOKEN` secret** — a `mayankag-qti` PAT with **read** access to
   `mayankag-qti/MSYS2-packages-arm64` (branch `ci/cross-runtime-packaging`),
   which the toolchain build clones for the PKGBUILDs. The per-job `github.token`
   only covers *this* repo, so a cross-repo read needs `CI_TOKEN`; the same
   fine-grained PAT you use to push here (scoped to both repos) works. The
   toolchain release download uses the job token (same repo), so `CI_TOKEN` is
   only needed for the packages clone.

2. **Runner** — jobs target `windows-11-arm` (GitHub-hosted ARM64). Confirm the
   hosted ARM64 runner is available/enabled for this repo, or override via the
   `arm64_runner` workflow_dispatch input with a self-hosted label.

Notes:
- `toolchain.yml` and `cygwin.yml` use the public **`msys2/setup-msys2@v2`**
  action (the old `qcom-eng-691` fork existed only for an internal enterprise
  policy that does not apply here). `build.yaml` (the x86_64 path) still
  references the `qcom-eng-691` forks and can be repointed the same way when needed.
- The old `msys2-woarm64-build` driver is no longer cloned — the only pieces the
  build used from it (the pthread-header hack scripts) are vendored under
  `.github/arm64/scripts/`.

Once these are in place: Actions → **Toolchain (ARM64)** → Run workflow (publishes
the release), after which `cygwin.yml`'s `windows-build-arm64` consumes it per push/PR.
