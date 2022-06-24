const std = @import("std");

pub const EvalError = error{
    StackUnderflow,
    StackOverflow,
    DivisionByZero,
    LimitReached,
};
pub const EvalErrorData = struct {
    err: EvalError,
    working: bool,
};

pub const Stack = struct {
    const StackSize = 255;

    len: u8 = 0,
    data: [StackSize]u8 = undefined,

    const Self = @This();
    pub inline fn push(self: *Self, use_short: bool, value: u32) !void {
        if (use_short) {
            if (self.len > StackSize - 2) return error.StackOverflow;
            self.data[self.len] = @truncate(u8, value >> 8);
            self.data[self.len + 1] = @truncate(u8, value);
            self.len += 2;
        } else {
            if (self.len > StackSize - 1) return error.StackOverflow;
            self.data[self.len] = @truncate(u8, value);
            self.len += 1;
        }
    }
    pub inline fn pop(self: *Self, sp: *u8, use_short: bool, register: *u32) !void {
        if (use_short) {
            if (sp.* < 2) return error.StackUnderflow;
            register.* = @as(u32, self.data[sp.* - 1]) |
                (@as(u32, self.data[sp.* - 2]) << 8);
            sp.* -= 2;
        } else {
            if (sp.* < 1) return error.StackUnderflow;
            register.* = @as(u32, self.data[sp.* - 1]);
            sp.* -= 1;
        }
    }

    pub fn write(self: *Self, writer: anytype, name: []const u8) !void {
        try writer.print("<{s}>", .{name});
        var i: usize = 0;
        while (i < self.len) : (i += 1) try writer.print(" {x}", .{self.data[i]});
        if (i == 0) try writer.writeAll(" empty");
        try writer.writeByte('\n');
    }
};

pub const Device = struct {
    data: [16]u8 = [_]u8{0} ** 16,
    dei: fn (u: *Uxn, device: *Device, port: u8) u8 = nilDei,
    deo: fn (u: *Uxn, device: *Device, port: u8) void = nilDeo,
    state: *anyopaque = undefined,

    fn nilDei(u: *Uxn, device: *Device, port: u8) u8 {
        _ = u;
        return device.data[port];
    }
    fn nilDeo(u: *Uxn, device: *Device, port: u8) void {
        _ = u;
        _ = device;
        _ = port;
    }

    pub inline fn peek16(self: *Device, x: u16) u16 {
        return (@as(u16, self.data[x]) << 8) |
            @as(u16, self.data[x + 1]);
    }
    pub inline fn poke16(self: *Device, x: u16, y: u16) void {
        self.data[x] = @truncate(u8, y >> 8);
        self.data[x + 1] = @truncate(u8, y);
    }
    pub inline fn getVector(self: *Device) u16 {
        return (@as(u16, self.data[0]) << 8) | @as(u16, self.data[1]);
    }
};

pub const UxnLimit = 0x40000;
pub const PageProgram = 0x0100;

pub const UxnOp = enum(u5) {
    LIT = 0x00,
    INC = 0x01,
    POP = 0x02,
    NIP = 0x03,
    SWP = 0x04,
    ROT = 0x05,
    DUP = 0x06,
    OVR = 0x07,

    EQU = 0x08,
    NEQ = 0x09,
    GTH = 0x0a,
    LTH = 0x0b,
    JMP = 0x0c,
    JCN = 0x0d,
    JSR = 0x0e,
    STH = 0x0f,

    LDZ = 0x10,
    STZ = 0x11,
    LDR = 0x12,
    STR = 0x13,
    LDA = 0x14,
    STA = 0x15,
    DEI = 0x16,
    DEO = 0x17,

    ADD = 0x18,
    SUB = 0x19,
    MUL = 0x1a,
    DIV = 0x1b,
    AND = 0x1c,
    ORA = 0x1d,
    EOR = 0x1e,
    SFT = 0x1f,
};

inline fn devr(
    use_short: bool,
    register: *u32,
    u: *Uxn,
    device: *Device,
    x: u32,
) void {
    register.* = device.dei(u, device, @truncate(u8, x & 0x0f));
    if (use_short) {
        register.* = (register.* << 8) |
            device.dei(u, device, @truncate(u8, (x + 1) & 0x0f));
    }
}
inline fn devw8(
    u: *Uxn,
    device: *Device,
    x: u32,
    y: u32,
) void {
    device.data[x & 0xf] = @truncate(u8, y);
    device.deo(u, device, @truncate(u8, x & 0x0f));
}
inline fn devw(
    use_short: bool,
    u: *Uxn,
    device: *Device,
    x: u32,
    y: u32,
) void {
    if (use_short) {
        devw8(u, device, x, y >> 8);
        devw8(u, device, x + 1, y);
    } else {
        devw8(u, device, x, y);
    }
}
inline fn warp(
    use_short: bool,
    pc: *u16,
    x: u32,
) void {
    if (use_short) {
        pc.* = @truncate(u16, x);
    } else {
        const val = @bitCast(i8, @truncate(u8, x));
        const scalar = std.math.absCast(val);
        if (val < 0) {
            pc.* -= scalar;
        } else {
            pc.* += scalar;
        }
    }
}

