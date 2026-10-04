# Architecture

How the builder works and why it is built this way.  For using the binhost
see the [README](../README.md); for dealing with a failed run see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## The idea

```
        daily trigger / manual / previous run
                      │
                      ▼
   ┌─────────────────────────────────────────┐
   │ build (hosted runner)                   │
   │                                         │
   │  host-build.sh ── fresh stage3 container│      release assets
   │     │               container-build.sh  │   ┌──► pkgs-<category>/*.gpkg.tar
   │     │                 resolve, compile  │   │
   │     └─ binhost.py ◄── PKGDIR ───────────┼───┤
   │        every 5 min and at the end       │   └──► branch `binhost`
   └──────────────────┬──────────────────────┘        Packages, state.json
                      ▼
        install check on a clean container
                      ▼
       next run, if this one ran out of time
```

**What is published is the only state.**  Every run starts from a fresh
stage3 container, configures it like a machine that uses the binhost, and
asks Portage what the package lists need.  Anything a binhost already offers
is a binary; the rest is compiled, signed and published while the run is
still going.  The next run sees those packages as binaries and continues with
what is left.

Consequences:

- A run can stop anywhere (time limit, runner failure, cancellation) and
  loses only what was not installed in the container yet: the packages it
  was compiling, and after a hard stop the few that were built and still
  waiting to be installed.
- Nothing has to be passed from one run to the next: no chain ids, no
  attempt counters, no saved container images, no cached package database.
- A new upstream version needs no detection logic.  The tree is newer, no
  binary matches, so it gets built.
- The builder uses the binhost exactly as a machine does.  If publishing is
  broken, the next run cannot use its own packages and says so.

## Storage

| What | Where | Why |
|---|---|---|
| Package files | Release assets, one release per category (`pkgs-dev-qt`, ...; `pkgs-dev-qt.2` and so on once a release is full) | No size or bandwidth limit, files can be added one at a time; a release holds at most 1000 files |
| Index (`Packages`) and `state.json` | Branch `binhost`, read through `raw.githubusercontent.com` | Replaced atomically by a git push; small |
| Compiler cache | Actions cache, one entry | Only an accelerator; see below |

Portage is told that the files are not next to the index: the index header
has `URI: https://github.com/<repo>/releases/download` and each entry
`PATH: <release tag>/<file>`.

Rules the publisher (`scripts/binhost.py`) follows:

- **Entries are Portage's own.**  Each entry is copied from the
  `PKGDIR/Packages` that Portage wrote in the build container; only `PATH`
  is rewritten.  Slot, USE flags, dependencies and build time are never
  reconstructed.
- **Upload before index, delete after index.**  A file is uploaded before
  the index mentions it and deleted only once the index stopped mentioning
  it, so a client never finds an entry without its file.
- **Portage reads every index the workflow publishes before it goes live.**
  `scripts/portage-index.py check` parses the candidate with Portage's
  reader in a container; a rejected candidate is not pushed.
- **Only installed packages are published.**  Portage writes the binary
  before merging the package.  The build container reports what is really
  installed, and a binary whose merge failed is not handed out.
- **Not everything may be published.**  Packages with `RESTRICT=bindist` and
  those in `config/no-publish.txt` are built when needed and kept private.
- **One entry per package version.**  A rebuild replaces the entry; the old
  file is deleted by pruning after a grace period.

Pruning runs at the end of every run that got through its tiers.  A package
whose ebuild has been gone from the tree for 14 days is dropped from the
index, and a file is deleted 14 days after the index stopped referring to
it (because the package was rebuilt, dropped or removed by hand).  Files in
the releases that nothing refers to, left by an upload whose index update
never happened, are found by the same step and deleted after the same
period.

## One run

`scripts/host-build.sh` on the runner:

1. Frees disk space and restores the compiler cache.
2. Creates the index branch if it does not exist, reads `state.json`.
3. Starts the stage3 container with `scripts/container-build.sh`.
4. Publishes finished packages every five minutes while the container runs,
   and once more when it stops.
5. Prunes, decides whether another run is needed, writes the summary.

`scripts/container-build.sh` in the container:

1. `scripts/setup-consumer.sh`: sync the tree, apply the profile from
   `config/profiles/`, write `binrepos.conf` (this binhost and the official
   one), trust the signing key.  The same script prepares the container of
   the install check.
2. Builder-only settings: `buildpkg`, signing, ccache, `MAKEOPTS`.
3. Per tier: resolve with `emerge --pretend`, then build only the versions
   that have to be compiled.  A tier whose packages all exist as binaries
   costs one dependency calculation and installs nothing.
4. Before the first compile of a run, update the container's own packages
   (`@world`), using binaries where they exist, so that leftovers of the
   stage3's default configuration do not conflict with what the tiers need.

### Time limit

