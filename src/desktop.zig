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

pub fn config(c: Context) ![]const u8 {
    const path = if (c.env) |env| env.get("XDG_CONFIG_HOME") else null;
    const result = path orelse try c.fmt("{s}/.config", .{try c.environment("HOME")});
    if (!std.fs.path.isAbsolute(result)) return error.AbsoluteConfigPathRequired;
    return result;
}

pub fn choices(c: Context) !Choices {
    const value = try std.json.parseFromSlice(Choices, c.a, try c.read(try c.fmt("{s}/owendots/apps.json", .{try config(c)})), .{});
    return value.value;
}

pub fn compositor(c: Context) !@FieldType(Choices, "compositor") {
    if (c.env) |env| {
        if (env.get("XDG_SESSION_DESKTOP")) |name| {
            if (std.meta.stringToEnum(@FieldType(Choices, "compositor"), name)) |active| return active;
        }
    }
    return (try choices(c)).compositor;
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
    try @import("display.zig").append(c, root, stage);
    const selected = try choices(c);
    const bar_path = try c.fmt("{s}/waybar/config.jsonc", .{stage});
    const bar = try c.read(bar_path);
    const scroll_bar = try std.mem.replaceOwned(u8, c.a, bar, "niri/workspaces", "sway/workspaces");
    try c.write(try c.fmt("{s}/waybar/niri.jsonc", .{stage}), bar);
    try c.write(try c.fmt("{s}/waybar/scroll.jsonc", .{stage}), scroll_bar);
    if (selected.compositor == .scroll) {
        try c.write(bar_path, scroll_bar);
    }
    const files = try c.capture(&.{ "find", stage, "-type", "f", "-printf", "%P\\0" });
    var paths = std.mem.splitScalar(u8, files, 0);
    while (paths.next()) |relative| {
        if (relative.len == 0) continue;
        if (std.mem.startsWith(u8, relative, "system/") or std.mem.startsWith(u8, relative, "firefox/") or std.mem.startsWith(u8, relative, "palemoon/")) continue;
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
        for ([_][]const u8{ "user.js", "chrome/userChrome.css", "chrome/userContent.css" }) |file| {
            const source = if (!std.mem.eql(u8, file, "chrome/userChrome.css")) "firefox" else browser;
            try c.write(try c.fmt("{s}/{s}", .{ profile, file }), try c.read(try c.fmt("{s}/{s}/{s}", .{ stage, source, file })));
        }
    }
    try launchers(c);
    try c.print("Applied palette. Original files: {s}/owendots/backup\nRestart applications to reload their colors.\n", .{root});
}

pub fn launchBrowser(c: Context, name: []const u8, arguments: []const []const u8) !void {
    try user(c);
    if (!std.mem.eql(u8, name, "firefox") and !std.mem.eql(u8, name, "palemoon")) return error.UnknownBrowser;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ name, "--no-remote", "--profile", try c.fmt("{s}/owendots/{s}", .{ try config(c), name }) });
    try argv.appendSlice(c.a, arguments);
    try c.run(argv.items);
}

fn launchers(c: Context) !void {
    const data_home = (c.env orelse return error.MissingEnvironment).get("XDG_DATA_HOME") orelse try c.fmt("{s}/.local/share", .{try c.environment("HOME")});
    if (!std.fs.path.isAbsolute(data_home)) return error.AbsoluteDataPathRequired;
    const apps = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "firefox", "Firefox", "browser firefox %U", "web-browser-symbolic" },
        .{ "palemoon", "Pale Moon", "browser palemoon %U", "web-browser-symbolic" },
        .{ "owendots-terminal", "Terminal", "launch terminal", "utilities-terminal-symbolic" },
        .{ "owendots-files", "Files", "launch files", "folder-symbolic" },
        .{ "owendots-telegram", "Telegram", "launch telegram", "mail-send-symbolic" },
        .{ "owendots-settings", "Settings", "menu", "preferences-system-symbolic" },
    };
    for (apps) |app| {
        const path = try c.fmt("{s}/applications/{s}.desktop", .{ data_home, app[0] });
        const saved = try c.fmt("{s}/owendots/backup/desktop/{s}.desktop", .{ try config(c), app[0] });
        const original = c.read(path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (original) |text| {
            _ = c.read(saved) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    try c.write(saved, text);
                    break :blk text;
                },
                else => return err,
            };
        }
        try c.write(path, try c.fmt("[Desktop Entry]\nType=Application\nName={s}\nExec=owendots {s}\nIcon={s}\nTerminal=false\nCategories=Utility;\n", .{ app[1], app[2], app[3] }));
    }
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
    if ((try compositor(c)) == .niri) return c.run(&.{ "niri", "msg", "action", "screenshot" });
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
