const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "owendots", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run owendots").dependOn(&run.step);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    b.step("test", "Test parsers and package rules").dependOn(&tests.step);
    if (b.option([]const u8, "gui-deps", "Raylib/Raygui installation prefix")) |prefix| {
        const gui_module = b.createModule(.{ .root_source_file = b.path("src/gui.zig"), .target = target, .optimize = optimize, .link_libc = true });
        gui_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        gui_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        gui_module.addCSourceFile(.{ .file = b.path("src/raygui.c"), .flags = &.{"-O2"} });
        gui_module.linkSystemLibrary("raylib", .{ .preferred_link_mode = .static });
        gui_module.linkSystemLibrary("SDL3", .{});
        gui_module.linkSystemLibrary("m", .{});
        const gui = b.addExecutable(.{ .name = "owenctl", .root_module = gui_module });
        b.step("gui", "Build the Raygui desktop controls").dependOn(&b.addInstallArtifact(gui, .{}).step);
    }
}
