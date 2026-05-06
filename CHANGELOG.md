# Changelog

Notable user-visible changes to the gentoo-binhost CI, configuration, and
packaging surface. Internal refactors and per-package masks are not listed
unless they affect downstream consumers.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Reliability

- **`scripts/build.sh` — two-phase stale-package restore; no unconditional source rebuild.** `rebuild_stale_from_source` previously forced `--usepkg=n --getbinpkg=n` for every package removed by verify-vdb. On a fresh chain with 598 stale entries this scheduled 598 from-source builds (glibc alone took 38 min); the deadline fired with zero new packages published, the zero-progress gate killed the chain, and auto-resume was disabled. Root cause: most stale entries are absent simply because stage3 does not include previously-built CI packages — their binpkgs are valid. Now: **Phase 1** installs from binpkg (`--usepkg --getbinpkg`, fast — local cache first, then remote binhost, falls back to source only if neither has the package); **Phase 2** re-runs verify-vdb and forces `--usepkg=n` only for packages that are still stale after the binpkg install (binpkg itself is corrupt). The corrupt-binpkg detection is preserved for the ruby case (observed run 25347952798) while avoiding catastrophic source-rebuild storms.
- **Workflow + `verify-vdb.sh` — share the removed-atoms list across both invocations.** The "Repair stale VDB entries" workflow step ran verify-vdb without `--removed-atoms-file`, so its removals were never recorded. By the time `build.sh` ran verify-vdb a second time (the only one passing the flag), the stale entries were already gone — empty list, empty `rebuild_stale_from_source`, and the main emerge re-pulled the corrupt binpkg from the binhost regardless. PR #20's intent (rebuild from source after a stale-VDB removal) didn't fire. Observed in run 25360091149: `dev-lang/ruby-3.3.11`'s `rubygems/compatibility.rb` still missing after PR #20 merged. Fix: workflow step now passes `--removed-atoms-file` to a path build.sh also reads; verify-vdb.sh APPENDs (no longer truncates on entry); `rebuild_stale_from_source` dedupes via `sort -u` and truncates after consuming.
- **`scripts/build.sh` — rebuild stale VDB entries from source, not from binpkg.** When `verify-vdb` removes a package because its files are missing on disk (system-state cache restored, but `/usr/*` came from fresh stage3 without those files), the next emerge would re-install from the published binhost binpkg. But the binhost is fed by these CI runs — if a previous run published a binpkg generated from a partially-broken installation, the binpkg itself is incomplete, and reinstalling perpetuates the same missing files. Observed in run 25347952798: `dev-lang/ruby-3.3.11`'s published binpkg lacked `rubygems/compatibility.rb`, every emerge that touched ruby crashed in configure phase the same way after each "reinstall". `verify-vdb.sh` now writes its removed atoms to a file; `build.sh` reads that file and rebuilds those atoms with `--usepkg=n --getbinpkg=n`, generating a fresh complete binpkg locally that replaces the corrupt one in the binhost on the next publish. Self-heals across chains.
- **`scripts/verify-vdb.sh` — exhaustive CONTENTS scan.** The previous "5 spread samples" probe was probabilistic and missed real breakage: in run 25343885245, `dev-lang/ruby-3.3.11-1` had thousands of `obj` entries with one missing file (`/usr/lib64/ruby/3.3.0/rubygems/compatibility.rb`). None of the 5 samples landed on it, the VDB entry was kept, and the next emerge that invoked ruby (`dev-ruby/json-2.19.4`) died with `cannot load such file` in the configure phase. Now we walk every `obj` entry and short-circuit on the first missing file — deterministic, and cheap because healthy packages still complete in milliseconds.
- **`scripts/build.sh` — fix `rebuild_broken_libs` revdep-rebuild call.** The previous `--no-progress --ignore-temp-files` flags don't exist on the python rewrite of `revdep-rebuild`; the call exited with rc=2 and the ELF scan was a no-op. Removed the `revdep-rebuild` block entirely; the exhaustive `verify-vdb.sh` plus the unchanged `emerge @preserved-rebuild` cover the same failure classes (mesa_clc-style SONAME-skew and ruby-style missing-files-vs-VDB) without depending on revdep-rebuild's flag idiosyncrasies.
- **`config/profiles/.../package.mask/00-binhost` — drop `=dev-build/cmake-4.3.1` mask.** Comment said "fails to build in two consecutive CI attempts (phase unknown)", which is exactly the SIGTERM-victim misclassification pattern fixed in PR #18 (F2). The mask was a bandaid for a CI bug that no longer exists.
- **`config/profiles/.../package.use/00-profile-defaults` — drop `media-video/pipewire -extra` and `media-sound/audacity -vamp -twolame`.** Both were added with "repeatedly failed in CI" / "reduce compile breakage surface" comments — the same SIGTERM-victim signature fixed in PR #18. The legitimate `-ffmpeg` cycle-break on pipewire (tracked in `config/workarounds.json`) is preserved; only the bandaid disables are removed. Restores the user's "max USE flags" preference for both packages.
- **`scripts/build.sh` — don't classify SIGTERM victims as failures.** When `--max-build-time` fires mid-package, Portage's signal handler writes `.die_hooks` for the in-flight ebuild, which `report_failed_atoms` then recorded as a real failure. Two consecutive resume attempts each unlucky-enough to catch a different package this way could falsely trip the "repeated failures" gate and abort a chain that had nothing actually wrong with it. The deadline wrapper now records the SIGTERM timestamp; markers with mtime in the timeout window are skipped.
- **`scripts/build.sh` — phase-extractor fallback.** When `temp/environment` doesn't yield `EBUILD_PHASE` (typical for interrupted ebuilds), parse `temp/build.log` for the canonical Portage line `failed (compile phase)`. Replaces the previous always-`unknown` fallback that obscured every interrupted-build report.
- **`scripts/build.sh` — resume-chain fix.** Sourcing `/etc/profile` after `etc-update` runs under `set -u`, so an unset variable in any `/etc/profile.d/*.sh` (observed: `DEBUGINFOD_URLS` in `debuginfod.sh`) aborted `build.sh` mid-cleanup and swallowed `return 42` from a timed-out emerge, turning it into exit 1 and disabling auto-resume. Now wrap the source in `set +u`/`set -u`.

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
