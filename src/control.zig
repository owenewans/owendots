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
    if (!same(panel, "audio") and !same(panel, "bluetooth") and !same(panel, "power")) return error.UnknownControl;
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
