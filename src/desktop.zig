const std = @import("std");
const sys = @import("sys.zig");
const tui = @import("tui.zig");
const palette = @import("palette.zig");
const Context = sys.Context;

pub const Choices = struct {
    terminal: enum { foot, ghostty },
    browser: enum { firefox, palemoon },
    telegram: enum { tele, telegramtui },
    compositor: enum { niri, scroll },
};

fn user(c: Context) !void {
    if (std.mem.eql(u8, std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return error.RunAsDesktopUser;
}

fn config(c: Context) ![]const u8 {
    const path = if (c.env) |env| env.get("XDG_CONFIG_HOME") else null;
    const result = path orelse try c.fmt("{s}/.config", .{try c.environment("HOME")});
    if (!std.fs.path.isAbsolute(result)) return error.AbsoluteConfigPathRequired;
    return result;
}

pub fn choices(c: Context) !Choices {
    const value = try std.json.parseFromSlice(Choices, c.a, try c.read(try c.fmt("{s}/owendots/apps.json", .{try config(c)})), .{});
    return value.value;
}

pub fn configure(c: Context) !void {
    try user(c);
    const selected: Choices = .{
        .terminal = std.meta.stringToEnum(@FieldType(Choices, "terminal"), try tui.menu(c, "Terminal", &.{ "foot", "Foot", "ghostty", "Ghostty (notifications disabled)" })).?,
        .browser = std.meta.stringToEnum(@FieldType(Choices, "browser"), try tui.menu(c, "Browser to launch", &.{ "firefox", "Firefox", "palemoon", "Pale Moon" })).?,
        .telegram = std.meta.stringToEnum(@FieldType(Choices, "telegram"), try tui.menu(c, "Telegram client to launch", &.{ "tele", "tele", "telegramtui", "telegramtui" })).?,
        .compositor = std.meta.stringToEnum(@FieldType(Choices, "compositor"), try tui.menu(c, "Compositor", &.{ "niri", "Niri", "scroll", "scroll" })).?,
    };
    try c.write(try c.fmt("{s}/owendots/apps.json", .{try config(c)}), try std.json.Stringify.valueAlloc(c.a, selected, .{ .whitespace = .indent_2 }));
    try apply(c);
}

pub fn apply(c: Context) !void {
    try user(c);
    const root = try config(c);
    const path = try c.fmt("{s}/owendots/palette.toml", .{root});
    _ = c.read(path) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const initial = try c.read("/usr/share/owendots/palette.toml");
            try c.write(path, initial);
            break :blk initial;
        },
        else => return err,
    };
    const stage = try c.temp();
    defer c.run(&.{ "rm", "-rf", "--", stage }) catch {};
    try palette.generate(c, path, "/usr/share/owendots/templates", stage);
    const selected = try choices(c);
    if (selected.compositor == .scroll) {
        const bar_path = try c.fmt("{s}/waybar/config.jsonc", .{stage});
        const content = try c.read(bar_path);
        try c.write(bar_path, try std.mem.replaceOwned(u8, c.a, content, "niri/workspaces", "sway/workspaces"));
    }
    const files = try c.capture(&.{ "find", stage, "-type", "f", "-printf", "%P\\0" });
    var paths = std.mem.splitScalar(u8, files, 0);
    while (paths.next()) |relative| {
        if (relative.len == 0) continue;
        if (std.mem.startsWith(u8, relative, "firefox/")) continue;
        if (!sys.safePath(relative)) return error.InvalidTemplatePath;
        const target = try c.fmt("{s}/{s}", .{ root, relative });
        const backup = try c.fmt("{s}/owendots/backup/{s}", .{ root, relative });
        const old = c.read(target) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (old) |content| {
            _ = c.read(backup) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    try c.write(backup, content);
                    break :blk content;
                },
                else => return err,
            };
        }
        const temporary = try c.fmt("{s}.owendots-new", .{target});
        try c.write(temporary, try c.read(try c.fmt("{s}/{s}", .{ stage, relative })));
        try std.Io.Dir.cwd().rename(temporary, .cwd(), target, c.io);
    }
    // browsers use their own managed profile; an existing personal profile stays intact.
    for ([_][]const u8{ "firefox", "palemoon" }) |browser| {
        const profile = try c.fmt("{s}/owendots/{s}", .{ root, browser });
        for ([_][]const u8{ "user.js", "chrome/userChrome.css" }) |file| {
            try c.write(try c.fmt("{s}/{s}", .{ profile, file }), try c.read(try c.fmt("{s}/firefox/{s}", .{ stage, file })));
        }
    }
    try c.print("Applied palette. Original files: {s}/owendots/backup\nRestart applications to reload their colors.\n", .{root});
}

pub fn launch(c: Context, kind: []const u8, arguments: []const []const u8) !void {
    try user(c);
    const selected = try choices(c);
    var argv: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, kind, "terminal")) {
        try argv.append(c.a, @tagName(selected.terminal));
    } else if (std.mem.eql(u8, kind, "browser")) {
        const browser = @tagName(selected.browser);
        try argv.appendSlice(c.a, &.{ browser, "--no-remote", "--profile", try c.fmt("{s}/owendots/{s}", .{ try config(c), browser }) });
    } else if (std.mem.eql(u8, kind, "files") or std.mem.eql(u8, kind, "telegram") or std.mem.eql(u8, kind, "monitor") or std.mem.eql(u8, kind, "editor")) {
        const program = if (std.mem.eql(u8, kind, "files")) "yazi" else if (std.mem.eql(u8, kind, "telegram")) @tagName(selected.telegram) else if (std.mem.eql(u8, kind, "monitor")) "htop" else "micro";
        try argv.append(c.a, @tagName(selected.terminal));
        if (std.mem.eql(u8, kind, "monitor")) try argv.append(c.a, if (selected.terminal == .foot) "--app-id=org.owendots.control" else "--class=org.owendots.control");
        try argv.appendSlice(c.a, &.{ "-e", program });
    } else return error.UnknownApplication;
    try argv.appendSlice(c.a, arguments);
    try c.run(argv.items);
}

pub fn screenshot(c: Context) !void {
    try user(c);
    if ((try choices(c)).compositor == .niri) return c.run(&.{ "niri", "msg", "action", "screenshot" });
    const region = std.mem.trim(u8, try c.capture(&.{"slurp"}), "\r\n");
    if (region.len == 0) return error.Cancelled;
    const dir = try c.temp();
    defer c.run(&.{ "rm", "-rf", "--", dir }) catch {};
    const path = try c.fmt("{s}/screenshot.png", .{dir});
    try c.run(&.{ "grim", "-g", region, path });
    try c.run(&.{ "sh", "-c", "exec wl-copy --type image/png < \"$1\"", "owendots-screenshot", path });
}

pub fn clipboard(c: Context) !void {
    try user(c);
    // only fixed shell code; selected clipboard text never becomes a command.
    try c.run(&.{ "bash", "-o", "pipefail", "-c", "selection=$(cliphist list | walker --dmenu) || exit; [ -n \"$selection\" ] || exit; printf '%s\\n' \"$selection\" | cliphist decode | wl-copy" });
}

test "application choices reject executable injection" {
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Choices, std.testing.allocator, "{\"terminal\":\"foot;id\",\"browser\":\"firefox\",\"telegram\":\"tele\",\"compositor\":\"niri\"}", .{}));
}