A hosted runner stops a job after six hours.  The build stops itself after
`budget_minutes` (285 by default), which leaves time to publish and to save
the compiler cache.  If packages remain, the run records the tree snapshot
and container image it used and dispatches the next run, which uses the
same ones.

Portage installs a finished package only at a moment when no other package
is building, and drops the ones still waiting when it is told to stop.  At
the time limit the builder therefore first asks it to install what is
waiting (`SIGUSR2`, for up to four minutes) and only then stops it, so that
those packages are published too.

### Packages longer than one run

Portage cannot resume a half-finished compile, but ccache can make it
cheap to redo: the object files compiled so far are in the cache, the next
run gets them back and continues where the last one stopped.  That only
works if compiler, headers and sources are identical, which is why a
follow-up run pins the tree snapshot and the image, and why the builder
keeps the toolchain of its stage3 instead of upgrading it.

The chain of runs ends when a run reaches the limit without having
published or compiled anything new, or when four runs in a row published
nothing (one package that does not get finished); both are reported.  It
also ends after 40 runs, without a report, because the tree it is pinned
to is old by then.  The next daily run starts a new chain from a current
tree.

### Failures

- **A package fails to build.**  `emerge --keep-going` drops it and what
  depends on it, and builds the rest.  For the remainder of the run the
  package is left out of every dependency calculation, so nothing starts it
  a second time; roots that need it are reported as unresolvable.  The log
  goes into the run's artifact, the package into the alert issue.  The next
  run tries again; with the compiler cache that costs little until it
  reaches the same error.
- **A set of packages cannot be resolved together.**  Where Portage names
  the root it cannot satisfy, the others are tried without it and that
  root on its own; otherwise the list is split in halves until the
  offending root is isolated.  A dependency calculation that takes more
  than ten minutes counts as failed, and after half an hour of failed
  calculations the rest of the tier is left for the next run.
- **Build-time dependency loops** (ffmpeg needs openal needs pipewire needs
  ffmpeg) only exist in a fresh container.  Portage names a USE flag that
  breaks the loop; the builder applies it for one build, without producing a
  binary package, and then rebuilds the affected package as configured.
  Only that second build is published.  No such flags are kept in the
  configuration.
- **Out of memory or disk** is recognised in the build log and reported as
  such, not as a broken package.  Such a package gets one more try in the
  same run, by a later tier that needs it.  The work
  directory of a failed build is removed while the run goes on, so one
  failure for lack of space does not cause the next.

### Install check and alert issue

After a run that published something, a second job starts a clean stage3,
configures it as a consumer and checks that Portage picks the published
binaries, downloads them, verifies their signatures and installs them.

A final job keeps one issue labelled `binhost-alert`: opened or updated when
a run ends with a problem (failed packages, unresolved roots, unpublished
packages, a failed install check, a chain that stopped), closed by the next
run that gets through every tier cleanly.  A clean run of a single tier
leaves it open.

## Decisions worth knowing

**The builder consumes its own binhost.**  An earlier version did not, on
purpose: an index with corrupt entries had once crashed every client,
including the builder.  The price was rebuilding everything every week and
never publishing a usable index.  The protection is now in the publishing
path instead: entries come from Portage, the candidate index is parsed by
Portage before it is pushed, and every run ends with an install on a clean
machine.  `binhost.py evict <cpv>` removes a bad package by hand
([TROUBLESHOOTING.md](TROUBLESHOOTING.md)).

**No part of the system is cached except the compiler cache.**  Caching the
installed-package database separately from the files it describes produced
states Portage could not make sense of.  A fresh container plus binaries is
always consistent.

**The toolchain is not upgraded in the builder.**  gcc, glibc and binutils
stay at the stage3's stable versions.  Binaries built against an older
glibc run on a newer one; the reverse fails at run time.  Portage records
the glibc a binary needs, so machines are protected either way.

**Signing is not optional.**  Portage verifies binary package signatures by
default; unsigned packages would be rejected by every client.  The builder
signs with Portage's own mechanism (`FEATURES=binpkg-signing`) and checks
before building that the key it signs with is the one published in `keys/`.

**Test runs do not touch the real binhost.**  A run on any ref other than
`main` uses the branch `binhost-test` and releases `test-pkgs-*`, and never
starts a follow-up run.

**The daily trigger is a separate workflow.**  GitHub disables scheduled
workflows in repositories without recent activity.  With the schedule in its
own file that only stops the trigger; manual runs and follow-up runs keep
working.

## Limits

- A package whose non-cacheable part (linking, code generation, Rust)
  does not fit into one run cannot be built this way.
- Only the Gentoo repository is built, no overlays.
- One configuration.  A machine with different USE flags compiles the
  affected packages itself.
- The tree the packages are built from is a daily snapshot; a machine that
  synced later may find a few binaries ignored until the next run.
- Using GitHub's hosted runners and release storage for this is within what
  the terms allow for a project's own builds, but GitHub decides; do not
  add anything that keeps the schedule alive artificially.
