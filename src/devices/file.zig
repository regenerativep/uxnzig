const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;

const uxn = @import("../uxn.zig");

fn copyCorrect(comptime T: type, dest: []T, source: []const T) void {
    if (@ptrToInt(dest.ptr) < @ptrToInt(source.ptr)) {
        std.mem.copy(T, dest, source);
    } else {
        std.mem.copyBackwards(T, dest, source);
    }
}

fn getEntryKind(buffer: []u8, kind: ?fs.File.Kind, size: ?usize, basename: []const u8) ![]u8 {
    var prefix: [4]u8 = "!!!!".*;
    if (kind != null) {
        if (kind.? == .Directory) {
            prefix = "----".*;
        } else if (size != null) {
            _ = fmt.bufPrint(&prefix, "{x:0>4}", .{size.?}) catch {
                prefix = "????".*;
            };
        }
    }
    const result = try fmt.bufPrint(buffer, "{s} {s}\n\x00", .{ prefix, basename });
    return result[0 .. result.len - 1]; // exclude the null terminator
}
fn getEntry(buffer: []u8, path: []const u8, basename: []const u8, comptime errorOnStat: bool) ![]u8 {
    var size: ?usize = null;
    const kind: ?fs.File.Kind = blk: {
        const stat = fs.cwd().statFile(path) catch |e| if (errorOnStat) return e else break :blk null;
        size = stat.size;
        break :blk stat.kind;
    };
    return getEntryKind(buffer, kind, size, basename);
}

