# Troubleshooting

This page maps the explicit error annotations emitted by the CI to their
causes and remediations. If you see an `::error title=…` line in a failed
workflow run, find it below.

Cross-reference: [ARCHITECTURE.md](ARCHITECTURE.md) explains *why* each of
these checks exists.

---

## `Stage3 tag drift`

> stage3 tag drift (STAGE3_TAG|image): got <current>, expected <canonical>
> Run 'scripts/sync-stage3-tag.sh --write <tag>' to fix

**Cause.** Someone changed the stage3 tag in one place but not the others.
The tag appears in three locations:

1. `STAGE3_TAG` env var in `.github/workflows/build-packages.yml` — the canonical source of truth.
2. `container.image` (`gentoo/stage3:<TAG>`) in the same file.
3. `container.image` in `.github/workflows/validate-config-changes.yml`.

**Fix.** From the repo root:

```bash
bash scripts/sync-stage3-tag.sh --write amd64-openrc-<new-date>
```

The tool rewrites every reference atomically and self-verifies. Commit the
result in its own PR.

**Prevention.**

- `lint.yml`'s `stage3-tag-drift` job runs on every PR touching workflows or scripts and fails red on drift.
- `build-packages.yml` also verifies at build start; drift refuses to build.
- The weekly `check-stage3.yml` update issue tells you the exact `--write` command to run.

---

## `Package build failure`

> Package build failure: N package(s) failed.

**Cause.** One or more ebuilds died in a real phase (`configure`, `compile`,
`install`, etc.). Timeout victims are filtered out, so this is not the normal
5.5-hour continuation path.

**Fix.**

1. Download the failed run's artifact (`binpkgs-<chain>-<attempt>`).
2. Look inside `_failures/<cat>/<pkg>/build.log` — the last ~80 lines are
   also in the workflow step summary.
3. Common causes:
   - Upstream source tarball moved — bump the package or pin an older version
   - New dep not yet in Gentoo — add `package.accept_keywords` entry or mask
   - USE-flag conflict — adjust `config/profiles/.../package.use/`
   - Compiler regression — pin GCC or disable LTO for that package
4. Once fixed, dispatch `Build Packages` manually.

---

## `Build did not complete after N attempts`

**Cause.** Every attempt hit the time budget without a real package failure,
and `_max_attempts` was exhausted.

**Fix.** Increase `_max_attempts` for the next manual dispatch, or build one
large atom at a time with the `package: <cat>/<pkg>` input to warm ccache and
publish partial progress.

---

## `Pages site size >900 MiB`

> Pages site is N bytes (>900 MiB). Approaching the 1 GiB GitHub Pages
> limit; consider trimming packages/packages.txt.

**Cause.** The published binhost directory is closing in on GitHub Pages'
1 GiB soft limit. Crossing that limit makes the binhost unreachable.

**Fix.** One or more of:

1. **Trim `packages/packages.txt`** — remove packages rarely installed by
   downstream users.
2. **Reduce package variants** — if both Qt5 and Qt6 variants are shipped
   for the same upstream, drop one.
3. **Bump pruning aggressiveness** — `scripts/prune-old-binpkgs.py`
   currently keeps the newest version per `(cat, pn)`. Nothing to tune
   there; the fix is upstream (fewer packages).

**Prevention.** Monitor the `Site size after pruning` line in the publish
job's log.

---

## `Malformed artifact layout`

> Refusing to publish …/pkg.gpkg.tar (relative path '…' does not match
> <cat>/<pn>/<pn>-<ver>.gpkg.tar)

**Cause.** An artifact uploaded by `build-packages.yml` contains a file at
a path that doesn't match the canonical `<category>/<pn>/<pn>-<ver>.gpkg.tar`
layout. If published anyway, `generate-packages-index.sh` would write
`CPV: tmp/artifacts/…` and every downstream Portage client would crash
with `portage.exception.InvalidData`.

**Fix.**

1. The publish job stops before corrupting the live binhost — no user
   impact.
2. Find the failing artifact in the run's artifacts panel. Inspect
   `find /tmp/artifacts/binpkgs-*/ -name '*.gpkg.tar'`.
3. Most commonly this is a bug in `build.sh`'s `collect_packages` or
   Portage writing to a non-standard `PKGDIR`. Investigate and patch.

---

## `/usr/bin/getuto not found in stage3`

**Cause.** The pinned stage3 does not include `app-portage/getuto`. This
should not happen on any modern (`23.0`) stage3.

**Fix.** Either upgrade `STAGE3_TAG` to a newer snapshot (dispatch the
`Check Stage3 Update` workflow) or, if you *must* stay on this tag, emerge
getuto manually before calling `setup-binpkg-trust.sh`:

```bash
emerge --oneshot app-portage/getuto
```

---

## `Gentoo binhost signing key … not present after getuto`

**Cause.** `getuto` ran but did not import the expected key fingerprint
`534E4209AB49EEE1C19D96162C44695DB9F6043D`. Either Gentoo rotated the
binhost signing key or `getuto` has a regression.

**Fix.**

1. Check [www.gentoo.org/glep/glep-0079.html](https://www.gentoo.org/glep/glep-0079.html) for the current signing key fingerprint.
2. If rotated, update the constant in `scripts/setup-binpkg-trust.sh` and
   `scripts/build.sh` (the old one is also referenced there for a
   skip-if-already-trusted check).

---

## Cache size approaching GHA cap

> Total cache size … is within 2 GiB of GitHub's 10 GiB per-repository cap.

**Cause.** The ccache and binpkg caches together are close to 10 GiB; the next
save attempt may be silently dropped by GitHub.

**Fix.** Options to reduce footprint:

- `CCACHE_SIZE` (default 20G) can be lowered in the workflow env.
- `packages/packages.txt` trimming shrinks both `binpkgs` and `ccache`.

---

## My dispatched build has `_attempt: 1` but keeps failing mid-continuation

Check the "Verify stage3 tag consistency" step in the failed run's log. If
someone updated the stage3 tag between the fresh dispatch and "now", every
subsequent run fails consistency check. Revert to the tag that was live
when the chain started, or start a new chain with `fresh: true`.

---

## I want to start completely over

Dispatch `Build Packages` with `fresh: true`. That is the single supported
"nuke everything" button. Don't manually delete caches via the API — the
script handles pagination correctly (avoids off-by-page bugs deleting while
iterating), deletes in the right order, and logs what it wiped.
