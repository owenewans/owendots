const std = @import("std");
const sys = @import("sys.zig");

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn inittab(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var defaults: usize = 0;
    var consoles: usize = 0;
    var managers: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, source, "\n"), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            try output.appendSlice(a, line);
        } else {
            var fields = std.mem.splitScalar(u8, line, ':');
            const id = fields.next() orelse return error.InvalidInittab;
            const levels = fields.next() orelse return error.InvalidInittab;
            const action = fields.next() orelse return error.InvalidInittab;
            const command = fields.rest();
            if (same(action, "initdefault")) {
                if (!same(levels, "3") and !same(levels, "4")) return error.UnexpectedDefaultRunlevel;
                defaults += 1;
                try output.appendSlice(a, try std.fmt.allocPrint(a, "{s}:4:initdefault:", .{id}));
            } else {
                var words = std.mem.tokenizeAny(u8, command, " \t");
                const executable = words.next() orelse "";
                var tty2 = false;
                while (words.next()) |word| if (same(word, "tty2")) {
                    tty2 = true;
                };
                if (same(executable, "/sbin/agetty") and same(action, "respawn") and tty2) {
                    consoles += 1;
                    try output.appendSlice(a, id);
                    try output.append(a, ':');
                    for (levels) |level| if (level != '4') {
                        try output.append(a, level);
                    };
                    try output.appendSlice(a, try std.fmt.allocPrint(a, ":{s}:{s}", .{ action, command }));
                } else {
                    if (same(command, "/etc/rc.d/rc.4") and same(action, "respawn") and same(levels, "4")) managers += 1;
                    try output.appendSlice(a, line);
                }
            }
        }
        try output.append(a, '\n');
    }
    if (defaults != 1 or consoles != 1 or managers != 1) return error.UnsupportedInittab;
    return output.toOwnedSlice(a);
}

fn backup(c: sys.Context, path: []const u8) !void {
    const original = c.read(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const saved = try c.fmt("/var/lib/owendots/backup{s}", .{path});
    _ = c.read(saved) catch |err| switch (err) {
        error.FileNotFound => return c.write(saved, original),
        else => return err,
    };
}

pub fn enable(c: sys.Context) !void {
    if (!same(std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return error.RootRequired;
    _ = try c.read("/etc/slackware-version");
    _ = try @import("media.zig").parse(c, try c.read("/var/lib/owendots/media.json"));
    try c.run(&.{ "test", "-x", "/usr/bin/ly-dm" });
    const init = try inittab(c.a, try c.read("/etc/inittab"));
    for ([_][]const u8{ "/etc/inittab", "/etc/rc.d/rc.4.local", "/etc/pam.d/ly", "/etc/ly/config.ini" }) |path| try backup(c, path);
    try c.write("/etc/pam.d/ly", "#%PAM-1.0\nauth include login\naccount include login\npassword include login\nsession include login\n");
    try c.write("/etc/rc.d/rc.4.local", "#!/bin/sh\nexport LANG=en_US.UTF-8 TZ=UTC\n/usr/bin/chvt 2\nexec /sbin/agetty -n -l /usr/bin/ly-dm tty2 38400 linux\n");
    try c.run(&.{ "chmod", "755", "/etc/rc.d/rc.4.local" });
    try c.run(&.{ "mkdir", "-p", "/etc/owendots/sessions", "/etc/owendots/sessions-x11", "/etc/ly/custom-sessions" });
    for ([_][]const u8{ "niri", "scroll" }) |name| {
        const binary = try c.fmt("/usr/bin/{s}", .{name});
        const entry = try c.fmt("/etc/owendots/sessions/owendots-{s}.desktop", .{name});
        c.run(&.{ "test", "-x", binary }) catch {
            try c.run(&.{ "rm", "-f", "--", entry });
            continue;
        };
        try c.run(&.{ "ln", "-sfn", try c.fmt("/usr/share/wayland-sessions/owendots-{s}.desktop", .{name}), entry });
    }
    try c.write("/etc/ly/config.ini",
        \\allow_empty_password = false
        \\animation = none
        \\auth_fails = 0
        \\box_title = owendots
        \\clock = %Y-%m-%d %H:%M UTC
        \\clear_password = true
        \\hide_version_string = true
        \\brightness_down_key = null
        \\brightness_up_key = null
        \\waylandsessions = /etc/owendots/sessions
        \\xsessions = /etc/owendots/sessions-x11
        \\save = true
        \\service_name = ly
        \\setup_cmd = /etc/ly/setup.sh
        \\shutdown_cmd = /usr/bin/loginctl poweroff
        \\restart_cmd = /usr/bin/loginctl reboot
        \\session_log = .local/state/ly-session.log
        \\
    );
    try c.write("/etc/inittab", init);
    try c.print("Enabled Ly on tty2 for the next boot. Other console logins remain available.\n", .{});
}

test "Ly reserves only tty2 in runlevel four and preserves console recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "# tty2 remains usable in runlevel 3\nid:3:initdefault:\nc1:12345:respawn:/sbin/agetty 38400 tty1 linux\nc2:12345:respawn:/sbin/agetty 38400 tty2 linux\nx1:4:respawn:/etc/rc.d/rc.4\n";
    const result = try inittab(a, source);
    try std.testing.expect(std.mem.indexOf(u8, result, "c2:1235:respawn:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "c1:12345:respawn:") != null);
    try std.testing.expectEqualStrings(result, try inittab(a, result));
    try std.testing.expectError(error.UnsupportedInittab, inittab(a, "id:3:initdefault:\n"));
    try std.testing.expectError(error.UnexpectedDefaultRunlevel, inittab(a, "id:1:initdefault:\n"));
}
