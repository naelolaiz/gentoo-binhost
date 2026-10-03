# Using the binhost on a machine

## What has to match

Portage compares a binary package with what the machine would build and
ignores the binary if they differ.  What it compares:

| Compared | Where it is set | Value used here |
|---|---|---|
| Keywords | `ACCEPT_KEYWORDS` | `~amd64` |
| Global USE flags | `USE` in `make.conf`, the profile | see the profile's `make.conf` |
| Per-package USE flags | `package.use` | see the profile's `package.use/` |
| `CPU_FLAGS_X86` | `make.conf` | the x86-64-v3 set, see below |
| `VIDEO_CARDS`, `INPUT_DEVICES`, `L10N`, `LLVM_TARGETS`, `GRUB_PLATFORMS` | `make.conf` | see the profile's `make.conf` |
| `PYTHON_TARGETS`, `PYTHON_SINGLE_TARGET` | `make.conf`, the profile | not set: the profile's default |
| Tree | `emerge --sync` | at most a day or two older than yours |

`CFLAGS` are *not* compared.  A machine can keep `-march=native` for what it
compiles itself and still install binaries built with `-march=x86-64-v3`.

All of these are USE flags as far as Portage is concerned, so a difference
never breaks anything: the machine just compiles that package itself.  The
closer the configuration, the more comes as a binary.

### CPU flags

```
CPU_FLAGS_X86="aes avx avx2 bmi1 bmi2 f16c fma3 mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3"
```

This is what every x86-64-v3 CPU supports.  `cpuid2cpuflags` prints more on
most machines (`sha`, `vpclmulqdq`, `sse4a`, ...); with those extra flags set,
the packages that have them as USE flags are compiled locally.  Using the line
above gives up a few hand-optimised code paths in a handful of packages and
gets binaries for all of them.

### Python

The packages are built for the Python version of the profile, which is also
what the stage3 images and the official binhost use.  A `PYTHON_TARGETS` or
`PYTHON_SINGLE_TARGET` line in `make.conf` that pins other versions makes
Portage ignore every binary of a Python package.

## Setting a machine up

1. `/etc/portage/binrepos.conf/binhost.conf` as in the [README](../README.md).
2. Trust the signing key:

   ```bash
   bash scripts/trust-binhost-key.sh keys/binhost-signing-key.asc
   ```

   The script runs `getuto` (which creates Portage's keyring in
   `/etc/portage/gnupg` and imports the official Gentoo keys), imports this
   binhost's key and signs it with the keyring's local trust key.  Portage
   refuses packages whose key is not fully trusted.

3. Bring the configuration in line.  Copy what you want from
   `config/profiles/amd64-23.0-desktop-plasma-openrc/` to `/etc/portage/`;
   the files are plain Portage configuration.  Each file you leave out costs
   the binaries of the packages it names: `package.use/20-steam-multilib`,
   for instance, covers Mesa, glib, fontconfig and one LLVM slot (see
   [STEAM.md](STEAM.md)), with or without Steam installed.
   `package.use/90-smoke-test` only concerns the test packages and can be
   skipped.

## Checking how much a machine would get

```bash
emerge --pretend --verbose --update --deep --newuse --getbinpkg @world
```

- `[binary ...]` lines are packages that come from a binhost.
- `[ebuild ...]` lines would be compiled.
- At the end, **"The following binary packages have been ignored due to non
  matching USE"** lists every binary Portage found and rejected, with the
  flags that differ.  Each entry is either a setting to align, or a package
  you prefer to build your own way.

Portage only prints that list when `--binpkg-respect-use` is not given on
the command line or in `EMERGE_DEFAULT_OPTS`; its default behaviour is the
same, with the explanation.

## Glibc and the compiler

The packages are built with the stable toolchain of the stage3 image and
record the glibc they need (`RDEPEND: >=sys-libs/glibc-...`), so Portage
updates glibc first when a machine is behind.  A `~amd64` machine is at or
ahead of that version.

## When a package is missing

- It failed to build: see the open issue labelled `binhost-alert`.
- It is not in a tier: add it to a file in `packages/tiers/`.
- It may not be redistributed (`RESTRICT=bindist`, or listed in
  `config/no-publish.txt`): it is never published.
- It is in an overlay: only the Gentoo repository is built.
