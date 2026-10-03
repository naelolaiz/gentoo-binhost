# Steam

`games-util/steam-launcher` comes from the
[steam-overlay](https://github.com/anyc/steam-overlay) and needs 32-bit
builds of a number of libraries.  Without them Portage stops with:

```
emerge: there are no ebuilds built with USE flags to satisfy "media-libs/fontconfig[abi_x86_32]".
```

Enabling `abi_x86_32` for fontconfig alone only moves the error to the next
library, because every library fontconfig links to needs the flag too.

## The fix

[`package.use/20-steam-multilib`](../config/profiles/amd64-23.0-desktop-plasma-openrc/package.use/20-steam-multilib)
enables `abi_x86_32` for the complete set: the libraries Steam asks for and
everything they depend on, and nothing else.  On a machine:

```bash
cp config/profiles/amd64-23.0-desktop-plasma-openrc/package.use/20-steam-multilib \
   /etc/portage/package.use/
emerge --ask --update --deep --newuse --getbinpkg games-util/steam-launcher
```

The binhost builds the same set (tier
[`25-steam-runtime`](../packages/tiers/25-steam-runtime.txt)), so those
libraries arrive as binaries.  Steam itself is not built here: it is in an
overlay and its licence does not allow redistribution.

The file is part of the configuration every package here is built with.
The libraries in it (Mesa, glib, fontconfig, the X libraries, one LLVM slot,
...) are therefore only published with 32-bit support, and **a machine needs
the file to get binaries for them even if it does not use Steam**.  Without
it, Portage ignores those binaries and compiles the packages.

Setting `abi_x86_32` globally (`ABI_X86="64 32"`) would also work, but it
rebuilds every library that can be built for 32 bit, every installed LLVM
slot among them, for no benefit.  The list names slots where it matters:
only the LLVM slot Mesa is built against gets a 32-bit build.

## When Gentoo changes a dependency

A new 32-bit dependency shows up in two places: `emerge steam-launcher` asks
for another `abi_x86_32` on the machine, and the `steam-runtime` tier stops
resolving, which the build reports in its alert issue.

Regenerate the list (the command asks Portage, inside a container, what the
tier's packages need):

```bash
podman run --rm --privileged \
  -v "$PWD":/repo:ro -v "$PWD/config/profiles/amd64-23.0-desktop-plasma-openrc/package.use":/out \
  docker.io/gentoo/stage3:amd64-desktop-openrc \
  bash /repo/scripts/use-closure.sh /repo/packages/tiers/25-steam-runtime.txt \
       /out/20-steam-multilib 20-steam-multilib
```

Commit the result and copy it to the machines again.

If the steam-launcher ebuild itself starts to require another library, add
it to `packages/tiers/25-steam-runtime.txt` with the USE flags from the
ebuild first.
