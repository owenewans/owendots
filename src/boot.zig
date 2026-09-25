const std = @import("std");
const sys = @import("sys.zig");
const storage = @import("storage.zig");

pub const Options = struct {
    target: []const u8,
    firmware: storage.Firmware,
    uuid: []const u8,
    filesystem: storage.Filesystem,
    version: []const u8,
    disk: []const u8,
};

pub fn install(c: sys.Context, o: Options) !void {
    if (std.mem.eql(u8, try c.absolute(o.target), "/")) return error.TargetIsHostRoot;
    try stage(c, o, true);
}

pub fn refresh(c: sys.Context, version: []const u8) !void {
    if (!std.mem.eql(u8, std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return c.run(&.{ "doas", "/usr/bin/owendots", "kernel", version });
    _ = try c.read("/etc/slackware-version");
    _ = try @import("media.zig").parse(c, try c.read("/var/lib/owendots/media.json"));
    if (!sys.safeName(version)) return error.InvalidKernelVersion;
    _ = try std.Io.Dir.cwd().statFile(c.io, try c.fmt("/lib/modules/{s}", .{version}), .{});
    const uuid = std.mem.trim(u8, try c.capture(&.{ "findmnt", "-n", "-o", "UUID", "--target", "/" }), "\r\n");
    const fs = std.mem.trim(u8, try c.capture(&.{ "findmnt", "-n", "-o", "FSTYPE", "--target", "/" }), "\r\n");
    const filesystem = std.meta.stringToEnum(storage.Filesystem, fs) orelse return error.UnsupportedRootFilesystem;
    const efi = std.Io.Dir.cwd().statFile(c.io, "/sys/firmware/efi", .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    try stage(c, .{ .target = "/", .firmware = if (efi != null) .uefi else .bios, .uuid = uuid, .filesystem = filesystem, .version = version, .disk = "" }, false);
    try c.print("Updated Limine kernel assets for {s}. Existing kernel packages and modules were retained.\n", .{version});
}

fn stage(c: sys.Context, o: Options, loader: bool) !void {
    // validate all strings used in boot configuration before producing files.
    _ = try render(c.a, o.uuid, o.version, null);
    if (o.filesystem == .fat32) return error.InvalidRootFilesystem;
    const target = try c.absolute(o.target);
    const mount = if (o.firmware == .uefi) "/boot/efi" else "/boot/limine";
    const fat = try c.fmt("{s}{s}", .{ target, mount });
    const fs = std.mem.trim(u8, try c.capture(&.{ "findmnt", "-n", "-o", "FSTYPE", "--mountpoint", fat }), "\r\n");
    if (!std.mem.eql(u8, fs, "vfat")) return error.BootMustBeMountedFat32;
    const assets = try c.fmt("{s}/owendots", .{fat});
    try std.Io.Dir.cwd().createDirPath(c.io, assets);
    const current_path = try c.fmt("{s}/current", .{assets});
    const current_text = c.read(current_path) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const current = std.mem.trim(u8, current_text, "\r\n");
    const previous_path = try c.fmt("{s}/previous", .{assets});
    const previous_text = c.read(previous_path) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const stored_previous = std.mem.trim(u8, previous_text, "\r\n");
    const previous: ?[]const u8 = if (current.len > 0 and !std.mem.eql(u8, current, o.version)) current else if (stored_previous.len > 0 and !std.mem.eql(u8, stored_previous, o.version)) stored_previous else null;
    if (previous) |version| {
        if (!sys.safeName(version)) return error.InvalidPreviousKernel;
        for ([_][]const u8{ try c.fmt("vmlinuz-{s}", .{version}), try c.fmt("initramfs-{s}.img", .{version}) }) |name| {
            const file = try std.Io.Dir.cwd().openFile(c.io, try c.fmt("{s}/{s}", .{ assets, name }), .{});
            file.close(c.io);
        }
    }
    var modules: std.Io.Writer.Allocating = .init(c.a);
    const needed = [_][]const u8{ "nvme", "ahci", "sd_mod", "usb_storage", "uas", "virtio_pci", "virtio_blk", "virtio_scsi", "xhci_pci", @tagName(o.filesystem) };
    for (needed) |name| {
        const info = c.capture(&.{ "chroot", target, "/sbin/modinfo", "-k", o.version, "-F", "filename", name }) catch continue;
        if (std.mem.indexOf(u8, info, "(builtin)") != null) continue;
        if (modules.written().len > 0) try modules.writer.writeByte(':');
        try modules.writer.writeAll(name);
    }
    const initrd = try c.fmt("{s}/owendots/initramfs-{s}.img.part", .{ mount, o.version });
    try c.run(&.{ "chroot", target, "/sbin/mkinitrd", "-c", "-k", o.version, "-f", @tagName(o.filesystem), "-r", try c.fmt("UUID={s}", .{o.uuid}), "-m", modules.written(), "-u", "-w", "5", "-s", "/var/lib/owendots/initramfs-tree", "-o", initrd });
    const kernel = try c.fmt("{s}/vmlinuz-{s}", .{ assets, o.version });
    try c.run(&.{ "cp", "--", try c.fmt("{s}/boot/vmlinuz-{s}", .{ target, o.version }), try c.fmt("{s}.part", .{kernel}) });
    try c.run(&.{ "mv", "--", try c.fmt("{s}.part", .{kernel}), kernel });
    try c.run(&.{ "mv", "--", try c.fmt("{s}{s}", .{ target, initrd }), try c.fmt("{s}/initramfs-{s}.img", .{ assets, o.version }) });
    const config = try c.fmt("{s}/limine.conf", .{fat});
    try c.write(try c.fmt("{s}.part", .{config}), try render(c.a, o.uuid, o.version, previous));
    try c.run(&.{ "mv", "--", try c.fmt("{s}.part", .{config}), config });
    if (loader and o.firmware == .uefi) {
        const directory = try c.fmt("{s}/EFI/BOOT", .{fat});
        try std.Io.Dir.cwd().createDirPath(c.io, directory);
        try c.run(&.{ "cp", "--", try c.fmt("{s}/usr/share/limine/BOOTX64.EFI", .{target}), try c.fmt("{s}/BOOTX64.EFI", .{directory}) });
    } else if (loader) {
        try c.run(&.{ "cp", "--", try c.fmt("{s}/usr/share/limine/limine-bios.sys", .{target}), try c.fmt("{s}/limine-bios.sys", .{fat}) });
        try c.run(&.{ "chroot", target, "/usr/bin/limine", "bios-install", o.disk });
    }
    try c.write(current_path, try c.fmt("{s}\n", .{o.version}));
    if (previous) |version| try c.write(previous_path, try c.fmt("{s}\n", .{version}));
    try c.run(&.{ "sync", "-f", fat });
}

pub fn render(a: std.mem.Allocator, uuid: []const u8, current: []const u8, previous: ?[]const u8) ![]const u8 {
    if (uuid.len == 0 or uuid.len > 64) return error.InvalidRootUuid;
    for (uuid) |ch| if (!std.ascii.isHex(ch) and ch != '-') return error.InvalidRootUuid;
    if (!sys.safeName(current)) return error.InvalidKernelVersion;
    if (previous) |p| {
        if (!sys.safeName(p) or std.mem.eql(u8, current, p)) return error.InvalidPreviousKernel;
    }
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    try output.writer.writeAll("timeout: 5\ninterface_branding: owendots\n\n");
    try entry(&output.writer, "Slackware-current", uuid, current);
    if (previous) |p| try entry(&output.writer, "Slackware-current (previous kernel)", uuid, p);
    return output.toOwnedSlice();
}

fn entry(out: *std.Io.Writer, title: []const u8, uuid: []const u8, version: []const u8) !void {
    try out.print(
        \\/{s}
        \\    protocol: linux
        \\    path: boot():/owendots/vmlinuz-{s}
        \\    module_path: boot():/owendots/initramfs-{s}.img
        \\    cmdline: root=UUID={s} rw consoleblank=0
        \\
        \\
    , .{ title, version, version, uuid });
}

test "Limine configuration rejects injected command lines" {
    try std.testing.expectError(error.InvalidRootUuid, render(std.testing.allocator, "abc rw init=/bin/sh", "7.2.7", null));
    try std.testing.expectError(error.InvalidKernelVersion, render(std.testing.allocator, "abc-def", "7.2\nprotocol: efi", null));
    try std.testing.expectError(error.InvalidPreviousKernel, render(std.testing.allocator, "abc-def", "7.2.7", "7.2.7"));
}
