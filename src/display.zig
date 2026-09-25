const std = @import("std");
const sys = @import("sys.zig");

pub const Settings = struct {
    output: []const u8,
    width: u32,
    height: u32,
    refresh: u32,
    scale: u16,

    pub fn validate(self: Settings) !void {
        if (!sys.safeName(self.output)) return error.InvalidOutputName;
        if (self.width < 320 or self.width > 16384 or self.height < 200 or self.height > 16384) return error.InvalidResolution;
        if (self.refresh < 1000 or self.refresh > 1000000) return error.InvalidRefreshRate;
        if (self.scale < 50 or self.scale > 400) return error.InvalidScale;
    }

    pub fn mode(self: Settings, c: sys.Context) ![]const u8 {
        try self.validate();
        return c.fmt("{d}x{d}@{d}.{d:0>3}", .{ self.width, self.height, self.refresh / 1000, self.refresh % 1000 });
    }
};

pub fn append(c: sys.Context, config: []const u8, stage: []const u8) !void {
    const source = c.read(try c.fmt("{s}/owendots/display.json", .{config})) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(Settings, c.a, source, .{});
    const settings = parsed.value;
    try settings.validate();
    const mode = try settings.mode(c);
    const scale = try c.fmt("{d}.{d:0>2}", .{ settings.scale / 100, settings.scale % 100 });
    const niri = try c.fmt("{s}/niri/config.kdl", .{stage});
    const scroll = try c.fmt("{s}/scroll/config", .{stage});
    try c.write(niri, try c.fmt("{s}\noutput \"{s}\" {{\n    mode \"{s}\"\n    scale {s}\n}}\n", .{ try c.read(niri), settings.output, mode, scale }));
    try c.write(scroll, try c.fmt("{s}\noutput {s} mode {s}Hz scale {s}\n", .{ try c.read(scroll), settings.output, mode, scale }));
}

test "display settings reject configuration injection and retain millihertz" {
    const c: sys.Context = .{ .a = std.testing.allocator, .io = std.testing.io };
    var settings: Settings = .{ .output = "DP-1", .width = 1920, .height = 1080, .refresh = 59940, .scale = 125 };
    const mode = try settings.mode(c);
    defer c.a.free(mode);
    try std.testing.expectEqualStrings("1920x1080@59.940", mode);
    settings.output = "DP-1\";exec id";
    try std.testing.expectError(error.InvalidOutputName, settings.validate());
    settings.output = "DP-1";
    settings.scale = 0;
    try std.testing.expectError(error.InvalidScale, settings.validate());
}
