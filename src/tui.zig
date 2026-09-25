const std = @import("std");
const Context = @import("sys.zig").Context;

pub fn dialog(c: Context, arguments: []const []const u8) ![]const u8 {
    const tty = try std.Io.Dir.cwd().openFile(c.io, "/dev/tty", .{ .mode = .read_write });
    defer tty.close(c.io);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ "dialog", "--stdout", "--backtitle", "owendots / Slackware64-current" });
    try argv.appendSlice(c.a, arguments);
    var child = try std.process.spawn(c.io, .{ .argv = argv.items, .stdin = .{ .file = tty }, .stderr = .{ .file = tty }, .stdout = .pipe });
    defer child.kill(c.io);
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(c.io, &buffer);
    const answer = try reader.interface.allocRemaining(c.a, .limited(65536));
    const result = try child.wait(c.io);
    if (result != .exited or result.exited != 0) return error.Cancelled;
    return answer;
}

pub fn input(c: Context, title: []const u8, initial: []const u8) ![]const u8 {
    return dialog(c, &.{ "--inputbox", title, "10", "72", initial });
}

pub fn password(c: Context, title: []const u8) ![]const u8 {
    const first = try dialog(c, &.{ "--insecure", "--passwordbox", title, "10", "72" });
    if (first.len == 0) return error.EmptyPassword;
    const second = try dialog(c, &.{ "--insecure", "--passwordbox", "Repeat password", "10", "72" });
    if (!std.mem.eql(u8, first, second)) return error.PasswordMismatch;
    for (first) |ch| if (ch == '\n' or ch == '\r' or ch == 0) return error.InvalidPassword;
    return first;
}

pub fn menu(c: Context, title: []const u8, choices: []const []const u8) ![]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(c.a, &.{ "--menu", title, "22", "80", "14" });
    try args.appendSlice(c.a, choices);
    return dialog(c, args.items);
}