pub const Uxn = struct {
    ram: []u8,
    dev: [16]Device,
    wst: Stack = .{},
    rst: Stack = .{},

    inline fn poke(self: *Uxn, use_short: bool, x: u32, y: u32) void {
        if (use_short) {
            self.ram[x] = @truncate(u8, y >> 8);
            self.ram[x + 1] = @truncate(u8, y);
        } else {
            self.ram[x] = @truncate(u8, y);
        }
    }
    inline fn peek(self: *Uxn, use_short: bool, register: *u32, x: u32) void {
        if (use_short) {
            register.* = (@as(u32, self.ram[x]) << 8) | @as(u32, self.ram[x + 1]);
        } else {
            register.* = @as(u32, self.ram[x]);
        }
    }
    pub fn eval(self: *Uxn, pc_start: u16) !void {
        if (pc_start == 0 or self.dev[0].data[0xf] != 0) return error.StackUnderflow;
        // registers
        var a: u32 = undefined;
        var b: u32 = undefined;
        var c: u32 = undefined;

        var src: *Stack = undefined;
        var klen: u8 = undefined;
        var sp: *u8 = undefined;
        var dst: *Stack = undefined;
        var limit: u32 = UxnLimit;
        var pc = pc_start;
        while (true) {
            const instr = self.ram[pc];
            if (instr == 0) break;
            pc += 1;
            if (limit == 0) {
                return error.LimitReached;
                //limit = UxnLimit;
            }
            limit -= 1;

            if ((instr & 0x40) != 0) {
                src = &self.rst;
                dst = &self.wst;
            } else {
                src = &self.wst;
                dst = &self.rst;
            }
            if ((instr & 0x80) != 0) {
                klen = src.len;
                sp = &klen;
            } else {
                sp = &src.len;
            }
            const use_short = (instr & 0x20) != 0;
            switch (@intToEnum(UxnOp, instr & 0x1f)) {
                .LIT => {
                    self.peek(use_short, &a, pc);
                    try src.push(use_short, a);
                    pc += 1 + @as(u16, @boolToInt(use_short));
                },
                .INC => {
                    try src.pop(sp, use_short, &a);
                    try src.push(use_short, a + 1);
                },
                .POP => {
                    try src.pop(sp, use_short, &a);
                },
                .NIP => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, a);
                },
                .SWP => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, a);
                    try src.push(use_short, b);
                },
                .ROT => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.pop(sp, use_short, &c);
                    try src.push(use_short, b);
                    try src.push(use_short, a);
                    try src.push(use_short, c);
                },
                .DUP => {
                    try src.pop(sp, use_short, &a);
                    try src.push(use_short, a);
                    try src.push(use_short, a);
                },
                .OVR => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, b);
                    try src.push(use_short, a);
                    try src.push(use_short, b);
                },

                .EQU => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(false, @boolToInt(b == a));
                },
                .NEQ => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(false, @boolToInt(b != a));
                },
                .GTH => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(false, @boolToInt(b > a));
                },
                .LTH => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(false, @boolToInt(b < a));
                },
                .JMP => {
                    try src.pop(sp, use_short, &a);
                    warp(use_short, &pc, a);
                },
                .JCN => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, false, &b);
                    if (b != 0) warp(use_short, &pc, a);
                },
                .JSR => {
                    try src.pop(sp, use_short, &a);
                    try dst.push(true, pc);
                    warp(use_short, &pc, a);
                },
                .STH => {
                    try src.pop(sp, use_short, &a);
                    try dst.push(use_short, a);
                },

                .LDZ => {
                    try src.pop(sp, false, &a);
                    self.peek(use_short, &b, a);
                    try src.push(use_short, b);
                },
                .STZ => {
                    try src.pop(sp, false, &a);
                    try src.pop(sp, use_short, &b);
                    self.poke(use_short, a, b);
                },
                .LDR => {
                    try src.pop(sp, false, &a);
                    const val = @bitCast(i8, @truncate(u8, a));
                    const absval = std.math.absCast(val);
                    self.peek(use_short, &b, if (val < 0) pc - absval else pc + absval);
                },
                .STR => {
                    try src.pop(sp, false, &a);
                    try src.pop(sp, use_short, &b);
                    const val = @bitCast(i8, @truncate(u8, a));
                    const absval = std.math.absCast(val);
                    c = if (val < 0) pc - absval else pc + absval;
                    self.poke(use_short, c, b);
                },
                .LDA => {
                    try src.pop(sp, true, &a);
                    self.peek(use_short, &b, a);
                    try src.push(use_short, b);
                },
                .STA => {
                    try src.pop(sp, true, &a);
                    try src.pop(sp, use_short, &b);
                    self.poke(use_short, a, b);
                },
                .DEI => {
                    try src.pop(sp, false, &a);
                    devr(use_short, &b, self, &self.dev[a >> 4], a);
                    try src.push(use_short, b);
                },
                .DEO => {
                    try src.pop(sp, false, &a);
                    try src.pop(sp, use_short, &b);
                    devw(use_short, self, &self.dev[a >> 4], a, b);
                },

                .ADD => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, b + a);
                },
                .SUB => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, b - a);
                },
                .MUL => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, b * a);
                },
                .DIV => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    if (a == 0) return error.DivisionByZero;
                    try src.push(use_short, b / a);
                },
                .AND => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, b & a);
                },
                .ORA => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, b | a);
                },
                .EOR => {
                    try src.pop(sp, use_short, &a);
                    try src.pop(sp, use_short, &b);
                    try src.push(use_short, b ^ a);
                },
                .SFT => {
                    try src.pop(sp, false, &a);
                    try src.pop(sp, use_short, &b);
                    c = (b >> @truncate(u4, a)) << @truncate(u4, a >> 4);
                    try src.push(use_short, c);
                },
            }
        }
    }

    pub fn loadRom(self: *Uxn, filename: []const u8) !usize {
        var file = try std.fs.cwd().openFile(filename, .{});
        return try file.readAll(self.ram[PageProgram..std.math.min(self.ram.len, 0x10000)]);
    }
    pub fn consoleInput(self: *Uxn, c: u8) !void {
        var device = &self.dev[1];
        device.data[0x2] = c;
        return try self.eval(device.getVector());
    }
};
