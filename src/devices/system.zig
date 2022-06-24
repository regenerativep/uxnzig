const std = @import("std");

const uxn = @import("../uxn.zig");

pub fn systemDeoSpecial(ctx: uxn.DeviceContext, device: *uxn.Device, port: u8) void {
    _ = ctx;
    _ = device;
    _ = port;
}
pub fn systemInspect(u: *uxn.Uxn) !void {
    var writer = std.io.getStdErr().writer();
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    try u.wst.write(writer, "wst");
    try u.rst.write(writer, "rst");
}
pub fn systemDei(ctx: uxn.DeviceContext, device: *uxn.Device, port: u8) u8 {
    return switch (port) {
        0x2 => ctx.uxn.wst.len,
        0x3 => ctx.uxn.rst.len,
        else => device.data[port],
    };
}
pub fn systemDeo(ctx: uxn.DeviceContext, device: *uxn.Device, port: u8) void {
    switch (port) {
        0x2 => ctx.uxn.wst.len = device.data[port],
        0x3 => ctx.uxn.rst.len = device.data[port],
        0xe => systemInspect(ctx.uxn) catch std.debug.panic("system io error :(", .{}),
        else => systemDeoSpecial(ctx, device, port),
    }
}

pub const system_device: uxn.Device = .{ .dei = systemDei, .deo = systemDeo };
