const std = @import("std");
const sys = @import("sys.zig");
const tui = @import("tui.zig");
const Context = sys.Context;

pub const Package = struct {
    name: []const u8,
    file: []const u8,
    sha256: []const u8,
    source: ?[]const u8,
    role: enum { base, desktop },
};
pub const Manifest = struct {
    schema: u32,
    distribution: []const u8,
    architecture: []const u8,
    kernel: []const u8,
    packages: []const Package,
};
pub const Prepared = struct { manifest: Manifest, paths: []const []const u8 };

pub fn parse(c: Context, text: []const u8) !Manifest {
    const parsed = try std.json.parseFromSlice(Manifest, c.a, text, .{ .allocate = .alloc_always });
    const manifest = parsed.value;
    if (manifest.schema != 1 or !std.mem.eql(u8, manifest.distribution, "slackware64-current") or !std.mem.eql(u8, manifest.architecture, "x86_64")) return error.UnsupportedMedia;
    if (!sys.safeName(manifest.kernel) or manifest.packages.len == 0) return error.InvalidManifest;
    for (manifest.packages, 0..) |pkg, index| {
        if (!sys.safeName(pkg.name) or !sys.safeName(pkg.file) or !std.mem.endsWith(u8, pkg.file, ".txz")) return error.InvalidPackageFilename;
        if (!std.mem.startsWith(u8, pkg.file, try c.fmt("{s}-", .{pkg.name}))) return error.PackageNameMismatch;
        if (pkg.sha256.len != 64) return error.InvalidChecksum;
        for (pkg.sha256) |ch| if (!std.ascii.isHex(ch)) return error.InvalidChecksum;
        if (pkg.source) |url| {
            if (!std.mem.startsWith(u8, url, "https://")) return error.HttpsRequired;
            for (url) |ch| if (ch <= 32 or ch == 127) return error.InvalidSourceUrl;
        }
        for (manifest.packages[0..index]) |other| {
            if (std.mem.eql(u8, pkg.name, other.name) or std.mem.eql(u8, pkg.file, other.file)) return error.DuplicatePackage;
        }
    }
    return manifest;
}

pub fn prepare(c: Context, medium: []const u8, cache: []const u8) !Prepared {
    const root = try c.absolute(medium);
    const manifest = try parse(c, try c.read(try c.fmt("{s}/manifest.json", .{root})));
    var paths: std.ArrayList([]const u8) = .empty;
    for (manifest.packages) |pkg| {
        var path = try c.fmt("{s}/packages/{s}", .{ root, pkg.file });
        const existing = std.Io.Dir.cwd().statFile(c.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing == null) {
            const url = pkg.source orelse return error.MissingLocalOnlyPackage;
            const answer = try tui.menu(c, try c.fmt("Missing USB package: {s}\nDownload from {s}?", .{ pkg.file, url }), &.{ "download", "Download this exact package", "cancel", "Cancel installation" });
            if (!std.mem.eql(u8, answer, "download")) return error.Cancelled;
            try std.Io.Dir.cwd().createDirPath(c.io, cache);
            path = try c.fmt("{s}/{s}", .{ cache, pkg.file });
            try c.download(url, path);
        } else if (existing.?.kind != .file) return error.PackageMustBeFile;
        if (!std.ascii.eqlIgnoreCase(try c.checksum(path), pkg.sha256)) return error.PackageChecksumMismatch;
        try paths.append(c.a, path);
    }
    return .{ .manifest = manifest, .paths = try paths.toOwnedSlice(c.a) };
}

test "media is current-only and paths and checksums are explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const empty = "{\"schema\":1,\"distribution\":\"slackware64-15.0\",\"architecture\":\"x86_64\",\"kernel\":\"7.2.7\",\"packages\":[]}";
    try std.testing.expectError(error.UnsupportedMedia, parse(c, empty));
    const traversal = "{\"schema\":1,\"distribution\":\"slackware64-current\",\"architecture\":\"x86_64\",\"kernel\":\"7.2.7\",\"packages\":[{\"name\":\"foo\",\"file\":\"../foo.txz\",\"sha256\":\"abc\",\"source\":\"https://example.org/foo.txz\",\"role\":\"base\"}]}";
    try std.testing.expectError(error.InvalidPackageFilename, parse(c, traversal));
}
