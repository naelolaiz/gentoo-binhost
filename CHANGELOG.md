# Changelog

Notable user-visible changes to the gentoo-binhost CI, configuration, and
packaging surface. Internal refactors and per-package masks are not listed
unless they affect downstream consumers.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### CI (tier 4)

- **`scripts/sync-stage3-tag.sh`** — one command to bump the pinned stage3 tag across every workflow (`--write <tag>`) and to verify no drift (`--check`). Replaces the "please edit three places by hand" ritual.
- **`lint.yml` `stage3-tag-drift` job** — runs on every PR touching workflows or scripts; catches partial stage3 tag edits before they reach main.
- **`build-packages.yml` tag-consistency step** — now calls `sync-stage3-tag.sh --check` instead of hand-rolled grep.
- **`check-stage3.yml`** — auto-filed update issue body now recommends the exact `sync-stage3-tag.sh --write <new-tag>` invocation.

### Documentation

- Added `docs/ARCHITECTURE.md` (CI internals: stage3 pinning, resume chain, coupled-cache invariant, VDB repair, workarounds subsystem).
- Added `docs/TROUBLESHOOTING.md` (mapping every `::error title=…` annotation to its cause and fix).
- Updated the README's repository structure section to list every current workflow and script.

## 2026-04 — CI quality pass (tier 1+2)

See [PR #11](https://github.com/naelolaiz/gentoo-binhost/pull/11).

### Reliability

- **Stage3 tag consistency check.** The build workflow now fails RED if `STAGE3_TAG` drifts from any `container.image` tag in the workflows. Previously the sync between three locations was maintained by comment.
- **`validate-config-changes.yml` pinned to the same stage3 tag as production.** PR validation now tests against the exact image downstream will use, instead of `:latest`.
- **Strict path regex in `accept-local-packages.yml`.** The previous depth-only check silently accepted too-deep submission paths.
- **`continue` job hardened.** 5-minute timeout (was inheriting the 360-minute default), replaced hand-rolled `curl + jq` with `gh workflow run`.

### New CI

- **`lint.yml`** — actionlint + shellcheck + `py_compile` on every PR touching workflows or scripts.

### Simplification

- Extracted shared logic from `build-packages.yml` and `build.sh` into dedicated scripts: `scripts/merge-pending-configs.sh`, `scripts/setup-binpkg-trust.sh`, `scripts/install-build-tools.sh`, `scripts/wipe-caches.py`. Net: `build-packages.yml` shrank ~155 lines, `build.sh` ~50. The extracted scripts are now shellcheck/pylint-verifiable and locally testable.
- Gentoo profile path (`default/linux/amd64/23.0/desktop/plasma`) is now a single workflow env var (`GENTOO_PROFILE`) instead of hardcoded in two places.
- `build.sh` gains `--gentoo-profile` as a required flag.
- Dropped the keyserver fallback in `build.sh`'s binpkg-trust setup. The CI path (getuto-based) is now the only supported path — it is strictly safer.

## 2026-04 — Earlier CI quality pass (#7)

- Data-driven workaround subsystem: `config/workarounds.json` + `scripts/check-workaround.sh` + weekly `check-workarounds.yml`.
- `BINHOST_PATH` consolidated as a single job-level env var in `publish-to-pages.yml`.
- Repository URLs in `index.html` switched to `${{ github.server_url }}/${{ github.repository }}` (no more hardcoded owner name).
- Added `--max-time 30` to every curl call in `check-stage3.yml`.
- Removed dead `publish-on-merge` placeholder and unused `helpers` step output.
- Normalized `actions/checkout` to `@v6` across all workflows.

## 2026-04 — Stage3 pinning (#6)

- Stage3 container is now pinned to a dated tag (was `:latest`). The tag is baked into every cache key; upgrading invalidates caches and forces a clean rebuild.
- New `check-stage3.yml` files an issue weekly when a newer stage3 tag is available (unless a build chain is active).
- Generalized the GLIBC ABI check in `verify-vdb.sh` to catch any library whose max `GLIBC_x.y` symbol version exceeds the running stage3's.

## 2026-04 — PipeWire restoration (#5)

- Restored latest PipeWire + zita-resampler tools while tightening the CI surface to reduce failure blast radius.

## Earlier

See git history for detail. Notable prior changes:

- Multi-phase resumable builds for tier-1 monster packages (qtwebengine, chromium, llvm) — **PR #28**
- Configure `PORTAGE_BINHOST` so CI reuses its own published binpkgs and the official Gentoo x86-64-v3 binhost — **PR #31**
- `libclc-22` slot conflict fix — **PR #23**
