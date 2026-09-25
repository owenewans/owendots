const std = @import("std");
const sys = @import("sys.zig");
const palette = @import("palette.zig");
const desktop = @import("desktop.zig");
const r = @cImport({
    @cInclude("raylib.h");
    @cInclude("raygui.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/wait.h");
});

const Editor = struct {
    values: [palette.keys.len][8:0]u8 = undefined,
    active: ?usize = null,

    fn load(self: *Editor, c: sys.Context, path: []const u8) !void {
        const colors = try palette.parse(c.a, try c.read(path));
        for (palette.keys, 0..) |key, i| {
            @memset(&self.values[i], 0);
            @memcpy(self.values[i][0..7], colors.get(key).?);
        }
    }

    fn color(self: *const Editor, index: usize) !r.Color {
        const text = std.mem.sliceTo(&self.values[index], 0);
        if (text.len != 7 or text[0] != '#') return error.InvalidColor;
        const rgb = try std.fmt.parseInt(u32, text[1..], 16);
        return .{ .r = @intCast(rgb >> 16), .g = @intCast((rgb >> 8) & 255), .b = @intCast(rgb & 255), .a = 255 };
    }

    fn save(self: *const Editor, c: sys.Context, path: []const u8) !void {
        var output: std.Io.Writer.Allocating = .init(c.a);
        for (palette.keys, 0..) |key, i| {
            _ = try self.color(i);
            try output.writer.print("{s} = \"{s}\"\n", .{ key, std.mem.sliceTo(&self.values[i], 0) });
        }
        const temporary = try c.fmt("{s}.owendots-new", .{path});
        try c.write(temporary, output.written());
        try std.Io.Dir.cwd().rename(temporary, .cwd(), path, c.io);
        try desktop.apply(c);
    }
};

