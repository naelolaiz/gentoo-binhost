# Testing

Everything can be checked in containers; nothing has to be installed or run
on the host.  The commands use `podman`; `docker` works the same way.  CI
(`.github/workflows/ci.yml`) runs all of this on every pull request.

## Unit tests

Index handling and the publisher, including the GitHub backend against a
local stand-in for the releases API (needs `git` in the image):

```bash
podman run --rm --network none -e PYTHONDONTWRITEBYTECODE=1 -v "$PWD":/repo:ro \
  docker.io/library/python:3.12 python3 -m unittest discover -s /repo/tests
```

## Lint

```bash
podman run --rm --network none -v "$PWD":/repo:ro -w /repo \
  docker.io/koalaman/shellcheck-alpine:stable \
  sh -c 'shellcheck --severity=warning --external-sources scripts/*.sh tests/*.sh'

podman run --rm --network none -v "$PWD":/repo:ro -w /repo \
  docker.io/rhysd/actionlint:1.7.12 -color
```

## End to end

The whole pipeline with a directory served over HTTP in place of GitHub:
build and sign the smoke tier, publish, check that a second run has nothing
to do, install on a clean container with signature verification, and check
that the same package is refused when its key is not trusted.

Each phase runs in a fresh stage3 container; they share a state directory.
The Portage tree is kept in a second directory so that it is downloaded
once.

```bash
state="$(mktemp -d)"; mkdir -p "$state/state" "$state/tree"
for phase in build rebuild consume; do
  podman run --rm --init --privileged \
    -v "$PWD":/repo:ro \
    -v "$state/tree":/var/db/repos/gentoo \
    -v "$state/state":/state \
    docker.io/gentoo/stage3:amd64-desktop-openrc \
    bash /repo/tests/e2e.sh "$phase" || break
done
```

About ten minutes, most of it downloading the tree and the image.  With
rootless podman, remove the state directory with
`podman unshare rm -rf "$state"` (some files belong to the container's
`portage` user).

### The time limit

Two more phases check what happens to a package that is still compiling when
a run has to stop.  They need the `build` phase to have run, and a compiler
cache directory shared between them:

```bash
mkdir -p "$state/ccache"
# Limited to one CPU, so that the package cannot finish before the deadline.
podman run --rm --init --privileged --cpuset-cpus 0 \
  -v "$PWD":/repo:ro -v "$state/tree":/var/db/repos/gentoo -v "$state/state":/state \
  -v "$state/ccache":/var/cache/ccache \
  docker.io/gentoo/stage3:amd64-desktop-openrc bash /repo/tests/e2e.sh deadline

podman run --rm --init --privileged \
  -v "$PWD":/repo:ro -v "$state/tree":/var/db/repos/gentoo -v "$state/state":/state \
  -v "$state/ccache":/var/cache/ccache \
  docker.io/gentoo/stage3:amd64-desktop-openrc bash /repo/tests/e2e.sh resume
```

`deadline` builds cmake with a six-minute limit and expects the builder to
stop with exit status 42, the package to be reported as interrupted (not as
failed), and nothing half-built to be published.  `resume` starts from a
fresh container and expects the build to finish with at least 80 % of the
files compiled before the interruption coming back from the compiler cache.
About fifteen minutes; not part of the pull request checks.

## Resolving the real tiers without building

To see whether a change to the profile or to a tier still resolves, and how
much it would compile:

```bash
state="${state:-$(mktemp -d)}"; mkdir -p "$state/tree" "$state/out"
podman run --rm --init --privileged \
  -v "$PWD":/repo:ro -v "$state/tree":/var/db/repos/gentoo -v "$state/out":/out \
  docker.io/gentoo/stage3:amd64-desktop-openrc \
  bash /repo/scripts/container-build.sh --plan-only --tiers "heavy" \
    --binhost-uri https://raw.githubusercontent.com/naelolaiz/gentoo-binhost/binhost \
    --trust-key /repo/keys/binhost-signing-key.asc --out /out
```

`$state/out/plans/` has Portage's output for every dependency calculation,
`$state/out/unresolved.tsv` the roots that do not resolve.  The index branch
has to exist (it does after the first run on GitHub).

## On GitHub

**Build packages → Run workflow** with `tiers` set to `smoke` builds, signs,
publishes and install-checks two tiny packages in a few minutes.  Run from a
branch other than `main`, it uses the `binhost-test` branch and
`test-pkgs-*` releases and leaves the real binhost alone.
