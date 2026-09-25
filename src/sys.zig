const std = @import("std");

pub const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,

    pub fn fmt(c: Context, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(c.a, format, args);
    }

    pub fn print(c: Context, comptime format: []const u8, args: anytype) !void {
        const message = try c.fmt(format, args);
        const output = if (@import("builtin").is_test) std.Io.File.stderr() else std.Io.File.stdout();
        try output.writeStreamingAll(c.io, message);
    }

    pub fn read(c: Context, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(c.io, path, c.a, .limited(64 * 1024 * 1024));
    }

    pub fn write(c: Context, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(c.io, dir);
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = data });
    }

    pub fn capture(c: Context, argv: []const []const u8) ![]const u8 {
        const result = try std.process.run(c.a, c.io, .{
            .argv = argv,
            .stdout_limit = .limited(128 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        if (result.term != .exited or result.term.exited != 0) {
            try std.Io.File.stderr().writeStreamingAll(c.io, result.stderr);
            return error.CommandFailed;
        }
        return result.stdout;
    }

    pub fn run(c: Context, argv: []const []const u8) !void {
        var child = try std.process.spawn(c.io, .{ .argv = argv });
        const term = try child.wait(c.io);
        if (term != .exited or term.exited != 0) return error.CommandFailed;
    }

    pub fn saveOutput(c: Context, argv: []const []const u8, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(c.io, path, .{});
        defer file.close(c.io);
        var child = try std.process.spawn(c.io, .{ .argv = argv, .stdout = .{ .file = file } });
        const term = try child.wait(c.io);
        if (term != .exited or term.exited != 0) return error.CommandFailed;
    }

    pub fn absolute(c: Context, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().realPathFileAlloc(c.io, path, c.a);
    }

    pub fn temp(c: Context) ![]const u8 {
        return try c.a.dupe(u8, std.mem.trim(u8, try c.capture(&.{ "mktemp", "-d", "-t", "owendots.XXXXXXXXXX" }), "\r\n"));
    }

    pub fn download(c: Context, url: []const u8, path: []const u8) !void {
        if (!std.mem.startsWith(u8, url, "https://")) return error.HttpsRequired;
        try c.run(&.{ "curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--retry", "2", "--connect-timeout", "20", "--output", path, "--", url });
    }

    pub fn checksum(c: Context, path: []const u8) ![]const u8 {
        const output = try c.capture(&.{ "sha256sum", "--", path });
        if (output.len < 64) return error.InvalidChecksum;
        return output[0..64];
    }

    pub fn verificationKey(c: Context, source: []const u8, work: []const u8) ![]const u8 {
        const path = try c.absolute(source);
        const data = try c.read(path);
        if (!std.mem.startsWith(u8, data, "-----BEGIN PGP PUBLIC KEY BLOCK-----")) return path;
        const binary = try c.fmt("{s}/verification-key.gpg", .{work});
        try c.run(&.{ "gpg", "--batch", "--yes", "--dearmor", "--output", binary, "--", path });
        return binary;
    }

    pub fn prompt(c: Context, message: []const u8) ![]const u8 {
        const tty = std.Io.Dir.cwd().openFile(c.io, "/dev/tty", .{ .mode = .read_write }) catch return error.InteractiveSelectionRequired;
        defer tty.close(c.io);
        try tty.writeStreamingAll(c.io, message);
        var buffer: [4096]u8 = undefined;
        var reader = tty.readerStreaming(c.io, &buffer);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        return c.a.dupe(u8, std.mem.trim(u8, line, "\r \t"));
    }
};

pub fn safeName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-') return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '_' and ch != '.' and ch != '-') return false;
    return !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

pub fn safePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    for (path) |ch| if (ch < 32 or ch == 127 or ch == '\\') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

test "archive paths reject traversal and control characters" {
    try std.testing.expect(safePath("./usr/bin/foo"));
    try std.testing.expect(!safePath("/etc/passwd"));
    try std.testing.expect(!safePath("usr/../../etc/passwd"));
    try std.testing.expect(!safePath("usr/bin/a\nb"));
    try std.testing.expect(!safeName("--help"));
}
