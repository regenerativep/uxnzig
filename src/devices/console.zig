const std = @import("std");
const fs = std.fs;

const uxn = @import("../uxn.zig");

pub const UxnConsole = struct {
    stdout: ?fs.File = null,
    stderr: ?fs.File = null,

    pub fn device(self: *UxnConsole) uxn.Device {
        return .{
            .deo = consoleDeo,
            .state = self,
        };
    }

    fn consoleDeo(u: *uxn.Uxn, dev: *uxn.Device, port: u8) void {
        _ = u;
        var self = @ptrCast(*UxnConsole, @alignCast(@alignOf(UxnConsole), dev.state));
        var file = blk: {
            switch (port) {
                0x8 => {
                    if (self.stdout == null) self.stdout = std.io.getStdOut();
                    break :blk self.stdout.?;
                },
                0x9 => {
                    if (self.stderr == null) self.stderr = std.io.getStdErr();
                    break :blk self.stderr.?;
                },
                else => return,
            }
        };
        file.writer().writeByte(dev.data[port]) catch |e| {
            std.debug.panic("std err or out error :( : {any}", .{e});
        };
    }

    pub fn close(self: *UxnConsole) void {
        if (self.stdout) |*stdout| {
            stdout.close();
            self.stdout = null;
        }
        if (self.stderr) |*stderr| {
            stderr.close();
            self.stderr = null;
        }
    }
};
