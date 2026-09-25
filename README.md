# owendots

Slackware64-current installer and workstation configuration for owenewans.
New code is Unlicense. The old owenslackinstall repository is a design reference;
its GPL implementation is not included here.

Development is in progress. There is no finished desktop image or release yet.
See [SPEC.md](SPEC.md) for scope and acceptance requirements.

## Build and checks

Requires Zig 0.16.0 on the development machine:

```sh
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
```

The command-line executable is static. Installer runtime tools come from the
Slackware live environment, including dialog, pkgtools and filesystem utilities.
The current modules cover manual partition planning, media verification, target
configuration, user/SSH setup, USB import, Limine boot assets and palette generation.
The installation path still requires QEMU acceptance tests and complete media.

Generate configurations without changing your running desktop:

```sh
owendots theme generate palette.toml templates ./generated
```

Colors come from the palette file. The generator rejects missing and unknown
keys. Application templates are under `templates/`; the desktop deployment and
Raygui control program are still being implemented.

## Installation media

The development-only Python tool downloads exactly the profile's packages,
checks the Slackware key fingerprint and signed checksums, then records SHA-256
for the installer. It does not resolve dependencies.

```sh
python3 tools/media.py --output ./media
```

This creates a package directory, not a bootable ISO. Native packages can be
supplied with `--native-manifest`, a JSON list containing `name`, `file`, `sha256`,
`source` and `role` (`base` or `desktop`), next to the package files. Files must
already have their published HTTPS source URLs and exact checksums.

The installer refuses incomplete media before offering disk changes. It requires
a live environment marker and root, displays the plan, and requires the full disk
path before writing. The source includes disk-writing code; only test it inside
disposable QEMU machines until the acceptance scenarios pass.

Boot layouts:

- UEFI/GPT: FAT32 at `/boot/efi`.
- BIOS/MBR: FAT32 at `/boot/limine`.
- Root and optional separate home: ext4, XFS or F2FS.

The ordinary `/boot` remains on the root filesystem so Slackware kernel packages
can create symlinks. Limine reads copied kernel/initramfs files from the FAT
partition. This follows [Limine's filesystem and installation requirements](https://github.com/Limine-Bootloader/Limine/blob/trunk/USAGE.md).

## Evidence

Eleven module tests passed in a Slackware-current Podman environment, including
USB copy collisions, symlink/mode preservation, repeated target configuration,
identity validation, manual layout validation and media restrictions. This does
not yet establish that the installer boots a target machine. QEMU installation,
boot, desktop and update evidence will be recorded before release.
