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
tag appears in three places, kept in lockstep by `scripts/sync-stage3-tag.sh`:

1. `STAGE3_TAG` env var in `build-packages.yml` (the canonical source of truth) — part of every cache key.
2. `container.image` in `build-packages.yml` — the actual runtime.
3. `container.image` in `validate-config-changes.yml` — PR validation uses the same image as production.

### Bumping the tag

Never edit the three locations by hand. Use the sync tool:

```bash
bash scripts/sync-stage3-tag.sh --write amd64-openrc-20260520
```

It rewrites every reference atomically and runs `--check` afterwards to
verify. Two CI gates enforce no-drift:

- **`lint.yml` `stage3-tag-drift` job** — runs on every PR touching workflows or scripts. Catches partial edits before they reach main.
- **`build-packages.yml` `Verify stage3 tag consistency` step** — runs at the top of every build. Refuses to build if any tag disagrees with `STAGE3_TAG`.

`check-stage3.yml`'s auto-filed update issue recommends the exact
`sync-stage3-tag.sh --write <tag>` invocation.

### Why pinning matters

- The tag is baked into every cache key (`ccache-<TAG>-...`, `binpkgs-<TAG>-...`). Updating it invalidates every build cache. That's the desired behavior: a new stage3 means the build should start from a clean installed system.
- `check-stage3.yml` queries the Docker Registry weekly and files a "stage3 update available" issue when newer tags exist, *unless* a build chain is active.
- `check-workarounds.yml` deliberately uses `gentoo/stage3:latest` (not pinned) because it checks "is the workaround still needed against the *current* Gentoo tree?". Lines containing `gentoo/stage3:latest` are intentionally excluded by the sync tool's scanner.

## 2. The continuation chain

A full rebuild doesn't fit in GitHub Actions' 6-hour job limit. The build
workflow handles this by running for 5.5 hours, saving completed binary
packages plus ccache, then re-dispatching itself to continue from a clean
stage3 container. The main package emerge uses `--buildpkgonly`: target
packages are built for the binhost, while dependencies are still merged only
when the build graph actually needs them.

### Exit codes

| Exit | Meaning |
|------|---------|
| 0    | Build finished successfully |
| 42   | Timed out gracefully; continuation expected |
| other| Package/config failure; no continuation |

The `42` is picked by `scripts/build.sh`. When `--max-build-time` is hit:

1. The shell script sends `SIGTERM` to the emerge process group, waits up to 60s for graceful shutdown, then sends `SIGKILL` if needed.
2. Finished `.gpkg.tar` files are copied into the artifact/output directory.
3. ccache stats and build progress are emitted.
4. The script exits 42.

The `continue` job in `build-packages.yml` only re-dispatches when
`should_continue == 'true'`, which requires all of:

- exit 42
- no real package failure was detected
- next attempt <= `_max_attempts` (default 8)

### Chain identification

`chain_id` is the `github.run_id` of the first attempt in the chain. Every
continuation run inherits the same `chain_id` via `workflow_dispatch` input,
so ccache and binpkg caches from the same conceptual build share a key prefix.

Inputs with a leading underscore (`_attempt`, `_chain_id`, `_max_attempts`)
are conventionally "internal" — set by the `continue` job's
`gh workflow run` call, not by humans.

## 3. The cache system

Two cache families are used:

| Cache key prefix | Path | Purpose |
|------------------|------|---------|
| `ccache-…`       | `/var/cache/ccache` | compiler cache |
| `binpkgs-…`      | `/var/cache/binpkgs` | packages completed by earlier attempts in the same chain |

`ccache-*` can fall back across chains because object-cache misses are safe.
`binpkgs-*` is chain-scoped only: a fresh chain must not inherit old self-built
packages from GitHub Pages or a previous run. That keeps this CI from feeding a
stale or corrupt publication back into the next build.

The workflow deliberately does **not** cache `/var/db/pkg`, `/var/cache/edb`,
`/var/lib/portage`, `/etc`, or `/var/tmp/portage`. Portage can reason about ABI
compatibility when it owns the installed system. Restoring metadata without the
matching installed filesystem creates states Portage cannot validate reliably.

### The `fresh: true` escape hatch

Dispatch `Build Packages` with `fresh: true` to delete both active cache
families, plus legacy `system-state-*` and `build-state-*` prefixes left by
older workflow versions, before any restore step runs. Triple-guarded so it
cannot misfire:

1. Must be `workflow_dispatch` (never on schedule).
2. Must have `fresh: true` (explicit opt-in).
3. Must be attempt 1 (the `continue` job does not forward `fresh`).

The implementation lives in `scripts/wipe-caches.py`.

## 4. Build inputs

The build consumes the official Gentoo binhost only:

```text
https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64-v3/
```

The repository's own GitHub Pages binhost is output, not input. This avoids a
self-poisoning loop where one bad published package can keep breaking all
future builds.

The build does not pass `--ignore-built-slot-operator-deps`. Portage must keep
the ability to reject or rebuild a binary package whose recorded subslot
dependencies no longer match the current root, such as a `libgit2` binary built
against an older `llhttp` SONAME.

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

When an ebuild dies, the CI needs the package log copied out before the
container disappears. Without explicit failure capture, a broken ebuild can
leave only a short Portage summary in the workflow log.

Portage writes `/var/tmp/portage/<cat>/<pkg>/.die_hooks` unconditionally when
any non-`depend` phase dies. `build.sh` scans for these markers, copies each
failure's `build.log` and saved `environment` into `_failures/` inside the
build artifact, and emits a GitHub `::error` annotation per atom.

Timeout victims are filtered by marker mtime: if Portage writes `.die_hooks`
while the wrapper is terminating emerge for the time budget, that package is
not counted as a real failure.

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
| `build.sh`                   | workflow | main build runner (profile apply, ccache, sync, trust, news, kernel symlink, build, progress, failure report) |
| `apply-profile.sh`           | build.sh, validate-config-changes | copies `config/profiles/<name>/*` into `/etc/portage/*` |
| `sync-portage.sh`            | build.sh, workflows | `emerge-webrsync` → `emerge --sync` → `emaint sync` fallback chain |
| `sync-stage3-tag.sh`         | maintainer, build + lint workflows | `--write <tag>` rewrites every stage3 tag reference; `--check` verifies no drift |
| `setup-binpkg-trust.sh`      | workflow, build.sh | getuto-based Portage keyring bootstrap |
| `install-build-tools.sh`     | workflow | emerges ccache from the official Gentoo binhost, rebuilding if unusable |
| `merge-pending-configs.sh`   | build.sh, install-build-tools | `etc-update --automode -5` for `._cfg*` files |
| `wipe-caches.py`             | workflow | deletes every cache with a given prefix (fresh-start support) |
| `generate-packages-index.sh` | publish | writes the `Packages` index |
| `prune-old-binpkgs.py`       | publish, build.sh | keeps only the newest version per `(cat, pn)` |
| `check-workaround.sh`        | check-workarounds | executes a single workaround check (iuse/dep-grep/required-use-grep/version-gt) |
| `upload-local-packages.sh`   | contributors | helper to submit locally-built gpkgs via PR |

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for interpreting specific
workflow errors.
