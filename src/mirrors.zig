const std = @import("std");
const sys = @import("sys.zig");
const tui = @import("tui.zig");
const Context = sys.Context;

pub const Mirror = struct { url: []const u8, host: []const u8, milliseconds: f64 = std.math.inf(f64) };

pub fn parse(c: Context, html: []const u8) ![]Mirror {
    const begin = std.mem.indexOf(u8, html, "Available https mirrors:") orelse return error.InvalidMirrorList;
    const end = std.mem.indexOfPos(u8, html, begin, "Available http mirrors:") orelse html.len;
    var result: std.ArrayList(Mirror) = .empty;
    var links = std.mem.splitSequence(u8, html[begin..end], "href=");
    _ = links.next();
    while (links.next()) |link| {
        const start: usize = if (link.len > 0 and (link[0] == '\'' or link[0] == '"')) 1 else 0;
        const url = link[start .. start + (std.mem.indexOfAny(u8, link[start..], "\"' <>\r\n\t") orelse continue)];
        if (!std.mem.startsWith(u8, url, "https://")) continue;
        const suffix = url[8..];
        const host = suffix[0 .. std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len];
        if (host.len == 0 or host[0] == '-') continue;
        var valid = true;
        for (host) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-') {
            valid = false;
        };
        for (suffix) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "./_-", ch) == null) {
            valid = false;
        };
        if (!valid or std.mem.indexOf(u8, suffix, "..") != null) continue;
        const current = try c.fmt("{s}/slackware64-current/", .{std.mem.trimEnd(u8, url, "/")});
        var duplicate = false;
        for (result.items) |old| if (std.mem.eql(u8, old.url, current)) {
            duplicate = true;
        };
        if (!duplicate) try result.append(c.a, .{ .url = current, .host = try c.a.dupe(u8, host) });
    }
    if (result.items.len == 0) return error.EmptyMirrorList;
    return result.toOwnedSlice(c.a);
}

pub fn latency(output: []const u8) !f64 {
    const pos = std.mem.indexOf(u8, output, "min/avg/max") orelse return error.NoPingReply;
    const equal = std.mem.indexOfScalarPos(u8, output, pos, '=') orelse return error.NoPingReply;
    var parts = std.mem.splitScalar(u8, output[equal + 1 ..], '/');
    _ = parts.next();
    const value = try std.fmt.parseFloat(f64, std.mem.trim(u8, parts.next() orelse return error.NoPingReply, " \t"));
    if (!std.math.isFinite(value) or value < 0) return error.InvalidPingReply;
    return value;
}

fn before(_: void, a: Mirror, b: Mirror) bool {
    return a.milliseconds < b.milliseconds;
}

fn available(c: Context, mirror: Mirror) !bool {
    const r = try std.process.run(c.a, c.io, .{
        .argv = &.{ "curl", "--fail", "--silent", "--location", "--head", "--proto", "=https", "--proto-redir", "=https", "--max-time", "8", "--", try c.fmt("{s}CHECKSUMS.md5.asc", .{mirror.url}) },
        .stdout_limit = .limited(65536),
        .stderr_limit = .limited(4096),
    });
    return r.term == .exited and r.term.exited == 0;
}

pub fn select(c: Context) ![]const u8 {
    const work = try c.temp();
    defer c.run(&.{ "rm", "-rf", "--", work }) catch {};
    const path = try c.fmt("{s}/mirrors.html", .{work});
    try c.download("https://mirrors.slackware.com/mirrorlist/", path);
    const mirrors = try parse(c, try c.read(path));
    var replies: usize = 0;
    for (mirrors, 0..) |*mirror, i| {
        try c.print("Ping {d}/{d}: {s}\n", .{ i + 1, mirrors.len, mirror.host });
        const reply = try std.process.run(c.a, c.io, .{
            .argv = &.{ "env", "LC_ALL=C", "timeout", "3", "ping", "-n", "-c", "1", "-W", "1", "-w", "2", mirror.host },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        if (reply.term != .exited or reply.term.exited != 0) continue;
        mirror.milliseconds = latency(reply.stdout) catch continue;
        replies += 1;
    }
    std.mem.sort(Mirror, mirrors, {}, before);
    if (replies > 0) {
        for (mirrors[0..replies]) |mirror| {
            if (!try available(c, mirror)) continue;
            try c.print("Selected {s} ({d:.2} ms ICMP round trip).\n", .{ mirror.url, mirror.milliseconds });
            return mirror.url;
        }
    }
    var choices: std.ArrayList([]const u8) = .empty;
    for (mirrors, 0..) |mirror, i| try choices.appendSlice(c.a, &.{ try c.fmt("{d}", .{i}), mirror.url });
    const chosen = try tui.menu(c, "No responding mirror passed both ping and HTTPS checks. Select an official mirror.", choices.items);
    const index = try std.fmt.parseInt(usize, chosen, 10);
    if (index >= mirrors.len or !try available(c, mirrors[index])) return error.MirrorUnavailable;
    return mirrors[index].url;
}

pub fn configure(c: Context) !void {
    if (!std.mem.eql(u8, std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return c.run(&.{ "doas", "/usr/bin/owendots", "mirror" });
    _ = try c.read("/etc/slackware-version");
    _ = try @import("media.zig").parse(c, try c.read("/var/lib/owendots/media.json"));
    const chosen = try select(c);
    const path = "/etc/slackpkg/mirrors";
    const backup = "/var/lib/owendots/backup/slackpkg-mirrors";
    const old = try c.read(path);
    _ = c.read(backup) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try c.write(backup, old);
            break :blk old;
        },
        else => return err,
    };
    try c.write(path, try c.fmt("{s}\n", .{chosen}));
    try c.print("Configured the Slackware64-current mirror for slackpkg.\n", .{});
}

test "official mirror parser accepts quoted and unquoted HTTPS links only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const found = try parse(c, "Available https mirrors: <a href=https://mirror.example/slackware/>x</a><a href='https://other.example/pub/'>x</a><a href=\"https://mirror.example/slackware/\">duplicate</a><a href=https://x;id/path/>bad</a>Available http mirrors:<a href=https://ignore.example/>ignored</a>");
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("https://mirror.example/slackware/slackware64-current/", found[0].url);
    try std.testing.expectEqualStrings("other.example", found[1].host);
    try std.testing.expectEqual(@as(f64, 4.5), try latency("rtt min/avg/max/mdev = 4.5/4.5/4.5/0.0 ms\n"));
    try std.testing.expectError(error.NoPingReply, latency("100% packet loss"));
}
