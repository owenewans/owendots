const std = @import("std");

pub const Firmware = enum { uefi, bios };
pub const Filesystem = enum { fat32, ext4, xfs, f2fs };
pub const Partition = struct {
    start_mib: u64,
    size_mib: u64,
    filesystem: Filesystem,
    mount: []const u8,
};
pub const Layout = struct {
    disk: []const u8,
    bytes: u64,
    sector_size: u64,
    firmware: Firmware,
    partitions: []const Partition,

    pub fn validate(l: Layout) !void {
        if (!std.mem.startsWith(u8, l.disk, "/dev/") or std.mem.indexOf(u8, l.disk, "..") != null) return error.InvalidDisk;
        for (l.disk) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '/' and ch != '_' and ch != '-') return error.InvalidDisk;
        if (l.sector_size != 512 and l.sector_size != 4096) return error.UnsupportedSectorSize;
        if (l.partitions.len < 2 or l.partitions.len > (if (l.firmware == .bios) @as(usize, 4) else 128)) return error.InvalidPartitionCount;
        var root = false;
        var boot = false;
        for (l.partitions, 0..) |part, i| {
            if (part.start_mib < 1 or part.size_mib < 64) return error.PartitionTooSmall;
            const end = std.math.add(u64, part.start_mib, part.size_mib) catch return error.PartitionOutsideDisk;
            if (end > l.bytes / (1024 * 1024) -| 1) return error.PartitionOutsideDisk;
            if (l.firmware == .bios and end > (@as(u64, std.math.maxInt(u32)) + 1) / (1024 * 1024 / l.sector_size)) return error.MbrAddressLimit;
            const expected_boot = if (l.firmware == .uefi) "/boot/efi" else "/boot/limine";
            if (std.mem.eql(u8, part.mount, "/")) {
                root = true;
                if (part.filesystem == .fat32 or part.size_mib < 4096) return error.InvalidRootFilesystem;
            } else if (std.mem.eql(u8, part.mount, expected_boot)) {
                boot = true;
                if (part.filesystem != .fat32) return error.BootMustBeFat32;
            } else if (std.mem.eql(u8, part.mount, "/home")) {
                if (part.filesystem == .fat32) return error.InvalidHomeFilesystem;
            } else return error.UnsupportedMountPoint;
            for (l.partitions[0..i]) |other| {
                if (std.mem.eql(u8, part.mount, other.mount)) return error.DuplicateMountPoint;
                if (part.start_mib < other.start_mib + other.size_mib and other.start_mib < end) return error.OverlappingPartitions;
            }
        }
        if (!root or !boot) return error.MissingRequiredMount;
    }

    pub fn script(l: Layout, a: std.mem.Allocator) ![]const u8 {
        try l.validate();
        var output: std.Io.Writer.Allocating = .init(a);
        errdefer output.deinit();
        try output.writer.print("label: {s}\nunit: sectors\n\n", .{if (l.firmware == .uefi) "gpt" else "dos"});
        for (l.partitions) |part| {
            const fat = part.filesystem == .fat32;
            const kind = if (l.firmware == .uefi) (if (fat) "U" else "L") else (if (fat) "c" else "83");
            try output.writer.print("start={d}, size={d}, type={s}{s}\n", .{
                part.start_mib * (1024 * 1024 / l.sector_size),
                part.size_mib * (1024 * 1024 / l.sector_size),
                kind,
                if (l.firmware == .bios and fat) ", bootable" else "",
            });
        }
        return output.toOwnedSlice();
    }

    pub fn device(l: Layout, a: std.mem.Allocator, index: usize) ![]const u8 {
        if (index >= l.partitions.len or l.disk.len == 0) return error.InvalidPartition;
        return std.fmt.allocPrint(a, "{s}{s}{d}", .{ l.disk, if (std.ascii.isDigit(l.disk[l.disk.len - 1])) "p" else "", index + 1 });
    }
};

test "manual GPT layout uses a FAT ESP and preserves explicit offsets" {
    const a = std.testing.allocator;
    const l: Layout = .{ .disk = "/dev/nvme0n1", .bytes = 64 * 1024 * 1024 * 1024, .sector_size = 512, .firmware = .uefi, .partitions = &.{
        .{ .start_mib = 1, .size_mib = 1024, .filesystem = .fat32, .mount = "/boot/efi" },
        .{ .start_mib = 1025, .size_mib = 16000, .filesystem = .ext4, .mount = "/" },
        .{ .start_mib = 18000, .size_mib = 40000, .filesystem = .xfs, .mount = "/home" },
    } };
    const plan = try l.script(a);
    defer a.free(plan);
    try std.testing.expect(std.mem.indexOf(u8, plan, "start=2048, size=2097152, type=U") != null);
    const name = try l.device(a, 1);
    defer a.free(name);
    try std.testing.expectEqualStrings("/dev/nvme0n1p2", name);
}

test "reject overlapping partitions and non-FAT boot" {
    var parts = [_]Partition{
        .{ .start_mib = 1, .size_mib = 1024, .filesystem = .fat32, .mount = "/boot/limine" },
        .{ .start_mib = 512, .size_mib = 8192, .filesystem = .ext4, .mount = "/" },
    };
    const l: Layout = .{ .disk = "/dev/vda", .bytes = 32 * 1024 * 1024 * 1024, .sector_size = 512, .firmware = .bios, .partitions = &parts };
    try std.testing.expectError(error.OverlappingPartitions, l.validate());
    parts[1].start_mib = 1025;
    parts[0].filesystem = .ext4;
    try std.testing.expectError(error.BootMustBeFat32, l.validate());
}
