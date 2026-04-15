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
│   ├── build-tier1-monsters.yml      # qtwebengine, webkit-gtk, llvm/clang — weekly
│   ├── build-tier2-heavy.yml         # KDE plasma, Qt, ffmpeg, mesa — twice-weekly
│   ├── build-tier3-rest.yml          # remaining world packages — twice-weekly
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
│   ├── tier1-monsters.txt            # compile monsters (hours each)
│   ├── tier2-heavy.txt               # heavy packages (30 min – 2 h)
│   └── tier3-rest.txt                # everything else
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

## Build Tiers

| Tier | Contents | Schedule |
|------|----------|----------|
| **Tier 1** | qtwebengine, webkit-gtk, llvm, clang | Weekly (Sun) |
| **Tier 2** | KDE Plasma, Qt modules, ffmpeg, mesa, OpenCV, VTK | Mon & Thu |
| **Tier 3** | Audio tools, KDE apps, dev tools, system utilities | Tue & Fri |

Each build uses ccache to speed up incremental rebuilds.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for:
- How to submit locally-built packages (e.g. with `-march=znver3` or `abi_x86_32`)
- How to improve the configuration or package lists

## License

Configuration files and scripts in this repository are released under the
[MIT License](LICENSE).  Binary packages built from Gentoo ebuilds are subject
to their own upstream licenses.
