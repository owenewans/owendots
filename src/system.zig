const std = @import("std");
const sys = @import("sys.zig");
const storage = @import("storage.zig");
const Context = sys.Context;

pub const Ssh = enum { disabled, keys, passwords };
pub const Mount = struct { uuid: []const u8, path: []const u8, filesystem: storage.Filesystem };
pub const Config = struct {
    hostname: []const u8,
    ssh: Ssh,
    bluetooth: bool = false,
    mounts: []const Mount,
};

pub fn validUser(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.ascii.isLower(name[0])) return false;
    for (name) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_' and ch != '-') return false;
    return !std.mem.eql(u8, name, "root");
}

pub fn validHostname(name: []const u8) bool {
    if (name.len == 0 or name.len > 253) return false;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}

pub fn fstab(a: std.mem.Allocator, mounts: []const Mount) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var root = false;
    for (mounts, 0..) |mount, index| {
        if (mount.uuid.len == 0 or mount.uuid.len > 64) return error.InvalidUuid;
        for (mount.uuid) |ch| if (!std.ascii.isHex(ch) and ch != '-') return error.InvalidUuid;
        const allowed = [_][]const u8{ "/", "/boot/limine", "/boot/efi", "/home" };
        var found = false;
        for (allowed) |path| if (std.mem.eql(u8, mount.path, path)) {
            found = true;
        };
        if (!found) return error.InvalidMount;
        for (mounts[0..index]) |other| {
            if (std.mem.eql(u8, other.path, mount.path) or std.mem.eql(u8, other.uuid, mount.uuid)) return error.DuplicateMount;
        }
        if (std.mem.eql(u8, mount.path, "/")) {
            root = true;
            if (mount.filesystem == .fat32) return error.InvalidRootFilesystem;
        }
        const fs = if (mount.filesystem == .fat32) "vfat" else @tagName(mount.filesystem);
        const options = if (mount.filesystem == .fat32) "defaults,umask=0077" else "defaults,noatime";
        const pass: u8 = if (mount.filesystem == .xfs or mount.filesystem == .fat32) 0 else if (std.mem.eql(u8, mount.path, "/")) 1 else 2;
        try out.writer.print("UUID={s} {s} {s} {s} 0 {d}\n", .{ mount.uuid, mount.path, fs, options, pass });
    }
    if (!root) return error.MissingRoot;
    try out.writer.writeAll("devpts /dev/pts devpts gid=5,mode=620 0 0\nproc /proc proc defaults 0 0\nsysfs /sys sysfs defaults 0 0\ntmpfs /dev/shm tmpfs defaults,nosuid,nodev 0 0\n");
    return out.toOwnedSlice();
}

