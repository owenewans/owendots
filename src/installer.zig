const std = @import("std");
const sys = @import("sys.zig");
const tui = @import("tui.zig");
const storage = @import("storage.zig");
const media = @import("media.zig");
const system = @import("system.zig");
const data = @import("data.zig");
const boot = @import("boot.zig");
const Context = sys.Context;

const Disk = struct { path: []const u8, model: []const u8, serial: []const u8, bytes: u64, sector: u64 };
const User = struct { name: []const u8, secret: []const u8, wheel: bool, keys: []const []const u8, usb: ?[]const u8 };

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
fn jsonText(v: std.json.Value, name: []const u8) []const u8 {
    const field = v.object.get(name) orelse return "";
    return if (field == .string) trim(field.string) else "";
}
fn jsonNumber(v: std.json.Value, name: []const u8) !u64 {
    const field = v.object.get(name) orelse return error.InvalidDiskMetadata;
    if (field != .integer or field.integer < 0) return error.InvalidDiskMetadata;
    return @intCast(field.integer);
}
fn disks(c: Context) ![]Disk {
    const raw = try c.capture(&.{ "lsblk", "--json", "--bytes", "--nodeps", "--output", "PATH,MODEL,SERIAL,SIZE,LOG-SEC,TYPE,RO" });
    const parsed = try std.json.parseFromSlice(std.json.Value, c.a, raw, .{ .allocate = .alloc_always });
    const devices = parsed.value.object.get("blockdevices") orelse return error.InvalidDiskMetadata;
    var result: std.ArrayList(Disk) = .empty;
    for (devices.array.items) |item| {
        if (!same(jsonText(item, "type"), "disk")) continue;
        const path = jsonText(item, "path");
        if (std.mem.startsWith(u8, path, "/dev/zram") or std.mem.startsWith(u8, path, "/dev/ram") or std.mem.startsWith(u8, path, "/dev/fd")) continue;
        if (try jsonNumber(item, "size") < 4 * 1024 * 1024 * 1024) continue;
        const ro = item.object.get("ro") orelse return error.InvalidDiskMetadata;
        if (ro == .bool and ro.bool) continue;
        if (ro == .integer and ro.integer != 0) continue;
        try result.append(c.a, .{ .path = jsonText(item, "path"), .model = jsonText(item, "model"), .serial = jsonText(item, "serial"), .bytes = try jsonNumber(item, "size"), .sector = try jsonNumber(item, "log-sec") });
    }
    return result.toOwnedSlice(c.a);
}
fn unusedDisk(c: Context, disk: Disk) !void {
    const mounts = try c.capture(&.{ "lsblk", "--noheadings", "--raw", "--output", "MOUNTPOINTS", disk.path });
    if (trim(mounts).len != 0) return error.DiskHasMountedPartitions;
    const devices = try c.capture(&.{ "lsblk", "--noheadings", "--raw", "--output", "PATH", disk.path });
    const swaps = try c.capture(&.{ "swapon", "--noheadings", "--raw", "--show=NAME" });
    var lines = std.mem.splitScalar(u8, devices, '\n');
    while (lines.next()) |device| {
        var swap_lines = std.mem.splitScalar(u8, swaps, '\n');
        while (swap_lines.next()) |swap| if (device.len > 0 and same(device, swap)) return error.DiskHasActiveSwap;
    }
    var found = false;
    for (try disks(c)) |current| {
        if (same(current.path, disk.path)) {
            found = true;
            if (current.bytes != disk.bytes or current.sector != disk.sector or !same(current.serial, disk.serial) or !same(current.model, disk.model)) return error.DiskIdentityChanged;
        }
    }
    if (!found) return error.DiskRemoved;
}
fn number(c: Context, question: []const u8) !u64 {
    return std.fmt.parseInt(u64, trim(try tui.input(c, question, "")), 10);
}
fn layout(c: Context, disk: Disk, firmware: storage.Firmware) !storage.Layout {
    var partitions: std.ArrayList(storage.Partition) = .empty;
    const boot_mount = if (firmware == .uefi) "/boot/efi" else "/boot/limine";
    while (true) {
        var description: std.Io.Writer.Allocating = .init(c.a);
        try description.writer.print("{s}: {d} MiB\nManual layout; no partitions are written yet.\n", .{ disk.path, disk.bytes / (1024 * 1024) });
        for (partitions.items, 1..) |part, i| try description.writer.print("{d}: {s} {s}, start {d} MiB, size {d} MiB\n", .{ i, part.mount, @tagName(part.filesystem), part.start_mib, part.size_mib });
        const action = try tui.menu(c, description.written(), &.{ "add", "Add a partition with explicit offsets", "remove", "Remove one planned partition", "done", "Validate this layout" });
        if (same(action, "done")) {
            const result: storage.Layout = .{ .disk = disk.path, .bytes = disk.bytes, .sector_size = disk.sector, .firmware = firmware, .partitions = partitions.items };
            result.validate() catch |err| {
                _ = try tui.dialog(c, &.{ "--msgbox", try c.fmt("Invalid layout: {s}\nAdjust the planned partitions.", .{@errorName(err)}), "10", "72" });
                continue;
            };
            return result;
        }
        if (same(action, "remove")) {
            const index = try number(c, "Planned partition number to remove");
            if (index == 0 or index > partitions.items.len) return error.InvalidPartition;
            _ = partitions.orderedRemove(@intCast(index - 1));
            continue;
        }
        const mount = try tui.menu(c, "Mount point", &.{ "/", "Root filesystem", boot_mount, "FAT32 boot assets for Limine", "/home", "Separate home filesystem" });
        const fs: storage.Filesystem = if (same(mount, boot_mount)) .fat32 else std.meta.stringToEnum(storage.Filesystem, try tui.menu(c, "Filesystem", &.{ "ext4", "ext4", "xfs", "XFS", "f2fs", "F2FS" })) orelse return error.InvalidFilesystem;
        const offset = try number(c, "Partition start in MiB (explicit, at least 1)");
        const size = try number(c, "Partition size in MiB (explicit)");
        try partitions.append(c.a, .{ .start_mib = offset, .size_mib = size, .filesystem = fs, .mount = mount });
    }
}
fn users(c: Context) ![]User {
    var result: std.ArrayList(User) = .empty;
    while (true) {
        const name = try tui.input(c, if (result.items.len == 0) "First user" else "Next username (empty to finish)", if (result.items.len == 0) "owenewans" else "");
        if (name.len == 0 and result.items.len > 0) return result.toOwnedSlice(c.a);
        if (!system.validUser(name)) return error.InvalidUsername;
        for (result.items) |user| if (same(user.name, name)) return error.DuplicateUser;
        const secret = try tui.password(c, try c.fmt("Password for {s}", .{name}));
        const wheel = result.items.len == 0 or same(try tui.menu(c, "Allow doas through wheel?", &.{ "no", "Regular user", "yes", "Administrator" }), "yes");
        var keys: std.ArrayList([]const u8) = .empty;
        while (true) {
            const path = try tui.input(c, "Private SSH key on USB (empty to finish key selection)", "");
            if (path.len == 0) break;
            try data.validateKey(c, path);
            try keys.append(c.a, try c.absolute(path));
        }
        const source = try tui.input(c, "USB directory to copy into ~/Data/usb (empty to skip)", "");
        const usb: ?[]const u8 = if (source.len == 0) null else try c.absolute(source);
        if (usb) |path| {
            if (same(path, "/")) return error.InvalidImportDirectory;
            const stat = try std.Io.Dir.cwd().statFile(c.io, path, .{});
            if (stat.kind != .directory) return error.InvalidImportDirectory;
        }
        try result.append(c.a, .{ .name = name, .secret = secret, .wheel = wheel, .keys = try keys.toOwnedSlice(c.a), .usb = usb });
    }
}
fn inputCommand(c: Context, argv: []const []const u8, input: []const u8) !void {
    var child = try std.process.spawn(c.io, .{ .argv = argv, .stdin = .pipe });
    defer child.kill(c.io);
    try child.stdin.?.writeStreamingAll(c.io, input);
    child.stdin.?.close(c.io);
    child.stdin = null;
    const result = try child.wait(c.io);
    if (result != .exited or result.exited != 0) return error.CommandFailed;
}
fn execute(c: Context, disk: Disk, plan: storage.Layout, packages: media.Prepared, hostname: []const u8, ssh: system.Ssh, root_secret: []const u8, accounts: []const User, persist_minutes: u64) !void {
    try unusedDisk(c, disk);
    const target = "/mnt/owendots";
    try std.Io.Dir.cwd().createDirPath(c.io, target);
    if (trim(try c.capture(&.{ "find", target, "-mindepth", "1", "-maxdepth", "1", "-print", "-quit" })).len != 0) return error.TargetDirectoryNotEmpty;
    try inputCommand(c, &.{ "sfdisk", "--wipe", "always", "--wipe-partitions", "always", disk.path }, try plan.script(c.a));
    try c.run(&.{ "udevadm", "settle" });
    for (plan.partitions, 0..) |part, i| {
        const device = try plan.device(c.a, i);
        const argv: []const []const u8 = switch (part.filesystem) {
            .fat32 => &.{ "mkfs.fat", "-F", "32", device },
            .ext4 => &.{ "mkfs.ext4", "-F", device },
            .xfs => &.{ "mkfs.xfs", "-f", device },
            .f2fs => &.{ "mkfs.f2fs", "-f", device },
        };
        try c.run(argv);
    }
    var mounted = false;
    defer if (mounted) c.run(&.{ "umount", "-R", target }) catch {};
    var mounts: std.ArrayList(system.Mount) = .empty;
    var root_fs: storage.Filesystem = .ext4;
    var root_uuid: []const u8 = "";
    for (plan.partitions, 0..) |part, i| {
        const device = try plan.device(c.a, i);
        const uuid = try c.a.dupe(u8, trim(try c.capture(&.{ "blkid", "-s", "UUID", "-o", "value", device })));
        try mounts.append(c.a, .{ .uuid = uuid, .path = part.mount, .filesystem = part.filesystem });
        if (same(part.mount, "/")) {
            try c.run(&.{ "mount", device, target });
            mounted = true;
            root_uuid = uuid;
            root_fs = part.filesystem;
        }
    }
    for (plan.partitions, 0..) |part, i| {
        if (same(part.mount, "/")) continue;
        const destination = try c.fmt("{s}{s}", .{ target, part.mount });
        try std.Io.Dir.cwd().createDirPath(c.io, destination);
        try c.run(&.{ "mount", try plan.device(c.a, i), destination });
    }
    for ([_][]const u8{ "/dev", "/proc", "/sys" }) |path| {
        const destination = try c.fmt("{s}{s}", .{ target, path });
        try std.Io.Dir.cwd().createDirPath(c.io, destination);
        try c.run(&.{ "mount", "--rbind", path, destination });
        try c.run(&.{ "mount", "--make-rslave", destination });
    }
    try std.Io.Dir.cwd().createDirPath(c.io, target ++ "/run");
    try c.run(&.{ "mount", "-t", "tmpfs", "tmpfs", target ++ "/run" });
    const cache = try c.fmt("{s}/var/cache/owendots/packages", .{target});
    try std.Io.Dir.cwd().createDirPath(c.io, cache);
    for (packages.manifest.packages, packages.paths) |pkg, path| {
        if (pkg.role == .base) {
            try c.run(&.{ "installpkg", "--root", target, path });
        } else try c.run(&.{ "cp", "--", path, try c.fmt("{s}/{s}", .{ cache, pkg.file }) });
    }
    try c.write(try c.fmt("{s}/var/lib/owendots/media.json", .{target}), try std.json.Stringify.valueAlloc(c.a, packages.manifest, .{ .whitespace = .indent_2 }));
    try c.run(&.{ "chroot", target, "/sbin/ldconfig" });
    try c.run(&.{ "chroot", target, "/usr/sbin/update-ca-certificates" });
    try system.configure(c, target, .{ .hostname = hostname, .ssh = ssh, .mounts = mounts.items });
    try system.password(c, target, "root", root_secret);
    try c.write(try c.fmt("{s}/etc/doas.conf", .{target}), if (persist_minutes == 0) "permit :wheel\n" else "permit persist :wheel\n");
    try c.run(&.{ "chmod", "0600", try c.fmt("{s}/etc/doas.conf", .{target}) });
    try c.write(try c.fmt("{s}/etc/doas-persist.conf", .{target}), try c.fmt("{d}\n", .{persist_minutes * 60}));
    const shells = try c.fmt("{s}/etc/shells", .{target});
    const shell_text = try c.read(shells);
    if (std.mem.indexOf(u8, shell_text, "/usr/bin/fish") == null) try c.write(shells, try c.fmt("{s}\n/usr/bin/fish\n", .{shell_text}));
    for (accounts) |user| {
        try system.addUser(c, target, user.name, user.wheel, user.secret);
        const uid = try std.fmt.parseInt(u32, trim(try c.capture(&.{ "chroot", target, "/usr/bin/id", "-u", user.name })), 10);
        const gid = try std.fmt.parseInt(u32, trim(try c.capture(&.{ "chroot", target, "/usr/bin/id", "-g", user.name })), 10);
        const home = try c.fmt("{s}/home/{s}", .{ target, user.name });
        for (user.keys) |key| try data.importKey(c, key, home, uid, gid);
        if (user.usb) |source| try data.importFiles(c, source, home, uid, gid);
    }
    try boot.install(c, .{ .target = target, .firmware = plan.firmware, .uuid = root_uuid, .filesystem = root_fs, .version = packages.manifest.kernel, .disk = disk.path });
    try c.run(&.{"sync"});
    try c.run(&.{ "umount", "-R", target });
    mounted = false;
}

