# gentoo-binhost

Binary packages for Gentoo **desktop/plasma, OpenRC, `~amd64`**, built on
GitHub Actions and served from this repository: the heavy packages first
(LLVM, Clang, QtWebEngine, WebKitGTK, VTK, ...), then the rest of a Plasma
desktop.

| | |
|---|---|
| Profile | `default/linux/amd64/23.0/desktop/plasma` |
| Keywords | `~amd64` |
| Baseline | `-march=x86-64-v3` |
| Format | gpkg, signed |
| Index | `https://raw.githubusercontent.com/naelolaiz/gentoo-binhost/binhost` |

Portage only installs a binary whose USE flags equal what the machine would
build itself.  The configuration the packages are built with is in
[config/profiles/](config/profiles/amd64-23.0-desktop-plasma-openrc/); a
machine gets binaries for exactly the packages where its own configuration
says the same.

## Using it

1. Tell Portage about the binhost, next to the official one:

   ```ini
   # /etc/portage/binrepos.conf/binhost.conf
   [naelolaiz-binhost]
   priority = 10
   sync-uri = https://raw.githubusercontent.com/naelolaiz/gentoo-binhost/binhost
   verify-signature = true

   [gentoobinhost]
   priority = 1
   sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64-v3
   verify-signature = true
   ```

   Remove any `PORTAGE_BINHOST` line from `make.conf`; `binrepos.conf`
   replaces it.

2. Trust the key the packages are signed with (as root, from a checkout of
   this repository):

   ```bash
   bash scripts/trust-binhost-key.sh keys/binhost-signing-key.asc
   ```

3. Install as usual:

   ```bash
   emerge --ask --update --deep --newuse --getbinpkg @world
   ```

   Packages marked `[binary]` come from a binhost; anything Portage lists
   under "ignored due to non matching USE" is a place where the machine's
   configuration differs from the one used here.

[docs/USING.md](docs/USING.md) has the details: which settings have to match,
how to compare a machine with the binhost, and what the baseline means.
Steam's 32-bit libraries are covered in [docs/STEAM.md](docs/STEAM.md).

## How it works

Every run starts from a fresh Gentoo stage3 container that is configured
like a machine using the binhost.  Whatever the binhosts already offer is
installed as a binary; whatever is missing, or newer in the tree, is
compiled, signed and published straight away.  There is no build state to
carry around: what has been published is the progress, so a run that is cut
short, fails, or is cancelled loses only the packages it had not finished.

- **Package files** are release assets of this repository, one release per
  category.
- **The index** (`Packages`) is a file on the `binhost` branch.
- **A daily run** picks up new versions; a run that reaches the time limit
  of a hosted runner publishes what it has and starts the next one.
- **Packages that take longer than one run** finish across runs through the
  compiler cache.
- **A package that fails to build** is reported and does not stop the
  others.
- **Each run ends with an install check**: a clean container has to install
  what was just published, with signature verification on.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains the design and the
reasons behind it; [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) what to
do when a run reports a problem.

## What gets built

The package lists are in [packages/tiers/](packages/tiers/), processed in
file name order:

| Tier | Contents |
|---|---|
| `00-smoke` | two tiny packages that exercise the whole pipeline |
| `10-heavy` | the multi-hour builds |
| `20-desktop` | Plasma, Qt, KDE applications, audio production, CAD, tools |
| `21-desktop-more` | the rest of what the machines have installed |
| `25-steam-runtime` | the 32-bit libraries Steam needs |
| `30-kmod` | kernel and VirtualBox modules |

Run a single tier from the Actions tab: **Build packages → Run workflow →
tiers**.

## Repository layout

```
.github/workflows/
  build.yml               build, publish, install check, follow-up run, alert issue
  schedule.yml            daily trigger for build.yml
  ci.yml                  lint, unit tests, end-to-end test on every pull request
  check-workarounds.yml   weekly: reports configuration workarounds that can go
config/
  binhost.conf            profile, stage3 image, official binhost, cache size
  no-publish.txt          packages that are built but never published
  profiles/<profile>/     make.conf, package.use, package.mask, package.license
  workarounds.json        self-checks for the workarounds in the profile
packages/tiers/           what to build, in order
scripts/
  host-build.sh           one run on the CI host: container, publishing, follow-up
  container-build.sh      inside the container: resolve, build, report
  setup-consumer.sh       configure a container like a machine using the binhost
  binhost.py              publisher: release assets and the index branch
  pkgindex.py             read, merge and validate Packages indexes
  portage-index.py        index checks done by Portage itself
  consumer-smoke.sh       install check on a clean container
  trust-binhost-key.sh    make Portage trust the binhost's signing key
  use-closure.sh          work out which packages need a USE flag (Steam)
  ...
tests/                    unit tests and the end-to-end test
keys/                     the public signing key
```

## License

Configuration files and scripts in this repository are released under the
[MIT License](LICENSE).  Binary packages built from Gentoo ebuilds are subject to their
own upstream licenses; packages that may not be redistributed are not
published.
