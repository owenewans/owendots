const std = @import("std");
const sys = @import("sys.zig");
const palette = @import("palette.zig");

pub fn boot(c: sys.Context, target: []const u8) ![]const u8 {
    const saved = try c.fmt("{s}/etc/owendots/limine-theme.conf", .{target});
    return c.read(saved) catch |err| switch (err) {
        error.FileNotFound => palette.render(c.a, try c.read(try c.fmt("{s}/usr/share/owendots/templates/system/limine.conf", .{target})), try palette.parse(c.a, try c.read(try c.fmt("{s}/usr/share/owendots/palette.toml", .{target})))),
        else => return err,
    };
}

pub fn apply(c: sys.Context, path: []const u8) !void {
    if (!std.mem.eql(u8, std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return c.run(&.{ "doas", "/usr/bin/owendots", "system-theme", path });
    _ = try c.read("/etc/slackware-version");
    _ = try @import("media.zig").parse(c, try c.read("/var/lib/owendots/media.json"));
    const text = try c.read(path);
    const colors = try palette.parse(c.a, text);
    const theme = try palette.render(c.a, try c.read("/usr/share/owendots/templates/system/limine.conf"), colors);
    try c.write("/etc/owendots/palette.toml", text);
    try c.write("/etc/owendots/limine-theme.conf", theme);
    const theme_keys = [_][]const u8{ "bg", "fg", "border_fg", "error_bg", "error_fg", "full_color", "hide_borders", "blank_box", "margin_box_h", "margin_box_v", "start_cmd", "logout_cmd" };
    var output: std.Io.Writer.Allocating = .init(c.a);
    var lines = std.mem.splitScalar(u8, try c.read("/etc/ly/config.ini"), '\n');
    while (lines.next()) |line| {
        const key = std.mem.trim(u8, line[0 .. std.mem.indexOfScalar(u8, line, '=') orelse line.len], " \t");
        var replaced = false;
        for (theme_keys) |name| if (std.mem.eql(u8, key, name)) {
            replaced = true;
        };
        if (!replaced and line.len > 0) try output.writer.print("{s}\n", .{line});
    }
    try output.writer.writeAll("full_color = false\nbg = 1\nfg = 8\nborder_fg = 5\nerror_bg = 1\nerror_fg = 2\nhide_borders = false\nblank_box = true\nmargin_box_h = 3\nmargin_box_v = 1\nstart_cmd = /etc/ly/owendots-colors\nlogout_cmd = /etc/ly/owendots-colors\n");
    try c.write("/etc/ly/config.ini", output.written());
    var console: std.Io.Writer.Allocating = .init(c.a);
    try console.writer.writeAll("#!/bin/sh\nprintf '\\033%%G");
    const ansi = [_][]const u8{ "background", "red", "green", "yellow", "accent", "magenta", "cyan", "foreground", "bright_black", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan", "bright_white" };
    for (ansi, 0..) |key, i| try console.writer.print("\\033]P{X}{s}", .{ i, colors.get(key).?[1..] });
    try console.writer.writeAll("'\n");
    try c.write("/etc/ly/owendots-colors", console.written());
    try c.run(&.{ "chmod", "755", "/etc/ly/owendots-colors" });
    for ([_][]const u8{ "/boot/efi", "/boot/limine" }) |mount| {
        const config = try c.fmt("{s}/limine.conf", .{mount});
        const old = c.read(config) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const fs = std.mem.trim(u8, try c.capture(&.{ "findmnt", "-n", "-o", "FSTYPE", "--mountpoint", mount }), "\r\n");
        if (!std.mem.eql(u8, fs, "vfat")) return error.BootMustBeMountedFat32;
        const entries = std.mem.indexOf(u8, old, "\n/") orelse return error.InvalidBootConfiguration;
        const backup = try c.fmt("{s}.before-theme", .{config});
        _ = c.read(backup) catch |err| switch (err) {
            error.FileNotFound => blk: {
                try c.write(backup, old);
                break :blk old;
            },
            else => return err,
        };
        const temporary = try c.fmt("{s}.part", .{config});
        try c.write(temporary, try c.fmt("timeout: 5\n{s}{s}", .{ theme, old[entries..] }));
        try c.run(&.{ "mv", "--", temporary, config });
        try c.run(&.{ "sync", "-f", mount });
    }
    try c.print("Applied shared login and boot colors. They appear at the next login and boot.\n", .{});
}