pub const UxnFile = struct {
    pub const Filename = std.BoundedArray(u8, 4096);
    pub const State = enum { idle, file_read, file_write, dir_read };

    file: ?fs.File = null,
    dir: ?fs.Dir = null,
    filename: Filename = .{},
    state: State = .idle,

    const Self = @This();
    pub fn init(filename: []const u8) !Self {
        return Self{
            .filename = Filename.fromSlice(filename),
            .state = .idle,
        };
    }
    pub fn device(self: *Self) uxn.Device {
        return .{
            .dei = fileDei,
            .deo = fileDeo,
            .state = self,
        };
    }
    pub fn basename(self: *Self) []const u8 {
        const slice = self.filename.slice();
        const ind = std.mem.lastIndexOfScalar(u8, slice, '/') orelse return slice;
        return slice[ind + 1 ..];
    }
    pub fn close(self: *Self) void {
        if (self.file) |*file| {
            file.close();
            self.file = null;
        }
        if (self.dir) |*dir| {
            dir.close();
            self.dir = null;
        }
        self.state = .idle;
    }

    pub const OpenError = error{NoFilename};
    pub fn openForRead(self: *Self) !void {
        std.debug.assert(self.state == .idle);
        var cwd = fs.cwd();
        const filename = self.filename.slice();
        if (filename.len == 0) return error.NoFilename;
        if (cwd.openDir(filename, .{ .iterate = true })) |dir| {
            self.dir = dir;
            self.state = .dir_read;
        } else |e| {
            if (e == error.NotDir) {
                self.file = try cwd.openFile(filename, .{ .mode = .read_only });
                self.state = .file_read;
            } else return e;
        }
    }
    pub fn openForWrite(self: *Self, append: bool) !void {
        std.debug.assert(self.state == .idle);
        var cwd = fs.cwd();
        const filename = self.filename.slice();
        if (filename.len == 0) return error.NoFilename;
        self.file = try cwd.createFile(filename, .{ .truncate = !append });
        errdefer self.file.?.close();
        if (append) {
            try self.file.?.seekFromEnd(0);
        }
        self.state = .file_write;
    }
    pub fn readDir(self: *Self, out_buffer: []u8) []const u8 {
        var iter = self.dir.?.iterate();
        var ind: usize = 0;
        // iter always has a `buf`. we will use that
        while (true) {
            // note that the iterator should already skip '.' and '..' entries
            const entry = (iter.next() catch break) orelse break;
            // we need to manually format in the `buf` (no `format`)... (beginning of entry name in the buffer
            // might be before length of filename slice + 1)
            const filename = self.filename.slice();
            const pathname_len = filename.len + 1 + entry.name.len;
            if (pathname_len + 1 <= iter.buf.len) {
                copyCorrect(u8, iter.buf[filename.len + 1 ..], entry.name);
                std.mem.copy(u8, iter.buf[0..filename.len], filename);
                iter.buf[filename.len] = '/';
                //iter.buf[pathname_len] = '\x00';
                const result = getEntry(out_buffer[ind..], iter.buf[0..pathname_len], iter.buf[filename.len + 1 .. pathname_len], false) catch break;
                ind += result.len; // no + 1 here because we will overwrite the null terminator. entries are separated by newlines
            }
        }
        return out_buffer[0..ind];
    }

    fn fileDeo(u: *uxn.Uxn, dev: *uxn.Device, port: u8) void {
        var file = @ptrCast(*Self, @alignCast(@alignOf(Self), dev.state));
        var res: u16 = 0;
        switch (port) {
            0x5 => { // stat file
                const addr = dev.peek16(0x4);
                const len = dev.peek16(0xa);
                const out_buffer = u.ram[addr..std.math.min(addr + len, u.ram.len)];
                const result = getEntry(out_buffer, file.filename.slice(), file.basename(), true);
                res = if (result) |written| @truncate(u16, written.len) else |_| 0;
            },
            0x6 => { // delete file
                file.close(); // closing the file isnt in original code, but i felt this is the right thing to do here?
                const result = fs.cwd().deleteFile(file.filename.slice());
                res = @boolToInt(std.meta.isError(result));
            },
            0x9 => { // specify filename
                const addr = dev.peek16(0x8);
                file.filename = .{};
                if (std.mem.indexOfScalarPos(u8, u.ram, addr, 0)) |endaddr| {
                    file.filename = Filename.fromSlice(u.ram[addr..endaddr]) catch .{};
                }
                res = 0;
            },
            0xd => { // read file
                const addr = dev.peek16(0xc);
                const len = dev.peek16(0xa);
                const out_buffer = u.ram[addr..std.math.min(addr + len, u.ram.len)];
                if (file.state != .file_read and file.state != .dir_read) {
                    file.close();
                    file.openForRead() catch {};
                    // TODO: even though the original doesnt error handle, do we want to write an error back anyway?
                }
                switch (file.state) {
                    .file_read => {
                        res = @truncate(u16, file.file.?.readAll(out_buffer) catch 0);
                    },
                    .dir_read => {
                        res = @truncate(u16, file.readDir(out_buffer).len);
                    },
                    else => {},
                }
            },
            0xf => { // write file
                const addr = dev.peek16(0xe);
                const len = dev.peek16(0xa);
                const in_buffer = u.ram[addr..std.math.min(addr + len, u.ram.len)];
                if (file.state != .file_write) {
                    file.close();
                    file.openForWrite((dev.data[0x7] & 0x01) != 0) catch {};
                }
                if (file.state == .file_write) {
                    const result = file.file.?.writeAll(in_buffer);
                    res = @boolToInt(std.meta.isError(result));
                }
            },
            else => {},
        }
        dev.poke16(0x2, res);
    }

    fn fileDei(u: *uxn.Uxn, dev: *uxn.Device, port: u8) u8 {
        _ = u;
        var file = @ptrCast(*Self, @alignCast(@alignOf(Self), dev.state));
        switch (port) {
            0xc, 0xd => {
                if (file.state != .file_read and file.state != .dir_read) {
                    file.close();
                    file.openForRead() catch {};
                }
                // we are going to assume that this is only going to be used for file reading..
                // because i dont see how always reading the first character of `readDir` would
                // be very useful
                if (file.state == .file_read) {
                    const byte_res = file.file.?.reader().readByte();
                    var res: u16 = 0;
                    if (byte_res) |read_byte| {
                        dev.data[port] = read_byte;
                    } else |_| {
                        res = 1;
                    }
                    dev.poke16(0x2, res);
                }
            },
            else => {},
        }
        return dev.data[port];
    }
};
