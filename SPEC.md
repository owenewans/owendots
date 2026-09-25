# Delivery status

Target: Slackware64-current, x86_64. This file records implementation and evidence;
unchecked work is not a completed feature.

- [ ] holypkg: Artix and Arch repository providers and pacman conversion
- [ ] holypkg: Debian/Ubuntu, Fedora/openSUSE, GitHub/URL providers
- [ ] holypkg: signature verification, staging, scripts, ELF and collisions
- [ ] holypkg: native Slackware recipes and GitHub releases
- [ ] owendots: manual partition TUI and Slackware-current installation
- [ ] owendots: UEFI/GPT and BIOS/MBR with FAT-resident Limine boot assets
- [ ] owendots: users, doas, networking, SSH and per-user USB import
- [ ] owendots: post-boot deployment and application selection
- [ ] owendots: palette generation and Zig/Raygui control application
- [ ] owendots: Niri/scroll desktop and application configurations
- [ ] Podman integration tests on Slackware-current
- [ ] QEMU installation, boot, desktop, kernel update and recovery tests
- [ ] English documentation, release artifacts and two running VM windows

## Agreed constraints

Two public repositories: owenewans/holypkg and owenewans/owendots. New code uses
Unlicense; third-party notices remain intact. The old installer is a reference,
not code to relicense. No changes to the host desktop or host disk layout.

holypkg orchestrates Unix tools in Zig, creates ordinary pkgtools packages and
never resolves dependencies, executes foreign scripts, or creates an installed
package database. Providers are explicit. Artix and Arch share a format parser,
not repository identity. Testing repositories require an option. Preserve
provenance, source scripts and metadata. Require explicit generic archive layout.

Install from Ventoy/current media into manually specified partitions. ext4 is
the initial filesystem choice; XFS/F2FS are supported for root/home. UEFI/GPT
uses a FAT32 ESP for kernels/initramfs; BIOS/MBR uses FAT32 /boot/limine. The ordinary /boot stays on the root
filesystem so native kernel packages can create their symlinks. Preserve the
previous kernel and matching initramfs. No LUKS/LVM/RAID, automatic partitioning,
configuration export, or disk swap. Use zram. Require a root password.

After installation, run owendots to select applications, update and deploy the
desktop. en_US.UTF-8, UTC, Fish/Starship for users, Bash for root, NetworkManager,
PipeWire/WirePlumber, Ly, Niri with scroll alternative. Single monitor configured
in the control menu; US/RU on Caps Lock; no effects, auto-lock or idle blanking.
Ghostty toast notifications disabled, Foot alternative. Browser and Telegram
choices are explicit and may select both. Palette drives supported application
colors. Clipboard history persists; region screenshots go to clipboard.

Per-user private SSH keys and USB files are selected separately. Copy data into
~/Data/usb, preserve symlinks/modes, assign the target user, rename collisions.
Root console login stays enabled; SSH policy is selected during setup.

CI uses GitHub-hosted runners with Slackware build environments. Publish native
.txz on GitHub Releases. Test fixtures and real provider packages are both needed.
Final local VMs use root/root and owenewans/owenewans (test images only), NAT and
localhost SSH. Record logs/screenshots. Virtual hardware tests do not establish
physical RTX 3050, modem or Bluetooth correctness.

## Research references

- zarazaex69/l: 3d81619fa7e5b0442345aef3ce6124ff1175d56f
- zarazaex69/s: 306977b1a31e7d89bf18c58340e87bb9edb58bb5
- owenewans/owenslackinstall: 851e11eedfec387a01ea2172d25e7e6ff4008976
- Ghostty supports app-notifications=false; this does not remove GTK libraries.
- Current OpenDoas PAM code hardcodes persist to 300 seconds; configurable
  duration uses our native OpenDoas patch, with expiry and file-safety tests.
- Limine reads FAT12/16/32 and ISO9660. Do not put its Linux boot assets on ext4.

## Validation checkpoint, 2026-09-25

| scenario | evidence |
| --- | --- |
| module tests | 11 passed in Slackware-current under Podman |
| BIOS/MBR, ext4 root and home | installation completed in 256.4 s; Limine disk boot and root console login passed |
| UEFI/GPT, XFS root and ext4 home | installation completed in 274.8 s; ISO and installed ESP boot passed |
| fresh UEFI networking | NetworkManager DHCP, HTTPS, hostname and shared-memory mount passed |
| accounts | Fish user login, wheel membership and doas password reuse passed |
| native packages | [GitHub CI](https://github.com/owenewans/holypkg/actions/runs/36089550710) passed RPM verification, doas cache tests and Limine build |

The first BIOS test exposed missing base libraries and network startup files.
Those packages were added before the clean UEFI test. QEMU tests add a serial
getty and serial kernel console for observation. The firmware boots Limine
from the installed disk during the boot check.

`tests/vm.py` drives the real TUI over a QEMU UNIX serial socket. It requires a
32 GiB disposable `/dev/vda` and the explicit `--erase-qemu-vda` flag. Its
root/root and owenewans/owenewans credentials are test fixtures only.

F2FS, the rest of the firmware/filesystem matrix, Ventoy, desktop sessions,
kernel updates and the two final interactive VM windows remain open.
