# Architecture

This document describes how the CI builds the binhost and why certain non-obvious
pieces exist. It is maintenance documentation for contributors and for the
maintainer's future self — if you're just *using* the binhost, the
[README](../README.md) is what you want.

## Overview

```
                 weekly cron                manual dispatch
                      |                           |
                      v                           v
              ┌───────────────────┐
              │  build-packages   │   builds packages in a pinned
              │  (Gentoo stage3)  │   Gentoo stage3 container
              └─────────┬─────────┘
                        │ artifacts
                        v
              ┌───────────────────┐
              │ publish-to-pages  │   assembles the binhost tree,
              │  (ubuntu-latest)  │   generates Packages index,
              └─────────┬─────────┘   deploys to GitHub Pages
                        │
                        v (exit 42 if build timed out)
              ┌───────────────────┐
              │  continue (job)   │   re-dispatches build-packages
              └───────────────────┘   with incremented _attempt
```

Three independent monitoring workflows run on their own schedules:

- `check-stage3.yml` — files an issue when a newer `gentoo/stage3` image exists.
- `check-workarounds.yml` — runs each workaround's self-test (see *Workarounds subsystem*) against the current Portage tree and files issues for any that are now removable.
- `validate-config-changes.yml` — runs on every PR that touches `config/profiles/**`, verifies the dependency graph resolves against the pinned stage3.

## 1. The stage3 container

Every build runs inside a pinned `gentoo/stage3:amd64-openrc-<DATE>` image. The
tag appears in three places (enforced by the "Verify stage3 tag consistency"
step in `build-packages.yml`):

1. `STAGE3_TAG` env var — part of every cache key.
2. `container.image` in `build-packages.yml` — the actual runtime.
3. `container.image` in `validate-config-changes.yml` — PR validation uses the same image as production.

Pinning matters because:

- The tag is baked into every cache key (`ccache-<TAG>-…`, `binpkgs-<TAG>-…`, `system-state-<TAG>-…`, `build-state-<TAG>-…`). Updating it invalidates every cache. That's the desired behavior — a new glibc in stage3 means existing binpkgs may have the wrong ABI (see `scripts/verify-vdb.sh`).
- `check-stage3.yml` queries the Docker Registry weekly and files a "stage3 update available" issue when newer tags exist, *unless* a build chain is active (updating mid-chain would corrupt resume state).

## 2. The resume chain

A full rebuild doesn't fit in GitHub Actions' 6-hour job limit. The build
workflow handles this by running for 5.5 hours, saving state, then
re-dispatching itself to continue.

### Exit codes

| Exit | Meaning |
|------|---------|
| 0    | Build finished successfully |
| 42   | Timed out gracefully; state saved; resume expected |
| other| Hard failure; no resume |

The `42` is picked by `scripts/build.sh`. When `--max-build-time` is hit:

1. The shell script sends `SIGTERM` to the emerge process group, waits up to 60s for graceful shutdown, then sends `SIGKILL` if needed.
2. `mtimedb` (emerge's resume list) is copied to the state dir.
3. `/var/tmp/portage` (intermediate WORKDIRs) is copied to the state dir.
4. The script exits 42.

The `continue` job in `build-packages.yml` only re-dispatches when
`should_continue == 'true'`, which requires all of:

- exit 42
- at least one *new* `.gpkg.tar` was produced this attempt
- no package failed in *two consecutive* attempts (see *Failure detection*)
- next attempt ≤ `_max_attempts` (default 8)

### Chain identification

`chain_id` is the `github.run_id` of the first attempt in the chain. Every
resume run inherits the same `chain_id` via `workflow_dispatch` input, so all
caches from the same conceptual build share a key prefix and can be restored
as a group.

Inputs with a leading underscore (`_attempt`, `_chain_id`, `_max_attempts`)
are conventionally "internal" — set by the `continue` job's
`gh workflow run` call, not by humans.

## 3. The cache system

Four cache families, all scoped to `STAGE3_TAG` and `chain_id`:

| Cache key prefix | Path | Purpose |
|------------------|------|---------|
| `ccache-…`       | `/var/cache/ccache` | compiler cache |
| `binpkgs-…`      | `/var/cache/binpkgs` | already-built binpkgs |
| `system-state-…` | `/var/db/pkg`, `/var/lib/portage`, `/var/cache/edb`, `/etc/portage`, `/etc/env.d`, `/etc/ld.so.conf.d` | Portage's installed-package DB and on-disk config |
| `build-state-…`  | `/var/tmp/portage-state` | saved mtimedb + WORKDIRs for resume |

### The coupled-cache invariant

`binpkgs-*` and `system-state-*` **must move together**. If `system-state`
restores and `binpkgs` does not, Portage's VDB claims packages are installed
while their binaries are missing — leading to "skip then fail" later in the
build.

This happens in practice because GitHub's 10 GB-per-repo cache budget can evict
the 3.6 GB `binpkgs` cache while the 50 MB `system-state` cache survives.

The "Verify coupled-cache invariant" step uses GitHub's authoritative
`cache-matched-key` outputs to XOR-check both restores and fails **RED** if
exactly one succeeded. This runs on *every* attempt (including attempt 1)
because cross-chain eviction is the actual failure mode.

### The `fresh: true` escape hatch

Dispatch `Build Packages` with `fresh: true` to delete every cache in all four
families before any restore step runs. Triple-guarded so it cannot misfire:

1. Must be `workflow_dispatch` (never on schedule).
2. Must have `fresh: true` (explicit opt-in).
3. Must be attempt 1 (the `continue` job does not forward `fresh`).

The implementation lives in `scripts/wipe-caches.py`.

## 4. VDB repair (`scripts/verify-vdb.sh`)

Between the `system-state` cache (saved at the end of one attempt) and the
next attempt's container (fresh stage3 extract), the VDB can claim installed
packages that are no longer on disk.

`verify-vdb.sh` walks every `/var/db/pkg/<cat>/<pkg>/CONTENTS`, samples up
to 5 `obj` paths spread through the file, and deletes the VDB entry if any
probe is missing on disk. Portage then re-resolves and pulls or rebuilds.

A second pass checks every shared library for a **GLIBC ABI mismatch** —
a `.so` whose max `GLIBC_x.y` symbol version exceeds what the current stage3
ships. Without this, binpkgs built against an older glibc cause cryptic linker
errors in dependents.

The script runs in two places:

- In `build-packages.yml`, before "Install build tools", so ccache/gentoolkit see a correct view.
- From `build.sh`, before the main build emerge.

## 5. Binpkg trust (`scripts/setup-binpkg-trust.sh`)

Portage verifies GPG signatures on binpkgs downloaded from the Gentoo binhost.
The keyring lives at `/etc/portage/gnupg/` and must be owned by `portage:portage`.

The script calls `getuto` (Portage's `$PORTAGE_TRUST_HELPER`) which:

- imports the binhost signing key (`534E4209AB49EEE1C19D96162C44695DB9F6043D`),
- sets correct trust levels,
- chowns the keyring to portage:portage.

An earlier manual `gpg --import` + `chown` produced "unsafe ownership on
homedir" errors during binpkg verification (run 24651146807). `getuto`
side-steps this class of bug.

## 6. Failure detection (`report_failed_atoms` in build.sh)

`emerge --keep-going` exits 0 even when individual atoms fail, because
other packages still complete. Without explicit failure detection, a broken
ebuild silently blocks the chain while the workflow turns green.

Portage writes `/var/tmp/portage/<cat>/<pkg>/.die_hooks` unconditionally when
any non-`depend` phase dies. `build.sh` scans for these markers, copies each
failure's `build.log` and saved `environment` into `_failures/` inside the
build artifact, and emits a GitHub `::error` annotation per atom.

A second pass compares this attempt's failure list to the previous attempt's
list (persisted in `STATE_DIR`). Any atom failing in **two consecutive**
attempts kills the chain with `repeated_failures=true` — retrying won't help
and the user needs to look at the log.

## 7. Publish pipeline

`publish-to-pages.yml` runs after every build (including failed and timed-out
ones) because even a partial attempt produces real artifacts worth shipping.

### Steps

1. **Restore cached pages site** — the last published tree, for incremental publishes.
2. **Scrub corrupt layout** — removes any file not matching the canonical `<cat>/<pn>/<pn>-<ver>.gpkg.tar(.asc)?` structure. Defends against historical "Organise packages" bugs that left files at e.g. `tmp/artifacts/acct-group/cuse/cuse-0-1.gpkg.tar`.
3. **Download artifacts** — every `binpkgs-*` artifact from the current run.
4. **Organise packages** — copies artifacts into the canonical layout, with strict regex validation. Any malformed path fails the step rather than corrupting the binhost.
5. **Prune older versions** — keeps only the newest version per `(category, PN)`. GitHub Pages enforces a 1 GB soft limit; without pruning the site grows monotonically.
6. **Generate Packages index** — `scripts/generate-packages-index.sh` writes `Packages` with correct `CPV: <cat>/<pf>` format (single slash; the Portage client rejects anything else).
7. **Deploy to GitHub Pages.**

## 8. Workarounds subsystem

Workarounds (masked versions, forced USE flag overrides, version pins) are
declared data-first in `config/workarounds.json`. Each entry includes:

- `key` — stable identifier
- `title` / `body_lines` — issue title and body for when it becomes removable
- `check` — one of `iuse` / `dep-grep` / `required-use-grep` / `version-gt`, with the package and pattern to probe

`check-workarounds.yml` runs weekly against `gentoo/stage3:latest` (not the
pinned tag — we want to know whether upstream has fixed the problem),
invokes `scripts/check-workaround.sh` for each entry, and files a GitHub
issue for any workaround that can now be removed.

## 9. Scripts

| Script | Called from | Purpose |
|--------|-------------|---------|
| `build.sh`                   | workflow | main build runner (profile apply, ccache, sync, trust, VDB repair, news, kernel symlink, build, progress, failure report) |
| `apply-profile.sh`           | build.sh, validate-config-changes | copies `config/profiles/<name>/*` into `/etc/portage/*` |
| `sync-portage.sh`            | build.sh, workflows | `emerge-webrsync` → `emerge --sync` → `emaint sync` fallback chain |
| `setup-binpkg-trust.sh`      | workflow, build.sh | getuto-based Portage keyring bootstrap |
| `verify-vdb.sh`              | workflow, build.sh | deletes stale VDB entries (missing files or glibc ABI mismatch) |
| `install-build-tools.sh`     | workflow | emerges ccache + gentoolkit with own-binhost-index validation and stale-gpkg ABI recovery |
| `merge-pending-configs.sh`   | build.sh, install-build-tools | `etc-update --automode -5` for `._cfg*` files |
| `wipe-caches.py`             | workflow | deletes every cache with a given prefix (fresh-start support) |
| `generate-packages-index.sh` | publish | writes the `Packages` index |
| `prune-old-binpkgs.py`       | publish, build.sh | keeps only the newest version per `(cat, pn)` |
| `check-packages-index.py`    | install-build-tools | validates a `Packages` index has no malformed CPV entries |
| `check-workaround.sh`        | check-workarounds | executes a single workaround check (iuse/dep-grep/required-use-grep/version-gt) |
| `upload-local-packages.sh`   | contributors | helper to submit locally-built gpkgs via PR |

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for interpreting specific
workflow errors.
