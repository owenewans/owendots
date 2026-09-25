<div align="center">

# owendots

slackware-current installer and workstation configuration.

<a href="https://count.owenewans.org/owenewans/owendots?theme=moebooru-h&notitle"><img src="https://count.owenewans.org/owenewans/owendots?theme=moebooru-h&notitle" alt="repository views"></a>

`zig` `desktop` `slackware`

</div>

## features

- manual partition planning for UEFI/GPT and BIOS/MBR with Limine
- ext4, XFS or F2FS for root and an optional separate home partition
- package verification against an explicit Slackware64-current media manifest
- user accounts, doas, SSH settings and private key import
- USB directory import with file modes, symlinks and renamed collision copies
- application configuration templates generated from one palette
- per-user application choices, managed browser profiles and original config backups

Development is in progress. Desktop deployment and the Raygui control program
are unfinished. BIOS/ext4, BIOS/F2FS and UEFI/XFS base installs have booted in QEMU;
the remaining acceptance scenarios are in progress. See
[scope and acceptance requirements](SPEC.md).

## build

Requires Zig 0.16.0:

```sh
zig build test
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
```

The static executable is `zig-out/bin/owendots`. At installation time, use a
Slackware live environment with `dialog`, pkgtools and filesystem utilities.

## usage

Generate application configurations:

```sh
owendots theme generate palette.toml templates ./generated
```

Edit colours in `palette.toml` and application templates in `templates/`.
The generator checks palette keys before writing the output directory.

With the package and applications installed, run as the desktop user:

```sh
owendots configure
owendots theme apply
owendots launch terminal
owendots launch browser
```

`configure` selects launch defaults and applies templates; it does not install
applications. Edit `~/.config/owendots/palette.toml` and run `theme apply` to
regenerate colors. The first existing configuration is saved under
`~/.config/owendots/backup/`. Firefox and Pale Moon use managed profiles under
`~/.config/owendots/`; existing browser profiles remain separate.

`launch` also accepts `files`, `telegram`, `monitor` and `editor`, followed by
literal application arguments. `screenshot` copies a selected region, and
`clipboard` selects persistent cliphist entries through Walker.

From the prepared live environment, start the installer as root:

```sh
owendots install /media/owendots
```

Choose the disk, partition offsets, filesystems, hostname and accounts. Review
the complete plan and enter the target disk's full path before writing.
Installation erases the selected disk. Test development builds in disposable
QEMU machines.

## media

Prepare the package directory on the development machine:

```sh
python3 tools/media.py --output ./media
```

The tool downloads the packages listed in `profiles/base.txt`, checks the
Slackware signing key and signed checksums, then records each package's SHA-256.
It creates a package directory, not a bootable ISO.

Supply native packages with `--native-manifest`: a JSON list beside the package
files, with `name`, `file`, `sha256`, `source` and `role` (`base` or `desktop`).
Use the published HTTPS download URL for `source`, or `null` for a local-only
package. Missing local-only packages stop installation.

Assemble the ISO from the matching current installer kernel/initrd and Limine
binary release directory:

```sh
python3 tools/iso.py --media ./media --live-base ./live-base \
  --limine ./limine-binary --binary zig-out/bin/owendots \
  --work ./iso-work --output ./owendots.iso
```

`live-base` contains `initrd.img` from `isolinux/initrd.img` and `vmlinuz` from
`kernels/generic.s/bzImage` on the same current mirror. The builder verifies
both against the signed media checksums. It requires `bsdtar`, `xz`, GnuPG and
`xorriso`, and writes an image file without mounting host disks. Use
`--serial-console` to select the serial boot entry for QEMU tests.

Build recipes and foreign package conversion live in
[holypkg](https://github.com/owenewans/holypkg). Installed packages remain under
Slackware pkgtools.

## boot layout

| mode | partition table | boot files |
| --- | --- | --- |
| UEFI | GPT | FAT32 at `/boot/efi` |
| BIOS | MBR | FAT32 at `/boot/limine` |

Keep ordinary `/boot` on the root filesystem for Slackware's kernel symlinks.
The installer copies the kernel and initramfs to FAT for Limine. See
[Limine's installation requirements](https://github.com/Limine-Bootloader/Limine/blob/trunk/USAGE.md).

## validation

Module tests have passed in Slackware-current under Podman, including manual
layouts, media checks, repeated target configuration and USB copy behaviour.
BIOS/MBR with ext4 and UEFI/GPT with XFS have passed base installation and
Limine disk boot. The UEFI test also passed DHCP, HTTPS, user password login
and root key login. BIOS/F2FS passed disk boot, DHCP, zram and user locale checks.
Container tests cover palette rejection, config backups, managed browser
profiles and literal launch arguments. Desktop, kernel updates, Ventoy and the remaining
filesystem cases still need acceptance.

## license

[Unlicense](LICENSE). The old
[owenslackinstall](https://github.com/owenewans/owenslackinstall) is a design
reference; its GPL implementation is not included.
