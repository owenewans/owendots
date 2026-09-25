const std = @import("std");
const sys = @import("sys.zig");
const Context = sys.Context;

fn directory(c: Context, path: []const u8) !void {
    std.Io.Dir.cwd().createDir(c.io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const stat = try std.Io.Dir.cwd().statFile(c.io, path, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.DestinationMustBeDirectory;
}

fn unused(c: Context, parent: []const u8, name: []const u8) ![]const u8 {
    var number: usize = 0;
    while (true) : (number += 1) {
        const candidate = if (number == 0) try c.fmt("{s}/{s}", .{ parent, name }) else try c.fmt("{s}/{s}.copy-{d}", .{ parent, name, number });
        _ = std.Io.Dir.cwd().statFile(c.io, candidate, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return candidate,
            else => return err,
        };
    }
}

fn owner(c: Context, path: []const u8, uid: u32, gid: u32) !void {
    try c.run(&.{ "chown", "-hR", "-P", try c.fmt("{d}:{d}", .{ uid, gid }), "--", path });
}

pub fn importFiles(c: Context, input: []const u8, home: []const u8, uid: u32, gid: u32) !void {
    const source = try c.absolute(input);
    const target = try c.absolute(home);
    if (std.mem.eql(u8, source, "/") or std.mem.eql(u8, target, "/")) return error.OverlappingImportPaths;
    const data = try c.fmt("{s}/Data", .{target});
    const output = try c.fmt("{s}/usb", .{data});
    if (std.mem.eql(u8, source, target) or std.mem.startsWith(u8, target, try c.fmt("{s}/", .{source})) or std.mem.startsWith(u8, source, try c.fmt("{s}/", .{target}))) return error.OverlappingImportPaths;
    try directory(c, data);
    try directory(c, output);
    var dir = try std.Io.Dir.cwd().openDir(c.io, source, .{ .iterate = true });
    defer dir.close(c.io);
    var iterator = dir.iterate();
    while (try iterator.next(c.io)) |entry| {
        const destination = try unused(c, output, entry.name);
        try c.run(&.{ "cp", "-a", "--no-preserve=ownership", "--", try c.fmt("{s}/{s}", .{ source, entry.name }), destination });
        try owner(c, destination, uid, gid);
        if (!@import("builtin").is_test) try c.print("copied {s}\n", .{destination});
    }
    try c.run(&.{ "chown", try c.fmt("{d}:{d}", .{ uid, gid }), "--", data, output });
}

pub fn importKey(c: Context, input: []const u8, home: []const u8, uid: u32, gid: u32) !void {
    const stat = try std.Io.Dir.cwd().statFile(c.io, input, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size > 1024 * 1024) return error.InvalidPrivateKeyFile;
    const contents = try c.read(input);
    const newline = std.mem.indexOfScalar(u8, contents, '\n') orelse return error.InvalidPrivateKeyFile;
    const header = contents[0..newline];
    if (!std.mem.startsWith(u8, header, "-----BEGIN ") or std.mem.indexOf(u8, header, "PRIVATE KEY-----") == null) return error.InvalidPrivateKeyFile;
    const name = std.fs.path.basename(input);
    if (!sys.safeName(name)) return error.InvalidKeyFilename;
    const ssh = try c.fmt("{s}/.ssh", .{try c.absolute(home)});
    try directory(c, ssh);
    try c.run(&.{ "chmod", "0700", ssh });
    const destination = try unused(c, ssh, name);
    try c.run(&.{ "install", "-m", "0600", "--", input, destination });
    try owner(c, destination, uid, gid);
    const config_path = try c.fmt("{s}/config", .{ssh});
    const config_stat = std.Io.Dir.cwd().statFile(c.io, config_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (config_stat) |s| if (s.kind != .file) return error.InvalidSshConfig;
    const existing = if (config_stat != null) try c.read(config_path) else "";
    try c.write(config_path, try c.fmt("{s}\nHost *\n    IdentityFile ~/.ssh/{s}\n", .{ existing, std.fs.path.basename(destination) }));
    try c.run(&.{ "chmod", "0600", config_path });
    try owner(c, config_path, uid, gid);
    try c.run(&.{ "chown", try c.fmt("{d}:{d}", .{ uid, gid }), "--", ssh });
    if (!@import("builtin").is_test) try c.print("private key imported: {s}\n", .{destination});
}

test "USB import preserves modes and symlinks and renames collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const work = try c.temp();
    defer std.Io.Dir.cwd().deleteTree(c.io, work) catch {};
    const source = try c.fmt("{s}/source", .{work});
    const home = try c.fmt("{s}/home", .{work});
    try directory(c, source);
    try directory(c, home);
    const file = try c.fmt("{s}/run", .{source});
    try c.write(file, "#!/bin/sh\nexit 0\n");
    try c.run(&.{ "chmod", "0750", file });
    try c.run(&.{ "ln", "-s", "run", try c.fmt("{s}/link", .{source}) });
    const uid = try std.fmt.parseInt(u32, std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), 10);
    const gid = try std.fmt.parseInt(u32, std.mem.trim(u8, try c.capture(&.{ "id", "-g" }), "\n"), 10);
    try importFiles(c, source, home, uid, gid);
    try importFiles(c, source, home, uid, gid);
    const copied = try c.fmt("{s}/Data/usb/run.copy-1", .{home});
    try std.testing.expectEqualStrings("750", std.mem.trim(u8, try c.capture(&.{ "stat", "-c", "%a", copied }), "\n"));
    try std.testing.expectEqualStrings("run", std.mem.trim(u8, try c.capture(&.{ "readlink", try c.fmt("{s}/Data/usb/link.copy-1", .{home}) }), "\n"));
    try std.testing.expectError(error.OverlappingImportPaths, importFiles(c, work, home, uid, gid));
}
