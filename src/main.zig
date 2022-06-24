const std = @import("std");

const uxn = @import("uxn.zig");
const devSystem = @import("devices/system.zig");
const devDatetime = @import("devices/datetime.zig");
const devFile = @import("devices/file.zig");

fn consoleDeo(ctx: uxn.DeviceContext, device: *uxn.Device, port: u8) void {
    _ = ctx;
    var file = switch (port) {
        0x8 => std.io.getStdOut(),
        0x9 => std.io.getStdErr(),
        else => return,
    };
    // TODO: do we want to use the mutex for stderr?
    file.writer().writeByte(device.data[port]) catch |e| std.debug.panic("std err or out error :( : {any}", .{e});
    // i dont think we need to flush here?
}

const console_device = .{ .deo = consoleDeo };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    if (!args.skip()) return std.log.err("what", .{});
    const rom_filename = args.next() orelse return std.log.err("no rom file specified", .{});

    var ram = try alloc.alloc(u8, 0x10000);
    defer alloc.free(ram);
    std.mem.set(u8, ram, 0);

    var file0 = devFile.UxnFile{};
    defer file0.close();
    var file1 = devFile.UxnFile{};
    defer file1.close();

    var u = uxn.Uxn{
        .ram = ram,
        .dev = [_]uxn.Device{
            devSystem.system_device, //0x00
            console_device, //0x01
            .{}, //0x02
            .{}, //0x03
            .{}, //0x04
            .{}, //0x05
            .{}, //0x06
            .{}, //0x07
            .{}, //0x08
            .{}, //0x09
            file0.getDevice(), //0x0a
            file1.getDevice(), //0x0b
            devDatetime.datetime_device, //0x0c
            .{}, //0x0d
            .{}, //0x0e
            .{}, //0x0f
        },
    };
    _ = try u.loadRom(rom_filename);
    try u.eval(uxn.PageProgram);

    while (args.next()) |p| {
        for (p) |c| try u.consoleInput(c);
        try u.consoleInput('\n');
    }

    var stdin = std.io.getStdIn();
    defer stdin.close();
    var reader = stdin.reader();
    var system_device = &u.dev[0];
    while (system_device.data[0xf] == 0) {
        const c = reader.readByte() catch |e| {
            if (e == error.EndOfStream) continue else return e;
        };
        //try u.consoleInput(c); // uxncli actually relies on not handling this error??
        u.consoleInput(c) catch {};
    }
}