pub fn start(c: Context, medium: []const u8) !void {
    if (!same(trim(try c.capture(&.{ "id", "-u" })), "0")) return error.RootRequired;
    const marker = try c.read("/run/owendots-live");
    if (!same(trim(marker), "slackware64-current")) return error.OwendotsLiveEnvironmentRequired;
    const work = try c.temp();
    defer std.Io.Dir.cwd().deleteTree(c.io, work) catch {};
    const packages = try media.prepare(c, medium, try c.fmt("{s}/packages", .{work}));
    for ([_][]const u8{ "aaa_base", "pkgtools", "kernel-generic", "mkinitrd", "fish", "owendoas", "limine", "owendots", "holypkg", "network-scripts", "hostname", "mozilla-nss" }) |required| {
        var found = false;
        for (packages.manifest.packages) |pkg| if (same(pkg.name, required) and pkg.role == .base) {
            found = true;
        };
        if (!found) {
            try c.print("Missing required base package: {s}\n", .{required});
            return error.IncompleteInstallationMedia;
        }
    }
    const available = try disks(c);
    if (available.len == 0) return error.NoWritableDisks;
    var choices: std.ArrayList([]const u8) = .empty;
    for (available) |disk| try choices.appendSlice(c.a, &.{ disk.path, try c.fmt("{s} / {s} / {d} MiB", .{ disk.model, disk.serial, disk.bytes / (1024 * 1024) }) });
    const selected = try tui.menu(c, "Target disk (all existing partitions will be replaced)", choices.items);
    var chosen: ?Disk = null;
    for (available) |disk| if (same(disk.path, selected)) {
        chosen = disk;
    };
    const disk = chosen orelse return error.InvalidDisk;
    try unusedDisk(c, disk);
    const mode = try tui.menu(c, "Firmware and partition table", &.{ "uefi", "UEFI / GPT", "bios", "BIOS / MBR" });
    const firmware = std.meta.stringToEnum(storage.Firmware, mode) orelse return error.InvalidFirmware;
    const plan = try layout(c, disk, firmware);
    const hostname = try tui.input(c, "Hostname (FQDN)", "x99.owenewans.org");
    if (!system.validHostname(hostname)) return error.InvalidHostname;
    const root_secret = try tui.password(c, "Root password (required)");
    const accounts = try users(c);
    const ssh = std.meta.stringToEnum(system.Ssh, try tui.menu(c, "SSH server", &.{ "disabled", "Do not start sshd", "keys", "Enable, keys only", "passwords", "Enable, user passwords and keys; root keys only" })) orelse return error.InvalidSshPolicy;
    const persist = try number(c, "doas password cache duration in minutes (0: each command, maximum 1440)");
    if (persist > 1440) return error.InvalidPersistDuration;
    var review: std.Io.Writer.Allocating = .init(c.a);
    try review.writer.print("ERASE {s}\nModel: {s}\nSerial: {s}\nBytes: {d}\n\n{s}\nHostname: {s}\nUTC / en_US.UTF-8\nRoot password: set\nSSH: {s}\ndoas cache: {d} minutes\n\n", .{ disk.path, disk.model, disk.serial, disk.bytes, try plan.script(c.a), hostname, @tagName(ssh), persist });
    try review.writer.print("Existing partitions:\n{s}\nPlanned filesystems:\n", .{try c.capture(&.{ "lsblk", "--output", "PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS", disk.path })});
    for (plan.partitions) |part| try review.writer.print("Format {s}: {s}, start {d} MiB, size {d} MiB\n", .{ part.mount, @tagName(part.filesystem), part.start_mib, part.size_mib });
    for (accounts) |user| {
        try review.writer.print("\nUser: {s}, wheel: {}, password: set\nUSB data: {s}\n", .{ user.name, user.wheel, user.usb orelse "none" });
        for (user.keys) |key| try review.writer.print("Private key source: {s}\n", .{key});
    }
    try review.writer.writeAll("\nPackages:\n");
    for (packages.manifest.packages) |pkg| try review.writer.print("{s}: {s}\n", .{ @tagName(pkg.role), pkg.file });
    const review_path = try c.fmt("{s}/plan.txt", .{work});
    try c.write(review_path, review.written());
    _ = try tui.dialog(c, &.{ "--textbox", review_path, "30", "100" });
    const confirmation = try tui.input(c, "Type the full disk path to erase it and execute this plan", "");
    if (!same(confirmation, disk.path)) return error.ConfirmationMismatch;
    try execute(c, disk, plan, packages, hostname, ssh, root_secret, accounts, persist);
    _ = try tui.dialog(c, &.{ "--msgbox", "Base installation complete. Reboot, log in, and run owendots to select and deploy your desktop.", "10", "76" });
}