pub fn configure(c: Context, target: []const u8, config: Config) !void {
    const root = try c.absolute(target);
    if (std.mem.eql(u8, root, "/")) return error.TargetIsHostRoot;
    if (!validHostname(config.hostname)) return error.InvalidHostname;
    const mounts = try fstab(c.a, config.mounts);
    try c.write(try c.fmt("{s}/etc/fstab", .{root}), mounts);
    try c.write(try c.fmt("{s}/etc/HOSTNAME", .{root}), try c.fmt("{s}\n", .{config.hostname}));
    const short = config.hostname[0 .. std.mem.indexOfScalar(u8, config.hostname, '.') orelse config.hostname.len];
    try c.write(try c.fmt("{s}/etc/hosts", .{root}), try c.fmt("127.0.0.1 localhost\n::1 localhost\n127.0.1.1 {s} {s}\n", .{ config.hostname, short }));
    try c.write(try c.fmt("{s}/etc/profile.d/lang.sh", .{root}), "export LANG=en_US.UTF-8\n");
    try c.write(try c.fmt("{s}/etc/profile.d/lang.csh", .{root}), "setenv LANG en_US.UTF-8\n");
    try c.write(try c.fmt("{s}/etc/environment", .{root}), "LANG=en_US.UTF-8\nTZ=UTC\n");
    try c.write(try c.fmt("{s}/etc/fish/conf.d/00-owendots.fish", .{root}), "set -gx LANG en_US.UTF-8\nset -gx TZ UTC\n");
    try c.write(try c.fmt("{s}/etc/hardwareclock", .{root}), "UTC\n");
    try c.run(&.{ "ln", "-sfn", "../usr/share/zoneinfo/UTC", try c.fmt("{s}/etc/localtime", .{root}) });
    try c.write(try c.fmt("{s}/etc/ssh/sshd_config.d/owendots.conf", .{root}), try c.fmt("PermitRootLogin prohibit-password\nPubkeyAuthentication yes\nSetEnv LANG=en_US.UTF-8 TZ=UTC\nPasswordAuthentication {s}\nKbdInteractiveAuthentication no\n", .{if (config.ssh == .passwords) "yes" else "no"}));
    // Slackware's default file does not consistently include a drop-in directory.
    const ssh_path = try c.fmt("{s}/etc/ssh/sshd_config", .{root});
    const ssh_config = c.read(ssh_path) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    if (std.mem.indexOf(u8, ssh_config, "Include /etc/ssh/sshd_config.d/owendots.conf") == null) {
        try c.write(ssh_path, try c.fmt("Include /etc/ssh/sshd_config.d/owendots.conf\n{s}", .{ssh_config}));
    }
    const services = [_]struct { []const u8, bool }{ .{ "rc.networkmanager", true }, .{ "rc.messagebus", true }, .{ "rc.sshd", config.ssh != .disabled }, .{ "rc.bluetooth", config.bluetooth }, .{ "rc.inet1", true }, .{ "rc.wireless", false } };
    for (services) |service| {
        const path = try c.fmt("{s}/etc/rc.d/{s}", .{ root, service[0] });
        const file = std.Io.Dir.cwd().openFile(c.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        file.close(c.io);
        try c.run(&.{ "chmod", if (service[1]) "0755" else "0644", path });
    }
    try c.write(try c.fmt("{s}/etc/default/zram", .{root}),
        \\ZRAM_ENABLE=1
        \\ZRAMSIZE=$(awk '/^MemTotal:/ { n=int($2/2); if (n>8388608) n=8388608; printf "%.0f", n }' /proc/meminfo)
        \\ZRAMNUMBER=1
        \\ZRAMCOMPRESSION=zstd
        \\ZRAMPRIORITY=100
        \\
    );
    try c.write(try c.fmt("{s}/etc/NetworkManager/conf.d/90-owendots.conf", .{root}), "[main]\ndhcp=internal\n");
}

pub fn password(c: Context, target: []const u8, user: []const u8, secret: []const u8) !void {
    if (!std.mem.eql(u8, user, "root") and !validUser(user)) return error.InvalidUsername;
    if (secret.len == 0) return error.EmptyPassword;
    for (secret) |ch| if (ch == 0 or ch == '\n' or ch == '\r') return error.InvalidPassword;
    if (std.mem.eql(u8, try c.absolute(target), "/")) return error.TargetIsHostRoot;
    var child = try std.process.spawn(c.io, .{ .argv = &.{ "chroot", target, "/usr/sbin/chpasswd" }, .stdin = .pipe });
    defer child.kill(c.io);
    try child.stdin.?.writeStreamingAll(c.io, try c.fmt("{s}:{s}\n", .{ user, secret }));
    child.stdin.?.close(c.io);
    child.stdin = null;
    const result = try child.wait(c.io);
    if (result != .exited or result.exited != 0) return error.PasswordChangeFailed;
}

pub fn addUser(c: Context, target: []const u8, user: []const u8, wheel: bool, secret: []const u8) !void {
    if (!validUser(user)) return error.InvalidUsername;
    if (std.mem.eql(u8, try c.absolute(target), "/")) return error.TargetIsHostRoot;
    const groups = if (wheel) "audio,video,input,plugdev,netdev,power,wheel" else "audio,video,input,plugdev,netdev,power";
    try c.run(&.{ "chroot", target, "/usr/sbin/useradd", "-m", "-g", "users", "-G", groups, "-s", "/usr/bin/fish", "--", user });
    try password(c, target, user, secret);
}

pub fn desktop(c: Context) !void {
    if (!std.mem.eql(u8, std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return error.RootRequired;
    _ = try c.read("/etc/slackware-version");
    _ = try @import("media.zig").parse(c, try c.read("/var/lib/owendots/media.json"));
    // glib rejects session bus environment variables for capability-marked executables.
    // grant audio scheduling through PAM limits instead, effective on the next login.
    try c.write("/etc/security/limits.d/90-owendots-audio.conf", "@audio - rtprio 80\n@audio - nice -11\n@audio - memlock 524288\n");
    for ([_][]const u8{ "/usr/bin/pipewire", "/usr/bin/wireplumber" }) |path| {
        const caps = try c.capture(&.{ "/sbin/getcap", path });
        if (std.mem.trim(u8, caps, "\r\n ").len > 0) try c.run(&.{ "/sbin/setcap", "-r", path });
    }
    const pulse = "/etc/rc.d/rc.pulseaudio";
    const file = std.Io.Dir.cwd().openFile(c.io, pulse, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (file) |f| {
        f.close(c.io);
        try c.run(&.{ "chmod", "644", pulse });
    }
    try c.print("Configured PipeWire scheduling for the audio group. Log out and back in.\n", .{});
}

test "identity validation rejects shell and configuration injection" {
    try std.testing.expect(validUser("owenewans"));
    try std.testing.expect(!validUser("root"));
    try std.testing.expect(!validUser("-u0"));
    try std.testing.expect(validHostname("x99.owenewans.org"));
    try std.testing.expect(!validHostname("x99\nlocalhost"));
    try std.testing.expect(!validHostname("x99..org"));
}

test "fstab preserves explicit filesystems and has no disk swap" {
    const text = try fstab(std.testing.allocator, &.{ .{ .uuid = "abc-123", .path = "/", .filesystem = .f2fs }, .{ .uuid = "ab-cd", .path = "/boot/efi", .filesystem = .fat32 } });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "f2fs defaults,noatime 0 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "vfat defaults,umask=0077 0 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "swap") == null);
}

test "target configuration is repeatable and retains SSH root key access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const root = try c.temp();
    defer std.Io.Dir.cwd().deleteTree(c.io, root) catch {};
    for ([_][]const u8{ "rc.networkmanager", "rc.messagebus", "rc.sshd", "rc.bluetooth", "rc.inet1" }) |name| {
        try c.write(try c.fmt("{s}/etc/rc.d/{s}", .{ root, name }), "#!/bin/sh\n");
    }
    const config: Config = .{ .hostname = "x99.owenewans.org", .ssh = .keys, .mounts = &.{ .{ .uuid = "abc-123", .path = "/", .filesystem = .ext4 }, .{ .uuid = "def-456", .path = "/boot/limine", .filesystem = .fat32 } } };
    try configure(c, root, config);
    try configure(c, root, config);
    const ssh = try c.read(try c.fmt("{s}/etc/ssh/sshd_config", .{root}));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ssh, "Include"));
    const policy = try c.read(try c.fmt("{s}/etc/ssh/sshd_config.d/owendots.conf", .{root}));
    try std.testing.expect(std.mem.indexOf(u8, policy, "PermitRootLogin prohibit-password") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "PasswordAuthentication no") != null);
    try std.testing.expectEqualStrings("755", std.mem.trim(u8, try c.capture(&.{ "stat", "-c", "%a", try c.fmt("{s}/etc/rc.d/rc.networkmanager", .{root}) }), "\n"));
    try std.testing.expectEqualStrings("644", std.mem.trim(u8, try c.capture(&.{ "stat", "-c", "%a", try c.fmt("{s}/etc/rc.d/rc.bluetooth", .{root}) }), "\n"));
    try std.testing.expectError(error.TargetIsHostRoot, configure(c, "/", config));
}
