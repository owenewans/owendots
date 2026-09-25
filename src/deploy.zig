const std = @import("std");
const sys = @import("sys.zig");
const tui = @import("tui.zig");
const media = @import("media.zig");
const desktop = @import("desktop.zig");
const Context = sys.Context;

pub const Selection = struct {
    launch: desktop.Choices,
    both_terminals: bool = false,
    both_browsers: bool = false,
    both_telegram: bool = false,
    both_compositors: bool = false,

    pub fn includes(s: Selection, name: []const u8) bool {
        const optional = .{
            .{ "foot", s.both_terminals or s.launch.terminal == .foot },
            .{ "fcft", s.both_terminals or s.launch.terminal == .foot },
            .{ "ghostty", s.both_terminals or s.launch.terminal == .ghostty },
            .{ "ghostty-shell-integration", s.both_terminals or s.launch.terminal == .ghostty },
            .{ "ghostty-terminfo", s.both_terminals or s.launch.terminal == .ghostty },
            .{ "mozilla-firefox", s.both_browsers or s.launch.browser == .firefox },
            .{ "palemoon", s.both_browsers or s.launch.browser == .palemoon },
            .{ "tele", s.both_telegram or s.launch.telegram == .tele },
            .{ "telegramtui", s.both_telegram or s.launch.telegram == .telegramtui },
            .{ "telegramtui-runtime", s.both_telegram or s.launch.telegram == .telegramtui },
            .{ "niri", s.both_compositors or s.launch.compositor == .niri },
            .{ "xwayland-satellite", s.both_compositors or s.launch.compositor == .niri },
            .{ "scroll", s.both_compositors or s.launch.compositor == .scroll },
            .{ "swaybg", s.both_compositors or s.launch.compositor == .scroll },
        };
        inline for (optional) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
        return true;
    }
};

fn choice(c: Context, title: []const u8, comptime T: type, both: *bool) !T {
    const fields = std.meta.fields(T);
    const answer = try tui.menu(c, title, &.{ fields[0].name, fields[0].name, fields[1].name, fields[1].name, "both", "Install both" });
    both.* = std.mem.eql(u8, answer, "both");
    const selected = if (both.*) try tui.menu(c, "Default application / session", &.{ fields[0].name, fields[0].name, fields[1].name, fields[1].name }) else answer;
    return std.meta.stringToEnum(T, selected) orelse error.InvalidSelection;
}

