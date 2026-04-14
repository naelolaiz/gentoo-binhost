# Local CPU Flags Guide

This guide explains how to adapt the packages from this binhost to your local
CPU when your processor supports different (or fewer) instructions than the
x86-64-v3 baseline used to build the packages.

## Background

The binhost compiles everything with:

```make.conf
COMMON_FLAGS="-march=x86-64-v3 -O2 -pipe"
CPU_FLAGS_X86="aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3"
```

**x86-64-v3** covers most CPUs released from approximately 2015 onwards
(Intel Haswell/Broadwell/Skylake+, AMD Excavator/Zen+).

Packages built this way are binary-compatible on any x86-64-v3 (or newer) CPU.
On older or different micro-architectures you may need to recompile some
packages.

---

## Checking Your CPU

### Option 1: `cpuid2cpuflags`

```bash
emerge app-portage/cpuid2cpuflags
cpuid2cpuflags
```

Example output:

```
CPU_FLAGS_X86: aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3
```

Add the output line to `/etc/portage/make.conf`.

### Option 2: Read `/proc/cpuinfo`

```bash
grep flags /proc/cpuinfo | head -1
```

Then compare to the flags listed at <https://en.wikipedia.org/wiki/X86-64#Microarchitecture_levels>.

### Option 3: GCC auto-detect (approximate)

```bash
gcc -march=native -Q --help=target | grep march
```

---

## Configuring Your Local System

### If your CPU supports x86-64-v3 or newer

Just add this binhost URL to `/etc/portage/make.conf` and you are done:

```bash
PORTAGE_BINHOST="https://naelolaiz.github.io/gentoo-binhost/amd64/23.0/desktop/plasma/openrc/x86-64-v3"
```

### If your CPU is older (x86-64-v2 or plain x86-64)

You can still use the binhost for packages that do not contain
architecture-sensitive compiled code (e.g. pure-Python packages), but for
anything with C/C++ code you should recompile locally.

Set a conservative `-march` in your `make.conf`:

```bash
# For x86-64-v2 (SSE4.2, no AVX)
COMMON_FLAGS="-march=x86-64-v2 -O2 -pipe"

# For plain x86-64
COMMON_FLAGS="-march=x86-64 -O2 -pipe"
```

### If your CPU is newer (Zen 3, Raptor Lake, etc.)

You can use all binhost packages (they run fine on newer CPUs) but you may
want to recompile CPU-sensitive packages locally to take advantage of newer
instructions.

Example for AMD Zen 3:

```bash
COMMON_FLAGS="-march=znver3 -O2 -pipe"
CPU_FLAGS_X86="aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3 sha vpclmulqdq"
```

You can then contribute those locally-built packages back via a PR — see
[CONTRIBUTING.md](../CONTRIBUTING.md).

---

## USE Flag Compatibility

The binhost is built with a specific set of USE flags (see
`config/profiles/amd64-23.0-desktop-plasma-openrc/`).

If your local USE flags differ, Portage will notice and recompile the package
from source.  To accept binhost packages even when USE flags differ:

```bash
# /etc/portage/make.conf
EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS} --binpkg-respect-use=n"
```

> ⚠️  Use with care — packages built with different USE flags may be
> functionally different from what you expect.

---

## Troubleshooting

### "Illegal instruction" crash

This means a package was compiled for a newer ISA than your CPU supports.
Recompile the offending package from source:

```bash
emerge --oneshot --usepkg=n =<category/package-version>
```

### Portage ignores the binhost

Check that `PORTAGE_BINHOST` is set and that your Portage version supports
GPKG format:

```bash
emerge --info | grep BINHOST
emerge --version   # needs >= 3.0.30 for GPKG
```

### Package checksum mismatch

The binhost index may be stale.  Run:

```bash
emaint binhost --fix
```
