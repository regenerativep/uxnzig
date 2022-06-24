const std = @import("std");

const uxn = @import("../uxn.zig");

pub fn systemDeoSpecial(u: *uxn.Uxn, dev: *uxn.Device, port: u8) void {
    // TODO: what is this for
    _ = u;
    _ = dev;
    _ = port;
}
pub fn systemInspect(u: *uxn.Uxn) !void {
    var writer = std.io.getStdErr().writer();
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    try u.wst.write(writer, "wst");
    try u.rst.write(writer, "rst");
}
pub fn systemDei(u: *uxn.Uxn, dev: *uxn.Device, port: u8) u8 {
    return switch (port) {
        0x2 => u.wst.len,
        0x3 => u.rst.len,
        else => dev.data[port],
    };
}
pub fn systemDeo(u: *uxn.Uxn, dev: *uxn.Device, port: u8) void {
    switch (port) {
        0x2 => u.wst.len = dev.data[port],
        0x3 => u.rst.len = dev.data[port],
        0xe => systemInspect(u) catch std.debug.panic("system io error :(", .{}),
        else => systemDeoSpecial(u, dev, port),
    }
}

pub const device: uxn.Device = .{ .dei = systemDei, .deo = systemDeo };