pub fn start(c: Context) !void {
    _ = try c.read("/etc/slackware-version");
    _ = try media.parse(c, try c.read("/var/lib/owendots/media.json"));
    if (std.mem.eql(u8, std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return error.RunAsDesktopUser;
    const action = try tui.menu(c, "Workstation", &.{ "deploy", "Select and install desktop applications", "configure", "Application preferences and palette", "menu", "Open desktop controls" });
    if (std.mem.eql(u8, action, "configure")) return desktop.configure(c);
    if (std.mem.eql(u8, action, "menu")) return c.run(&.{"/usr/bin/owenctl"});
    var selected: Selection = undefined;
    selected.launch.terminal = try choice(c, "Terminals", @FieldType(desktop.Choices, "terminal"), &selected.both_terminals);
    selected.launch.browser = try choice(c, "Browsers", @FieldType(desktop.Choices, "browser"), &selected.both_browsers);
    selected.launch.telegram = try choice(c, "Telegram clients", @FieldType(desktop.Choices, "telegram"), &selected.both_telegram);
    selected.launch.compositor = try choice(c, "Compositors", @FieldType(desktop.Choices, "compositor"), &selected.both_compositors);
    const json = try std.json.Stringify.valueAlloc(c.a, selected, .{});
    try c.run(&.{ "doas", "/usr/bin/owendots", "deploy-system", json });
    try c.write(try c.fmt("{s}/owendots/apps.json", .{try desktop.config(c)}), try std.json.Stringify.valueAlloc(c.a, selected.launch, .{ .whitespace = .indent_2 }));
    try desktop.apply(c);
    _ = try tui.dialog(c, &.{ "--msgbox", "Desktop packages and configuration installed. Reboot to enter Ly, or log out and select a session if Ly is already running.", "10", "76" });
}

fn contains(manifest: media.Manifest, name: []const u8) bool {
    for (manifest.packages) |pkg| if (std.mem.eql(u8, pkg.name, name)) return true;
    return false;
}

pub fn validate(manifest: media.Manifest, selection: Selection) !void {
    const required = [_][]const u8{ "owenctl", "ly", "pipewire", "wireplumber", "waybar", "dunst", "wl-clipboard", "cliphist", "slurp", "grim", "micro", "yazi", "swayimg", "mpv", "aria2", "htop", "walker", "elephant", "elephant-desktopapplications", "elephant-runner", "foot", "ghostty", "mozilla-firefox", "palemoon", "tele", "telegramtui", "niri", "scroll" };
    for (required) |name| if (selection.includes(name) and !contains(manifest, name)) return error.IncompleteDesktopMedia;
}

pub fn install(c: Context, json: []const u8) !void {
    if (!std.mem.eql(u8, std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return error.RootRequired;
    _ = try c.read("/etc/slackware-version");
    const manifest = try media.parse(c, try c.read("/var/lib/owendots/media.json"));
    const selection = (try std.json.parseFromSlice(Selection, c.a, json, .{})).value;
    try validate(manifest, selection);
    const work = try c.temp();
    defer c.run(&.{ "rm", "-rf", "--", work }) catch {};
    var plan: std.Io.Writer.Allocating = .init(c.a);
    try plan.writer.writeAll("Install or upgrade the following Slackware packages:\n\n");
    for (manifest.packages) |pkg| {
        if (pkg.role == .desktop and selection.includes(pkg.name)) try plan.writer.print("{s}\n", .{pkg.file});
    }
    try plan.writer.writeAll("\nConfigure PipeWire scheduling, disable PulseAudio autostart, and enable Ly on tty2. Existing application configuration receives a backup when the palette is applied.\n");
    const review = try c.fmt("{s}/plan.txt", .{work});
    try c.write(review, plan.written());
    _ = try tui.dialog(c, &.{ "--textbox", review, "25", "90" });
    if (!std.mem.eql(u8, try tui.menu(c, "Apply this desktop plan?", &.{ "cancel", "Cancel", "install", "Install" }), "install")) return error.Cancelled;
    var paths: std.ArrayList([]const u8) = .empty;
    for (manifest.packages) |pkg| {
        if (pkg.role != .desktop or !selection.includes(pkg.name)) continue;
        const path = try c.fmt("/var/cache/owendots/packages/{s}", .{pkg.file});
        _ = std.Io.Dir.cwd().statFile(c.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => blk: {
                const url = pkg.source orelse return error.MissingLocalOnlyPackage;
                if (!std.mem.eql(u8, try tui.menu(c, try c.fmt("Missing package: {s}\nDownload {s}?", .{ pkg.file, url }), &.{ "download", "Download", "cancel", "Cancel" }), "download")) return error.Cancelled;
                const partial = try c.fmt("{s}/{s}", .{ work, pkg.file });
                try c.download(url, partial);
                if (!std.ascii.eqlIgnoreCase(try c.checksum(partial), pkg.sha256)) return error.PackageChecksumMismatch;
                try c.run(&.{ "install", "-Dm644", "--", partial, path });
                break :blk try std.Io.Dir.cwd().statFile(c.io, path, .{});
            },
            else => return err,
        };
        if (!std.ascii.eqlIgnoreCase(try c.checksum(path), pkg.sha256)) return error.PackageChecksumMismatch;
        try paths.append(c.a, path);
    }
    // verify the entire selected set before running package installation scripts.
    for (paths.items) |path| try c.run(&.{ "/sbin/upgradepkg", "--install-new", path });
    try c.run(&.{"/sbin/ldconfig"});
    try @import("system.zig").desktop(c);
    try @import("login.zig").enable(c);
}

test "desktop selection keeps the requested applications and explicit alternatives" {
    var s: Selection = .{ .launch = .{ .terminal = .foot, .browser = .firefox, .telegram = .tele, .compositor = .niri } };
    try std.testing.expect(s.includes("foot"));
    try std.testing.expect(!s.includes("ghostty-terminfo"));
    try std.testing.expect(!s.includes("palemoon"));
    try std.testing.expect(!s.includes("scroll"));
    try std.testing.expect(s.includes("mesa"));
    s.both_terminals = true;
    s.both_compositors = true;
    try std.testing.expect(s.includes("ghostty-terminfo"));
    try std.testing.expect(s.includes("scroll"));
    try std.testing.expect(s.includes("swaybg"));
}
