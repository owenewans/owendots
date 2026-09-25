const std = @import("std");
const Context = @import("sys.zig").Context;

pub const keys = [_][]const u8{
    "background",  "foreground",     "surface",      "muted",        "accent",       "border",
    "black",       "red",            "green",        "yellow",       "blue",         "magenta",
    "cyan",        "white",          "bright_black", "bright_red",   "bright_green", "bright_yellow",
    "bright_blue", "bright_magenta", "bright_cyan",  "bright_white",
};
pub const Palette = std.StringHashMap([]const u8);

pub fn parse(a: std.mem.Allocator, data: []const u8) !Palette {
    var result = Palette.init(a);
    errdefer result.deinit();
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidPaletteLine;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        var known = false;
        for (keys) |name| if (std.mem.eql(u8, name, key)) {
            known = true;
            break;
        };
        if (!known) return error.UnknownPaletteKey;
        if (result.contains(key)) return error.DuplicatePaletteKey;
        if (value.len != 9 or value[0] != '"' or value[1] != '#' or value[8] != '"') return error.InvalidColor;
        for (value[2..8]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidColor;
        try result.put(key, value[1..8]);
    }
    for (keys) |key| if (!result.contains(key)) return error.MissingPaletteColor;
    return result;
}

pub fn render(a: std.mem.Allocator, input: []const u8, colors: Palette) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, input, pos, "{{")) |start| {
        try output.writer.writeAll(input[pos..start]);
        const end = std.mem.indexOfPos(u8, input, start + 2, "}}") orelse return error.UnclosedTemplateToken;
        var key = input[start + 2 .. end];
        const bare = std.mem.endsWith(u8, key, ":hex");
        if (bare) key = key[0 .. key.len - 4];
        const color = colors.get(key) orelse return error.UnknownTemplateToken;
        try output.writer.writeAll(if (bare) color[1..] else color);
        pos = end + 2;
    }
    try output.writer.writeAll(input[pos..]);
    return output.toOwnedSlice();
}

pub fn generate(c: Context, palette_path: []const u8, templates: []const u8, output: []const u8) !void {
    const colors = try parse(c.a, try c.read(palette_path));
    const paths = try c.capture(&.{ "find", templates, "-type", "f", "-printf", "%P\\0" });
    var files = std.mem.splitScalar(u8, paths, 0);
    // Render the entire generation before changing output files.
    var pending: std.ArrayList(struct { path: []const u8, data: []const u8 }) = .empty;
    while (files.next()) |path| {
        if (path.len == 0) continue;
        if (!@import("sys.zig").safePath(path)) return error.InvalidTemplatePath;
        const data = try render(c.a, try c.read(try c.fmt("{s}/{s}", .{ templates, path })), colors);
        try pending.append(c.a, .{ .path = try c.fmt("{s}/{s}", .{ output, path }), .data = data });
    }
    for (pending.items) |item| {
        const temporary = try c.fmt("{s}.owendots-new", .{item.path});
        try c.write(temporary, item.data);
        try std.Io.Dir.cwd().rename(temporary, .cwd(), item.path, c.io);
    }
    try c.print("generated {d} configuration files in {s}\n", .{ pending.items.len, output });
}

test "palette templates reject unknown substitutions" {
    var colors = Palette.init(std.testing.allocator);
    defer colors.deinit();
    try colors.put("background", "#102030");
    const rendered = try render(std.testing.allocator, "bg={{background}};raw={{background:hex}}", colors);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("bg=#102030;raw=102030", rendered);
    try std.testing.expectError(error.UnknownTemplateToken, render(std.testing.allocator, "{{missing}}", colors));
}
