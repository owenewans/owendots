const std = @import("std");
const sys = @import("sys.zig");
const tui = @import("tui.zig");
const desktop = @import("desktop.zig");
const Context = sys.Context;

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn open(c: Context, panel: []const u8) !void {
    const selected = try desktop.choices(c);
    const app_id = if (selected.terminal == .foot) "--app-id=org.owendots.control" else "--class=org.owendots.control";
    if (same(panel, "network")) return c.run(&.{ @tagName(selected.terminal), app_id, "-e", "nmtui" });
    if (!same(panel, "audio") and !same(panel, "bluetooth") and !same(panel, "power") and !same(panel, "display")) return error.UnknownControl;
    return c.run(&.{ @tagName(selected.terminal), app_id, "-e", "/usr/bin/owendots", "control", panel });
}

fn audio(c: Context) !void {
    const action = try tui.menu(c, "Audio / PipeWire", &.{ "volume", "Set output volume", "mute", "Toggle output mute", "microphone", "Toggle microphone mute", "output", "Choose output device", "input", "Choose input device", "status", "Show audio graph" });
    if (same(action, "volume")) {
        const number = try std.fmt.parseInt(u8, try tui.input(c, "Volume percentage (0-100)", "50"), 10);
        if (number > 100) return error.InvalidVolume;
        return c.run(&.{ "wpctl", "set-volume", "--limit", "1.0", "@DEFAULT_AUDIO_SINK@", try c.fmt("{d}%", .{number}) });
    }
    if (same(action, "mute")) return c.run(&.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" });
    if (same(action, "microphone")) return c.run(&.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" });
    if (same(action, "status")) {
        _ = try tui.dialog(c, &.{ "--msgbox", try c.capture(&.{ "wpctl", "status" }), "30", "100" });
        return;
    }
    const media_class = if (same(action, "output")) "Audio/Sink" else "Audio/Source";
    const dump = try std.json.parseFromSlice(std.json.Value, c.a, try c.capture(&.{"pw-dump"}), .{});
    if (dump.value != .array) return error.InvalidAudioGraph;
    var items: std.ArrayList([]const u8) = .empty;
    for (dump.value.array.items) |node| {
        if (node != .object) continue;
        const info = node.object.get("info") orelse continue;
        if (info != .object) continue;
        const props = info.object.get("props") orelse continue;
        if (props != .object) continue;
        const class = props.object.get("media.class") orelse continue;
        if (class != .string or !same(class.string, media_class)) continue;
        const id = node.object.get("id") orelse continue;
        if (id != .integer or id.integer < 0) continue;
        const label = props.object.get("node.description") orelse props.object.get("node.name") orelse continue;
        if (label != .string) continue;
        try items.appendSlice(c.a, &.{ try c.fmt("{d}", .{id.integer}), label.string });
    }
    if (items.items.len == 0) return error.NoAudioDevices;
    const chosen = try tui.menu(c, "Choose the default audio device", items.items);
    _ = try std.fmt.parseInt(u32, chosen, 10);
    try c.run(&.{ "wpctl", "set-default", chosen });
}

fn bluetooth(c: Context) !void {
    const action = try tui.menu(c, "Bluetooth", &.{ "on", "Enable service and controller", "off", "Disable service", "scan", "Scan for devices (15 seconds)", "connect", "Connect a known device", "pair", "Pair and connect", "disconnect", "Disconnect a device" });
    if (same(action, "on") or same(action, "off")) {
        try c.run(&.{ "doas", "/usr/bin/owendots", "service", "bluetooth", action });
        if (same(action, "on")) try c.run(&.{ "bluetoothctl", "power", "on" });
        return;
    }
    if (same(action, "scan")) return c.run(&.{ "bluetoothctl", "--timeout", "15", "scan", "on" });
    const devices = try c.capture(&.{ "bluetoothctl", "devices" });
    var items: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, devices, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Device ") or line.len < 25) continue;
        const address = line[7..24];
        if (!validAddress(address)) continue;
        try items.appendSlice(c.a, &.{ address, line[25..] });
    }
    if (items.items.len == 0) return error.NoBluetoothDevices;
    const address = try tui.menu(c, "Bluetooth device", items.items);
    if (!validAddress(address)) return error.InvalidBluetoothAddress;
    if (same(action, "pair")) {
        try c.run(&.{ "bluetoothctl", "pair", address });
        try c.run(&.{ "bluetoothctl", "trust", address });
    }
    try c.run(&.{ "bluetoothctl", if (same(action, "disconnect")) "disconnect" else "connect", address });
}

pub fn validAddress(address: []const u8) bool {
    if (address.len != 17) return false;
    for (address, 0..) |ch, i| {
        if (i % 3 == 2) {
            if (ch != ':') return false;
        } else if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

pub fn run(c: Context, panel: []const u8) !void {
    if (same(panel, "display")) return display(c);
    if (same(panel, "audio")) return audio(c);
    if (same(panel, "bluetooth")) return bluetooth(c);
    if (same(panel, "power")) {
        const action = try tui.menu(c, "Power", &.{ "back", "Return to the desktop", "suspend", "Suspend", "logout", "End this graphical session", "reboot", "Reboot", "poweroff", "Power off" });
        if (same(action, "back")) return;
        if (same(action, "logout")) {
            if ((try desktop.choices(c)).compositor == .niri) return c.run(&.{ "niri", "msg", "action", "quit", "--skip-confirmation" });
            return c.run(&.{ "swaymsg", "exit" });
        }
        return c.run(&.{ "loginctl", action });
    }
    return error.UnknownControl;
}

fn display(c: Context) !void {
    const compositor = (try desktop.choices(c)).compositor;
    const dump = try c.capture(if (compositor == .niri) &.{ "niri", "msg", "--json", "outputs" } else &.{ "swaymsg", "-t", "get_outputs", "-r" });
    const value = (try std.json.parseFromSlice(std.json.Value, c.a, dump, .{})).value;
    var outputs: std.ArrayList(std.json.Value) = .empty;
    var items: std.ArrayList([]const u8) = .empty;
    if (compositor == .niri and value == .object) {
        var it = value.object.iterator();
        while (it.next()) |entry| try outputs.append(c.a, entry.value_ptr.*);
    } else if (value == .array) try outputs.appendSlice(c.a, value.array.items) else return error.InvalidDisplayInfo;
    for (outputs.items) |output| {
        if (output != .object) return error.InvalidDisplayInfo;
        const name = output.object.get("name") orelse return error.InvalidDisplayInfo;
        if (name != .string or !sys.safeName(name.string)) return error.InvalidOutputName;
        try items.appendSlice(c.a, &.{ name.string, name.string });
    }
    if (items.items.len == 0) return error.NoDisplay;
    const chosen = try tui.menu(c, "Monitor", items.items);
    var modes: std.ArrayList(@import("display.zig").Settings) = .empty;
    items.clearRetainingCapacity();
    for (outputs.items) |output| {
        if (!same(output.object.get("name").?.string, chosen)) continue;
        const available = output.object.get("modes") orelse return error.InvalidDisplayInfo;
        if (available != .array) return error.InvalidDisplayInfo;
        for (available.array.items) |mode| {
            if (mode != .object) return error.InvalidDisplayInfo;
            const settings: @import("display.zig").Settings = .{
                .output = chosen,
                .width = try integer(mode, "width"),
                .height = try integer(mode, "height"),
                .refresh = try integer(mode, if (compositor == .niri) "refresh_rate" else "refresh"),
                .scale = 100,
            };
            try items.appendSlice(c.a, &.{ try c.fmt("{d}", .{modes.items.len}), try settings.mode(c) });
            try modes.append(c.a, settings);
        }
    }
    if (modes.items.len == 0) return error.NoDisplayModes;
    const index = try std.fmt.parseInt(usize, try tui.menu(c, "Resolution / refresh rate", items.items), 10);
    if (index >= modes.items.len) return error.InvalidDisplayMode;
    var settings = modes.items[index];
    settings.scale = try std.fmt.parseInt(u16, try tui.input(c, "Scale percentage (50-400)", "100"), 10);
    try settings.validate();
    const path = try c.fmt("{s}/owendots/display.json", .{try desktop.config(c)});
    const old = c.read(path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var keep = false;
    defer if (!keep) {
        if (old) |text| {
            c.write(path, text) catch {};
        } else {
            c.run(&.{ "rm", "-f", "--", path }) catch {};
        }
        desktop.apply(c) catch {};
        if (compositor == .scroll) c.run(&.{ "swaymsg", "reload" }) catch {};
    };
    try c.write(path, try std.json.Stringify.valueAlloc(c.a, settings, .{ .whitespace = .indent_2 }));
    try desktop.apply(c);
    if (compositor == .scroll) try c.run(&.{ "swaymsg", "reload" });
    _ = try tui.dialog(c, &.{ "--timeout", "15", "--defaultno", "--yesno", "Keep this display mode?\nCancel or wait 15 seconds to restore the previous configuration.", "10", "76" });
    keep = true;
}

fn integer(object: std.json.Value, key: []const u8) !u32 {
    const value = object.object.get(key) orelse return error.InvalidDisplayInfo;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.InvalidDisplayInfo;
    return @intCast(value.integer);
}

pub fn service(c: Context, name: []const u8, action: []const u8) !void {
    if (!same(name, "bluetooth") or (!same(action, "on") and !same(action, "off"))) return error.UnknownServiceAction;
    if (!same(std.mem.trim(u8, try c.capture(&.{ "id", "-u" }), "\n"), "0")) return error.RootRequired;
    _ = try c.read("/etc/slackware-version");
    const path = "/etc/rc.d/rc.bluetooth";
    if (same(action, "on")) {
        try c.run(&.{ "chmod", "755", path });
        try c.run(&.{ path, "start" });
    } else {
        try c.run(&.{ "sh", path, "stop" });
        try c.run(&.{ "chmod", "644", path });
    }
}

test "Bluetooth addresses are literal device identifiers" {
    try std.testing.expect(validAddress("01:23:45:67:89:AB"));
    try std.testing.expect(!validAddress("--help"));
    try std.testing.expect(!validAddress("01:23:45:67:89;AB"));
    try std.testing.expect(!validAddress("01:23:45:67:89:GG"));
}
