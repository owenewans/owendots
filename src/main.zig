const std = @import("std");
const sys = @import("sys.zig");
const palette = @import("palette.zig");
const storage = @import("storage.zig");
const boot = @import("boot.zig");
const tui = @import("tui.zig");
const system = @import("system.zig");
const data = @import("data.zig");
const media = @import("media.zig");
const installer = @import("installer.zig");
const desktop = @import("desktop.zig");
const control = @import("control.zig");
const login = @import("login.zig");

fn execute(c: sys.Context, args: []const []const u8) !void {
    if (args.len == 1 or std.mem.eql(u8, args[1], "--help")) {
        return c.print("owendots - Slackware workstation tools\n\nowendots theme generate PALETTE TEMPLATES OUTPUT\nowendots theme apply\nowendots configure\nowendots launch terminal|browser|files|telegram|monitor|editor [ARGS...]\nowendots screenshot|clipboard\nowendots install MEDIA_DIRECTORY (live environment only)\n", .{});
    }
    if (args.len == 7 and std.mem.eql(u8, args[1], "theme") and std.mem.eql(u8, args[2], "generate")) return error.TooManyArguments;
    if (args.len == 6 and std.mem.eql(u8, args[1], "theme") and std.mem.eql(u8, args[2], "generate")) {
        return palette.generate(c, args[3], args[4], args[5]);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "install")) return installer.start(c, args[2]);
    if (args.len == 3 and std.mem.eql(u8, args[1], "theme") and std.mem.eql(u8, args[2], "apply")) return desktop.apply(c);
    if (args.len == 2 and std.mem.eql(u8, args[1], "configure")) return desktop.configure(c);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "launch")) return desktop.launch(c, args[2], args[3..]);
    if (args.len == 2 and std.mem.eql(u8, args[1], "screenshot")) return desktop.screenshot(c);
    if (args.len == 2 and std.mem.eql(u8, args[1], "clipboard")) return desktop.clipboard(c);
    if (args.len == 2 and (std.mem.eql(u8, args[1], "network") or std.mem.eql(u8, args[1], "audio") or std.mem.eql(u8, args[1], "bluetooth") or std.mem.eql(u8, args[1], "power"))) return control.open(c, args[1]);
    if (args.len == 3 and std.mem.eql(u8, args[1], "control")) return control.run(c, args[2]);
    if (args.len == 4 and std.mem.eql(u8, args[1], "service")) return control.service(c, args[2], args[3]);
    if (args.len == 2 and std.mem.eql(u8, args[1], "desktop-system")) return system.desktop(c);
    if (args.len == 2 and std.mem.eql(u8, args[1], "display-manager")) return login.enable(c);
    if (args.len == 2 and std.mem.eql(u8, args[1], "session-ready")) return c.run(&.{ "/usr/libexec/owendots/session", "ready" });
    if (args.len == 3 and std.mem.eql(u8, args[1], "session")) {
        if (!std.mem.eql(u8, args[2], "niri") and !std.mem.eql(u8, args[2], "scroll")) return error.UnknownCompositor;
        return c.run(&.{ "/usr/libexec/owendots/session", args[2] });
    }
    return error.UnknownCommand;
}

pub fn main(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const c: sys.Context = .{ .a = arena.allocator(), .io = init.io, .env = init.environ_map };
    execute(c, try init.minimal.args.toSlice(c.a)) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(c.io, try c.fmt("owendots: {s}\n", .{@errorName(err)}));
        return 1;
    };
    return 0;
}

test {
    std.testing.refAllDecls(palette);
    std.testing.refAllDecls(storage);
    std.testing.refAllDecls(boot);
    std.testing.refAllDecls(tui);
    std.testing.refAllDecls(system);
    std.testing.refAllDecls(data);
    std.testing.refAllDecls(media);
    std.testing.refAllDecls(installer);
    std.testing.refAllDecls(desktop);
    std.testing.refAllDecls(control);
    std.testing.refAllDecls(login);
}
