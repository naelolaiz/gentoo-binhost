# Contributing to gentoo-binhost

Thank you for considering a contribution!  There are two main ways to contribute:

1. **Locally-built packages** — you compiled packages on your own machine (e.g.
   with `-march=znver3` or with `abi_x86_32` USE flag) and want to share them.
2. **Configuration improvements** — better USE flags, new package lists, CI
   workflow improvements, documentation, etc.

---

## Contributing Locally-Built Packages

### Prerequisites

- Gentoo system with `BINPKG_FORMAT="gpkg"` in your `make.conf`
- `git` installed
- A fork of this repository on GitHub

### Step 1 — Build your packages

Make sure your `/etc/portage/make.conf` includes:

```bash
FEATURES="buildpkg binpkg-multi-instance"
BINPKG_FORMAT="gpkg"
BINPKG_COMPRESS="zstd"
PKGDIR="/var/cache/binpkgs"
```

Then build the packages you want to contribute:

```bash
emerge --buildpkg <your-packages>
```

The resulting files will be at `/var/cache/binpkgs/<category>/<name>/<name-version>.gpkg.tar`.

### Step 2 — Use the upload helper script

Clone your fork and run:

```bash
git clone https://github.com/<your-username>/gentoo-binhost.git
cd gentoo-binhost

bash scripts/upload-local-packages.sh \
  --march znver3 \
  /var/cache/binpkgs/dev-qt/qtbase/qtbase-6.7.0.gpkg.tar \
  /var/cache/binpkgs/dev-qt/qtwebengine/qtwebengine-6.7.0.gpkg.tar
```

The script will:
- Create a new git branch `contrib/<timestamp>`
- Copy the packages under `contrib/amd64/23.0/desktop/plasma/openrc/znver3/`
- Create a commit

### Step 3 — Open a Pull Request

```bash
git push origin contrib/<timestamp>
```

Then open a Pull Request on GitHub.  The CI will automatically:

1. Validate that every file is a valid `.gpkg.tar` archive.
2. Check the path structure.
3. On merge, trigger the publish workflow to include the packages in the binhost.

### Package Path Structure

Contributed packages live under:

```
contrib/<arch>/<profile-version>/<desktop>/<variant>/<init>/<march>/<category>/<pkg-ver>.gpkg.tar
```

Example:

```
contrib/amd64/23.0/desktop/plasma/openrc/znver3/dev-qt/qtbase-6.7.0.gpkg.tar
```

---

## Contributing Configuration Changes

For changes to `make.conf`, `package.use`, `package.accept_keywords`,
`package.mask`, or the package lists (`packages/*.txt`):

1. Fork the repository
2. Create a branch: `git checkout -b my-change`
3. Make your changes
4. Open a Pull Request with a description of why the change is needed

---

## GPG Signing

If you want your packages to be GPG-signed before submission:

```bash
bash scripts/upload-local-packages.sh \
  --march znver3 \
  --sign \
  --gpg-key YOUR_GPG_KEY_ID \
  /var/cache/binpkgs/...
```

The script will create a `.asc` detached signature alongside each package.

---

## Code of Conduct

Please be respectful.  This is a community project.  Contributions that
are disruptive, abusive, or contain malware will be rejected and the
contributor banned.
