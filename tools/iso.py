#!/usr/bin/env python3
"""Assemble a current installer ISO without mounting or writing host disks."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--media', type=pathlib.Path, required=True)
parser.add_argument('--live-base', type=pathlib.Path, required=True)
parser.add_argument('--limine', type=pathlib.Path, required=True)
parser.add_argument('--binary', type=pathlib.Path, required=True)
parser.add_argument('--work', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--serial-console', action='store_true', help='select the serial-console boot entry for QEMU tests')
args = parser.parse_args()
for key, value in vars(args).items():
    if isinstance(value, pathlib.Path):
        setattr(args, key, value.resolve())
if args.work.exists() or args.output.exists():
    raise SystemExit('work and output must not exist')


def run(*argv, **kw):
    return subprocess.run([str(arg) for arg in argv], check=True, **kw)


# Verify the signing key again instead of trusting a replaced media keyring.
metadata = args.media / 'metadata'
listing = run('gpg', '--batch', '--with-colons', '--show-keys', metadata / 'slackware.gpg', capture_output=True, text=True).stdout
primaries = []
primary = False
for line in listing.splitlines():
    if line.startswith('pub:'):
        primary = True
    elif primary and line.startswith('fpr:'):
        primaries.append(line.split(':')[9])
        primary = False
if primaries != ['EC5649DA401E22ABFA6736EF6A4463C040102233']:
    raise SystemExit('unexpected Slackware signing key')
run('gpgv', '--keyring', metadata / 'slackware.gpg', metadata / 'CHECKSUMS.md5.asc', metadata / 'CHECKSUMS.md5')
checksums = {}
for line in (metadata / 'CHECKSUMS.md5').read_text().splitlines():
    match = re.match(r'^([a-f0-9]{32})\s+\*?(?:\./)?(.+)$', line)
    if match:
        checksums[match[2]] = match[1]
for filename, remote in [('initrd.img', 'isolinux/initrd.img'), ('vmlinuz', 'kernels/generic.s/bzImage')]:
    if hashlib.md5((args.live_base / filename).read_bytes()).hexdigest() != checksums[remote]:
        raise SystemExit('live source differs from signed current snapshot: ' + filename)

iso = args.work / 'iso'
overlay = args.work / 'overlay'
for directory in [iso / 'boot/limine', iso / 'EFI/BOOT', overlay / 'usr/bin', overlay / 'etc', overlay / 'run']:
    directory.mkdir(parents=True, exist_ok=True)
shutil.copy2(args.binary, overlay / 'usr/bin/owendots')
(overlay / 'run/owendots-live').write_text('slackware64-current\n')
# Install the full runtime tools after boot; the stock installer uses BusyBox.
manifest = json.loads((args.media / 'manifest.json').read_text())
live_names = ['aaa_libraries', 'openssl-solibs', 'brotli', 'libidn2', 'libunistring',
              'libpsl', 'cyrus-sasl', 'nghttp2', 'nghttp3', 'ngtcp2', 'libssh2', 'zstd', 'curl',
              'coreutils', 'findutils', 'util-linux', 'perl', 'openssl', 'dcron', 'ca-certificates']
live_files = []
for name in live_names:
    package = next(p for p in manifest['packages'] if p['name'] == name)
    filename = package['file']
    if pathlib.Path(filename).name != filename:
        raise SystemExit('invalid package filename')
    if hashlib.sha256((args.media / 'packages' / filename).read_bytes()).hexdigest() != package['sha256']:
        raise SystemExit('live package checksum mismatch: ' + name)
    live_files.append(filename)
(overlay / 'etc/owendots-live-packages').write_text('\n'.join(live_files) + '\n')
(overlay / 'etc/owendots-live-checksums').write_text(''.join(
    next(p['sha256'] for p in manifest['packages'] if p['file'] == name) + '  ' + name + '\n'
    for name in live_files))
# Keep Slackware's initialization intact. The wrapper supplies its fake login.
(overlay / 'usr/bin/owendots-live-init').write_text('''#!/bin/sh
printf 'root\\n' | /etc/rc.d/rc.S
mkdir -p /run /media/owendots
printf 'slackware64-current\\n' > /run/owendots-live
udevadm settle
for device in /dev/sr* /dev/disk/by-label/OWENDOTS; do
  [ -b "$device" ] || continue
  if mount -o ro "$device" /media/owendots; then
    [ -f /media/owendots/manifest.json ] && break
    umount /media/owendots
  fi
done
if [ -f /media/owendots/manifest.json ]; then
  cd /media/owendots/packages || exit 1
  sha256sum -c /etc/owendots-live-checksums || exit 1
  while read -r package; do
    installpkg "$package" || exit 1
  done < /etc/owendots-live-packages
  ldconfig
  update-ca-certificates
  cd /
fi
dhcpcd -b -t 15 >/var/log/owendots-dhcp.log 2>&1
printf '\\nRun: owendots install /media/owendots\\n'
''')
(overlay / 'usr/bin/owendots-live-init').chmod(0o755)
(overlay / 'etc/inittab').write_text('''::sysinit:/usr/bin/owendots-live-init
::respawn:-/bin/sh
tty2::askfirst:-/bin/sh
tty3::askfirst:-/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
''')
archive = args.work / 'overlay.cpio'
run('bsdtar', '--format=newc', '--uid', '0', '--gid', '0', '-cf', archive, '-C', overlay, '.')
# Linux accepts concatenated compressed cpio archives. Preserve original nodes.
with (iso / 'boot/initrd.img').open('wb') as output:
    with (args.live_base / 'initrd.img').open('rb') as original:
        shutil.copyfileobj(original, output)
    run('xz', '--check=crc32', '-c', archive, stdout=output)
shutil.copy2(args.live_base / 'vmlinuz', iso / 'boot/vmlinuz')
for filename in ['limine-bios.sys', 'limine-bios-cd.bin', 'limine-uefi-cd.bin']:
    shutil.copy2(args.limine / filename, iso / 'boot/limine' / filename)
shutil.copy2(args.limine / 'LICENSE', iso / 'boot/limine/LICENSE')
shutil.copy2(pathlib.Path(__file__).resolve().parent.parent / 'LICENSE', iso / 'LICENSE.owendots')
shutil.copy2(args.limine / 'BOOTX64.EFI', iso / 'EFI/BOOT/BOOTX64.EFI')
(iso / 'boot/limine/limine.conf').write_text('''timeout: 3

/owendots Slackware64-current installer
    protocol: linux
    path: boot():/boot/vmlinuz
    module_path: boot():/boot/initrd.img
    cmdline: rw kbd=us consoleblank=0

/owendots installer (serial console)
    protocol: linux
    path: boot():/boot/vmlinuz
    module_path: boot():/boot/initrd.img
    cmdline: rw kbd=us console=ttyS0,115200 consoleblank=0
''')
if args.serial_console:
    config = iso / 'boot/limine/limine.conf'
    config.write_text('default_entry: 2\nserial: yes\n' + config.read_text())
shutil.copytree(args.media, iso, dirs_exist_ok=True)
args.output.parent.mkdir(parents=True, exist_ok=True)
run('xorriso', '-as', 'mkisofs', '-R', '-J', '-V', 'OWENDOTS',
    '-b', 'boot/limine/limine-bios-cd.bin', '-no-emul-boot', '-boot-load-size', '4', '-boot-info-table',
    '--efi-boot', 'boot/limine/limine-uefi-cd.bin', '-efi-boot-part', '--efi-boot-image',
    '--protective-msdos-label', iso, '-o', args.output)
run(args.limine / 'limine', 'bios-install', args.output)
print('Created', args.output)
