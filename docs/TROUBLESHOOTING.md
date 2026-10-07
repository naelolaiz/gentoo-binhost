# Troubleshooting

Every run writes a summary (the run's page on GitHub) and uploads its logs
as the artifact `build-logs-<run>`.  Problems that need a human are collected
in one issue labelled `binhost-alert`, which closes itself after a clean run.

Contents of the logs artifact:

| File | What |
|---|---|
| `result.env` | status, counts, tree snapshot, toolchain versions |
| `failures.tsv`, `failures/<category>/<package>/build.log` | packages that failed and their build logs |
| `unresolved.tsv`, `plans/*.log` | roots Portage could not resolve, with its explanation |
| `planned.txt` | what the run decided to compile |
| `problems.md` | the text that went into the alert issue |
| `emerge-info.txt` | the builder's full configuration |

## "N package(s) failed to build"

The package's `build.log` is in the artifact; its last lines are in the job
log under the package's name.  Other packages were still built and published.

- A real build failure in the tree: wait for the fix (the next run tries
  again), or add a workaround to the profile.  A workaround in
  `package.mask` or `package.use` needs the same change on the machines and
  an entry in `config/workarounds.json`, so the weekly check reports when it
  is no longer needed.
- Marked "out of memory or disk": the package is fine, the runner was not.
  If it happens for a package in a tier without `#@ jobs=1`, move the package
  to the heavy tier.

## "N root(s) could not be resolved"

Portage found no way to install a package from a tier.  `plans/*.log` has
its explanation.  Usual causes:

- **A USE dependency is not met**
  (`Change USE: +abi_x86_32` on the Steam tier): regenerate
  `package.use/20-steam-multilib`, see [STEAM.md](STEAM.md).
- **A keyword, mask or licence** keeps a dependency out: add it to the
  profile.
- **A package left the tree or was renamed**: update the tier file.
- **A conflict in the tree** that upstream will sort out: nothing to do.

## "Some finished packages could not be published"

Uploading or pushing the index failed (GitHub error, rate limit, an asset
GitHub renamed), or a package was built but could not be installed in the
build container.  Nothing inconsistent was published; the packages are
rebuilt by the next run, mostly from the compiler cache.  If it repeats, the
job log of the "Build and publish" step has the reason next to each package.

Packages that were built but not yet installed when a run reached its time
limit are not reported here; the next run builds them again.

If the message mentions an **immutable release**: "immutable releases" has
been switched on in the repository settings.  It has to be off; packages are
added to the category releases over time.

## "The install check ... ended as failure"

A clean container could not install what was just published.  The follow-up
run is not started while this fails.

- `Portage would not install <cpv> from the binhost`: the plan printed below
  that line says why; most often the package's USE flags in the index do not
  match the profile.
- `GnuPG verification failed`: the signing key and
  `keys/binhost-signing-key.asc` do not belong together, or the key expired.
  See [keys/README.md](../keys/README.md).

To take a bad package out of the binhost, run locally with a token that can
write to the repository:

```bash
podman run --rm -e GH_TOKEN -v "$PWD":/repo:ro docker.io/library/python:3.12 \
  python3 /repo/scripts/binhost.py --backend github --repo naelolaiz/gentoo-binhost \
  evict <category>/<package>-<version>
```

(`python:3.12` contains git, which the publisher needs.)  The package
disappears from the index at once and the next run rebuilds it.  Its file
is deleted two weeks later, like any replaced file; add `--now` after
`evict` to delete it immediately.  Run by hand like this, the new index is
checked by the publisher's own rules but not parsed by Portage.

## "Building stopped: ..."

- **without finishing or compiling anything new**: a run spent its whole
  time budget and produced nothing, not even new compiler cache entries.
  Either a package's non-cacheable part does not fit into one run, or the
  compiler cache is not being hit; the summary shows the hit count.  The
  interrupted package is named in the summary.
- **4 runs in a row reached the time limit without publishing a package**:
  the package named in the message does not get finished, although the
  compiler cache grows.  Usually its non-cacheable part (linking, Rust, code
  generation) does not fit into one run.  Take it out of its tier file; the
  next daily run tries it again otherwise, and the tiers after it wait.

A run summary that says **Chain ended: 40 runs in a row reached the time
limit** is not a problem and opens no issue; the next daily run starts a
new chain.  A chain keeps its tree snapshot for at most two days, then moves
to a current one.

## "The build container failed"

The container stopped before or outside of building packages: the tree could
not be synced, a binhost index could not be read, the signing key could not
be imported, or the self-test of the signature failed.  The job log ends with
the reason.

- `Cannot read our own index`: `raw.githubusercontent.com` did not serve the
  index branch.  Temporary; start the run again.
- `Packages signed with key ... would be rejected by clients`: the secret key
  in `GPG_PRIVATE_KEY` is not the one whose public half is in `keys/`, or it
  has expired.
- `Cannot sign with the configured key`: `GPG_PASSPHRASE` is wrong or
  missing.

## The daily build does not start

GitHub switches off scheduled workflows in repositories without recent
activity.  Re-enable **Daily build** on the Actions tab.  Runs started by
hand are not affected.

## Starting over

Delete the `binhost` branch and the `pkgs-*` releases; the next run creates
an empty index and builds everything again.  To drop only the compiler
cache, delete the `cc-v1-*` entries under Actions → Caches.