fn rect(x: f32, y: f32, w: f32, h: f32) r.Rectangle {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

fn button(x: f32, y: f32, w: f32, label: [:0]const u8) bool {
    return r.GuiButton(rect(x, y, w, 36), label) != 0;
}

fn style(editor: *const Editor) void {
    const background = editor.color(0) catch return;
    const foreground = editor.color(1) catch return;
    const surface = editor.color(2) catch return;
    const accent = editor.color(4) catch return;
    const border = editor.color(5) catch return;
    for ([_]struct { c_int, r.Color }{
        .{ r.BORDER_COLOR_NORMAL, border },  .{ r.BASE_COLOR_NORMAL, surface },     .{ r.TEXT_COLOR_NORMAL, foreground },
        .{ r.BORDER_COLOR_FOCUSED, accent }, .{ r.BASE_COLOR_FOCUSED, background }, .{ r.TEXT_COLOR_FOCUSED, foreground },
        .{ r.BORDER_COLOR_PRESSED, accent }, .{ r.BASE_COLOR_PRESSED, accent },     .{ r.TEXT_COLOR_PRESSED, background },
        .{ r.BACKGROUND_COLOR, background }, .{ r.LINE_COLOR, border },
    }) |item| r.GuiSetStyle(r.DEFAULT, item[0], @bitCast(@as(u32, @bitCast(r.ColorToInt(item[1])))));
    r.GuiSetStyle(r.DEFAULT, r.TEXT_SIZE, 20);
    r.GuiSetStyle(r.DEFAULT, r.TEXT_SPACING, 0);
    r.GuiSetStyle(r.DEFAULT, r.BORDER_WIDTH, 1);
}

fn spawn(c: sys.Context, arguments: []const []const u8) !void {
    // inherited descriptors only; finished GUI launches are reaped in the event loop.
    _ = try std.process.spawn(c.io, .{ .argv = arguments });
}

fn message(buffer: *[256:0]u8, text: []const u8) void {
    @memset(buffer, 0);
    @memcpy(buffer[0..@min(text.len, 255)], text[0..@min(text.len, 255)]);
}

pub fn main(init: std.process.Init) !void {
    if (r.geteuid() == 0) return error.RunAsDesktopUser;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const c: sys.Context = .{ .a = arena.allocator(), .io = init.io, .env = init.environ_map };
    const config = init.environ_map.get("XDG_CONFIG_HOME") orelse try c.fmt("{s}/.config", .{try c.environment("HOME")});
    if (!std.fs.path.isAbsolute(config)) return error.AbsoluteConfigPathRequired;
    const path = try c.fmt("{s}/owendots/palette.toml", .{config});
    var editor: Editor = .{};
    try editor.load(c, path);
    const args = try init.minimal.args.toSlice(c.a);
    r.SetTraceLogLevel(if (args.len == 2 and std.mem.eql(u8, args[1], "--debug")) r.LOG_DEBUG else r.LOG_WARNING);
    _ = r.setenv("SDL_APP_ID", "org.owendots.control", 1);
    if (init.environ_map.get("WAYLAND_DISPLAY") != null) _ = r.setenv("SDL_VIDEODRIVER", "wayland", 0);
    r.SetConfigFlags(r.FLAG_WINDOW_RESIZABLE | r.FLAG_WINDOW_HIGHDPI);
    r.InitWindow(880, 650, "owendots");
    defer r.CloseWindow();
    r.SetWindowMinSize(720, 580);
    r.SetTargetFPS(30);
    const font_path = "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf";
    var font_scale = r.GetWindowScaleDPI().x;
    var font = if (r.FileExists(font_path)) r.LoadFontEx(font_path, @intFromFloat(@round(20 * font_scale)), null, 0) else r.GetFontDefault();
    r.SetTextureFilter(font.texture, r.TEXTURE_FILTER_BILINEAR);
    defer if (r.FileExists(font_path)) r.UnloadFont(font);
    r.GuiSetFont(font);
    var labels: [palette.keys.len][:0]const u8 = undefined;
    for (palette.keys, 0..) |key, i| labels[i] = try c.a.dupeZ(u8, key);
    const color_names = try c.a.dupeZ(u8, try std.mem.join(c.a, ";", &palette.keys));
    var color_index: c_int = 0;
    var color_scroll: c_int = 0;
    var page: enum { home, colors, keys } = .home;
    var status: [256:0]u8 = @splat(0);
    while (!r.WindowShouldClose()) {
        var child_status: c_int = 0;
        while (r.waitpid(-1, &child_status, r.WNOHANG) > 0) {
            if (child_status != 0) message(&status, "Command failed; see the session log.");
        }
        const scale = r.GetWindowScaleDPI().x;
        if (scale != font_scale and r.FileExists(font_path)) {
            r.UnloadFont(font);
            font = r.LoadFontEx(font_path, @intFromFloat(@round(20 * scale)), null, 0);
            r.SetTextureFilter(font.texture, r.TEXTURE_FILTER_BILINEAR);
            r.GuiSetFont(font);
            font_scale = scale;
        }
        style(&editor);
        r.BeginDrawing();
        r.ClearBackground(editor.color(0) catch r.BLACK);
        // raylib's SDL backend reports logical sizes but leaves draw scaling to us.
        r.BeginMode2D(.{ .offset = .{ .x = 0, .y = 0 }, .target = .{ .x = 0, .y = 0 }, .rotation = 0, .zoom = r.GetWindowScaleDPI().x });
        const width: f32 = @floatFromInt(r.GetScreenWidth());
        const height: f32 = @floatFromInt(r.GetScreenHeight());
        _ = r.GuiLabel(rect(20, 14, 200, 30), "owendots");
        if (button(20, 60, 126, "desktop")) page = .home;
        if (button(20, 108, 126, "palette")) page = .colors;
        if (button(20, 156, 126, "keys")) page = .keys;
        if (button(20, height - 58, 126, "close")) break;
        switch (page) {
            .home => {
                const actions = [_]struct { [:0]const u8, []const []const u8 }{
                    .{ "terminal", &.{ "owendots", "launch", "terminal" } },
                    .{ "browser", &.{ "owendots", "launch", "browser" } },
                    .{ "files", &.{ "owendots", "launch", "files" } },
                    .{ "telegram", &.{ "owendots", "launch", "telegram" } },
                    .{ "editor", &.{ "owendots", "launch", "editor" } },
                    .{ "processes", &.{ "owendots", "launch", "monitor" } },
                    .{ "network", &.{ "owendots", "network" } },
                    .{ "audio", &.{ "owendots", "audio" } },
                    .{ "bluetooth", &.{ "owendots", "bluetooth" } },
                    .{ "screenshot", &.{ "owendots", "screenshot" } },
                    .{ "clipboard", &.{ "owendots", "clipboard" } },
                    .{ "power", &.{ "owendots", "power" } },
                    .{ "display", &.{ "owendots", "display" } },
                };
                const cell = (width - 204) / 3;
                for (actions, 0..) |action, i| {
                    if (button(174 + @as(f32, @floatFromInt(i % 3)) * cell, 60 + @as(f32, @floatFromInt(i / 3)) * 52, cell - 12, action[0])) {
                        spawn(c, action[1]) catch |err| message(&status, @errorName(err));
                    }
                }
            },
            .colors => {
                _ = r.GuiListView(rect(174, 60, 190, height - 150), color_names, &color_scroll, &color_index);
                if (color_index < 0) color_index = 0;
                const index: usize = @intCast(color_index);
                var color = try editor.color(index);
                const picker_width = @min(width - 430, 330);
                _ = r.GuiLabel(rect(390, 60, picker_width, 30), labels[index]);
                _ = r.GuiColorPicker(rect(390, 108, picker_width, 260), null, &color);
                _ = try std.fmt.bufPrintZ(&editor.values[index], "#{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b });
                r.DrawRectangleRec(rect(390, 398, picker_width, 42), color);
                if (button(174, height - 90, 160, "apply palette")) {
                    editor.save(c, path) catch |err| {
                        message(&status, @errorName(err));
                        r.EndMode2D();
                        r.EndDrawing();
                        continue;
                    };
                    message(&status, "Saved. Restart applications to reload colors.");
                }
                if (button(510, height - 90, 180, "login / boot")) {
                    const selected = try desktop.choices(c);
                    spawn(c, &.{ @tagName(selected.terminal), "-e", "owendots", "theme", "system" }) catch |err| message(&status, @errorName(err));
                }
                if (button(350, height - 90, 140, "reload file")) editor.load(c, path) catch |err| message(&status, @errorName(err));
            },
            .keys => {
                const keys = [_][:0]const u8{ "Super+Return  terminal", "Super+Space   launcher", "Super+PgUp/Dn workspaces", "Super+Wheel   workspaces", "Super+Arrows  windows", "Super+Shift+Wheel windows", "Super+Shift+E files", "Super+Shift+B browser", "Super+Q       close window", "Super+Comma   settings", "Print         region to clipboard", "Super+Shift+V clipboard history", "Caps Lock     US / RU", "Super+Shift+Q end session" };
                for (keys, 0..) |key, i| _ = r.GuiLabel(rect(174, 60 + @as(f32, @floatFromInt(i)) * 30, width - 194, 28), key);
            },
        }
        _ = r.GuiLabel(rect(174, height - 58, width - 194, 36), &status);
        r.EndMode2D();
        r.EndDrawing();
    }
}
