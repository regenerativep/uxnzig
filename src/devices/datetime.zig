const std = @import("std");

const time = @import("../vendor/time.zig");

const uxn = @import("../uxn.zig");

pub fn datetimeDei(u: *uxn.Uxn, dev: *uxn.Device, port: u8) u8 {
    _ = u;
    const tm = time.DateTime.now();
    return switch (port) {
        0x0 => @truncate(u8, tm.years >> 8),
        0x1 => @truncate(u8, tm.years),
        0x2 => @truncate(u8, tm.months),
        0x3 => @truncate(u8, tm.days),
        0x4 => @truncate(u8, tm.hours),
        0x5 => @truncate(u8, tm.minutes),
        0x6 => @truncate(u8, tm.seconds),
        0x7 => @enumToInt(tm.weekday),
        0x8 => @truncate(u8, tm.dayOfThisYear() >> 8),
        0x9 => @truncate(u8, tm.dayOfThisYear()),
        0xa => 0, // TODO: obtain daylight savings info
        else => dev.data[port],
    };
}
pub const device = uxn.Device{ .dei = datetimeDei };
