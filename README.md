# gentoo-binhost

Community Gentoo binary package host (binhost) for **KDE Plasma / OpenRC / ~amd64**,
served via GitHub Pages and built automatically with GitHub Actions.

## Profile

| Setting | Value |
|---------|-------|
| Profile | `default/linux/amd64/23.0/desktop/plasma` |
| Init system | OpenRC |
| Keywords | `~amd64` (testing) |
| Architecture baseline | x86-64-v3 (`-march=x86-64-v3`) |
| Package format | GPKG (`.gpkg.tar`, zstd-compressed) |

## Usage

Add this to your `/etc/portage/make.conf`:

```bash
PORTAGE_BINHOST="https://naelolaiz.github.io/gentoo-binhost/amd64/23.0/desktop/plasma/openrc/x86-64-v3"
FEATURES="${FEATURES} getbinpkg"
```

Then install packages as usual — Portage will prefer pre-built binaries:

```bash
emerge --ask --getbinpkg <package>
```

### CPU Compatibility

Packages are compiled for **x86-64-v3** (AVX2, FMA, etc. — most CPUs ≥ 2015).
If your CPU is older or newer, see [docs/LOCAL-CPU-FLAGS-GUIDE.md](docs/LOCAL-CPU-FLAGS-GUIDE.md).

### GPG Verification (optional)

If signing is configured, import the public key:

```bash
gpg --import keys/binhost-signing-key.asc
```

## Repository Structure

```
gentoo-binhost/
├── .github/workflows/
│   ├── build-packages.yml            # builds all packages (weekly, auto-resumes)
│   ├── publish-to-pages.yml          # deploys binpkgs to GitHub Pages
│   └── accept-local-packages.yml     # validates locally-built package PRs
├── config/profiles/
│   └── amd64-23.0-desktop-plasma-openrc/
│       ├── make.conf
│       ├── package.use/
│       ├── package.accept_keywords/
│       ├── package.mask/
│       └── package.license/
├── packages/
│   └── packages.txt                  # all packages to build
├── scripts/
│   ├── build.sh                      # main CI build script
│   ├── upload-local-packages.sh      # submit locally-built packages via PR
│   └── generate-packages-index.sh    # regenerate Packages index
├── docs/
│   └── LOCAL-CPU-FLAGS-GUIDE.md
├── keys/
│   └── README.md                     # GPG key setup instructions
├── contrib/                          # locally-built package contributions
└── CONTRIBUTING.md
```

## How the Build Works

The CI runs weekly (Sunday) and does what you'd do on your own system:

1. **Sync** — `emerge-webrsync` (or `emerge --sync`)
2. **Build** — `emerge --buildpkg --usepkg --getbinpkg --keep-going <all packages>`
3. **Publish** — deploy to GitHub Pages

If the build times out (GitHub Actions has a 6 h limit), it saves state, publishes
whatever was built, and **automatically re-triggers** itself to continue.
This repeats until all packages complete (up to 8 attempts ≈ 44 h of build time).

Each build uses ccache to speed up incremental rebuilds.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for:
- How to submit locally-built packages (e.g. with `-march=znver3` or `abi_x86_32`)
- How to improve the configuration or package lists

## License

Configuration files and scripts in this repository are released under the
[MIT License](LICENSE).  Binary packages built from Gentoo ebuilds are subject
to their own upstream licenses.
