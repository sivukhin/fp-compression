const std = @import("std");
const testing = std.testing;

pub fn BitReadWorkspace(comptime T: type, comptime Reader: type) type {
    const t_info = @typeInfo(T);
    if (t_info != .Int or t_info.Int.signedness == .signed) {
        @compileError(std.fmt.comptimePrint("BitReadWorkspace can be constructed only from unsigned integer type, but given {}", .{T}));
    }
    if (t_info.Int.bits < 8) {
        @compileError(std.fmt.comptimePrint("BitReadWorkspace can be constructed from unsigned integer with at least 8 bits, but given {}", .{T}));
    }
    return struct {
        const Self = @This();
        workspace: T,
        position: u8,
        capacity: u8,
        reader: Reader,
        end: bool,

        pub fn init(reader: Reader) Self {
            return .{ .workspace = 0, .position = 0, .capacity = 0, .reader = reader, .end = false };
        }

        pub fn getBits(self: *Self, comptime ValueT: type, bits: anytype) !ValueT {
            if (self.capacity < bits) {
                if (self.end) return error.EndOfStream;
                try self.load();
            }
            const value = self.workspace & (~std.math.shl(T, ~@as(T, 0), bits));
            self.workspace = std.math.shr(T, self.workspace, bits);
            self.capacity -= bits;
            return @intCast(ValueT, value);
        }

        pub fn getFull(self: *Self, comptime ValueT: type) !ValueT {
            return self.getBits(ValueT, @bitSizeOf(ValueT));
        }

        fn load(self: *Self) !void {
            const expected_bytes = (@bitSizeOf(T) - self.capacity) / 8;
            var tmp: [@bitSizeOf(T) / 8]u8 = undefined;
            const actual_bytes = try self.reader.readAll((&tmp)[0..expected_bytes]);
            const mask = ~std.math.shl(T, ~@as(T, 0), 8 * actual_bytes);
            self.workspace = (self.workspace & ~(std.math.shl(T, mask, self.capacity))) | std.math.shl(T, std.mem.readIntNative(T, &tmp) & mask, self.capacity);
            self.capacity += @intCast(u8, 8 * actual_bytes);
            if (actual_bytes < expected_bytes) {
                self.capacity -= 1;
                while (self.capacity >= 0 and self.workspace & std.math.shl(T, @as(T, 1), self.capacity) > 0) {
                    self.capacity -= 1;
                }
                self.end = true;
            }
        }
    };
}

pub fn bitReadWorkspace(comptime T: type, reader: anytype) BitReadWorkspace(T, @TypeOf(reader)) {
    return BitReadWorkspace(T, @TypeOf(reader)).init(reader);
}

pub fn BitWriteWorkspace(comptime T: type, comptime Writer: type) type {
    const t_info = @typeInfo(T);
    if (t_info != .Int or t_info.Int.signedness == .signed) {
        @compileError(std.fmt.comptimePrint("BitWriteWorkspace can be constructed only from unsigned integer type, but given {}", .{T}));
    }
    if (t_info.Int.bits < 8) {
        @compileError(std.fmt.comptimePrint("BitWriteWorkspace can be constructed from unsigned integer with at least 8 bits, but given {}", .{T}));
    }
    return struct {
        const Self = @This();
        workspace: T,
        position: u32,
        writer: Writer,

        pub fn init(writer: Writer) Self {
            return .{ .workspace = 0, .position = 0, .writer = writer };
        }

        pub fn safeAdd(self: *Self, value: anytype, bits: anytype) !void {
            if (self.position + bits > @bitSizeOf(T)) {
                try self.flush();
            }
            try self.unsafeAdd(value, bits);
        }

        pub fn unsafeAdd(self: *Self, value: anytype, bits: anytype) !void {
            const mask = ~std.math.shl(T, ~@as(T, 0), bits);
            self.workspace = (self.workspace & ~std.math.shl(T, mask, self.position)) | std.math.shl(T, value & mask, self.position);
            self.position += bits;
        }

        pub fn finish(self: *Self) !void {
            try self.flush();
            try self.safeAdd(0, 1);
            try self.safeAdd((1 << 8) - 1, (8 - self.position % 8) % 8);
            try self.flush();
        }

        pub fn flush(self: *Self) !void {
            var ptr = @ptrCast(*[t_info.Int.bits / 8]u8, &self.workspace);
            var size = (self.position - self.position % 8) / 8;
            try self.writer.writeAll((&ptr.*)[0..size]);
            self.workspace = std.math.shr(T, self.workspace, self.position - self.position % 8);
            self.position %= 8;
        }
    };
}

pub fn bitWriteWorkspace(comptime T: type, writer: anytype) BitWriteWorkspace(T, @TypeOf(writer)) {
    return BitWriteWorkspace(T, @TypeOf(writer)).init(writer);
}

test "write: single finish" {
    var buffer = [_]u8{0} ** 3;
    var stream = std.io.fixedBufferStream(&buffer);
    var w = bitWriteWorkspace(u32, stream.writer());
    try w.safeAdd(0b10110011, 8);
    try w.safeAdd(0b1100, 4);
    try w.safeAdd(0b10001, 5);
    try w.finish();

    try testing.expectEqual(@as(u8, 0b10110011), buffer[0]);
    try testing.expectEqual(@as(u8, 0b00011100), buffer[1]);
    try testing.expectEqual(@as(u8, 0b11111101), buffer[2]);
}

test "write: multiple flushes" {
    var buffer = [_]u8{0} ** 8;
    var stream = std.io.fixedBufferStream(&buffer);
    var w = bitWriteWorkspace(u32, stream.writer());
    try w.safeAdd(0b10110011, 15);
    try w.safeAdd(0b101, 3);
    try w.flush();
    try w.safeAdd(0b10001, 5);
    try w.flush();
    try w.safeAdd(0b01, 2);
    try w.flush();
    try w.finish();
    try testing.expectEqual(@as(u8, 0b10110011), buffer[0]);
    try testing.expectEqual(@as(u8, 0b10000000), buffer[1]);
    try testing.expectEqual(@as(u8, 0b11000110), buffer[2]);
    try testing.expectEqual(@as(u8, 0b11111100), buffer[3]);
}

test "write: empty finish" {
    var buffer = [_]u8{0} ** 8;
    var stream = std.io.fixedBufferStream(&buffer);
    var w = bitWriteWorkspace(u32, stream.writer());
    try w.finish();
    try testing.expectEqual(@as(u8, 0b11111110), buffer[0]);
}

test "read: single read" {
    var buffer = [_]u8{0b11010000} ** 4;
    var stream = std.io.fixedBufferStream(&buffer);
    var r = bitReadWorkspace(u32, stream.reader());
    try testing.expectEqual(@as(u32, 0b11010000110100001101000011010000), try r.getFull(u32));
}

test "read/write" {
    var buffer = [_]u8{0} ** 8;
    {
        var stream = std.io.fixedBufferStream(&buffer);
        var w = bitWriteWorkspace(u32, stream.writer());
        try w.safeAdd(0b10110011, 15);
        try w.safeAdd(0b101, 3);
        try w.flush();
        try w.safeAdd(0b10001, 5);
        try w.flush();
        try w.safeAdd(0b01, 2);
        try w.flush();
        try w.finish();
    }

    {
        var stream = std.io.fixedBufferStream(&buffer);
        var r = bitReadWorkspace(u32, stream.reader());
        try testing.expectEqual(@as(u15, 0b10110011), try r.getFull(u15));
        try testing.expectEqual(@as(u3, 0b101), try r.getFull(u3));
        try testing.expectEqual(@as(u5, 0b10001), try r.getFull(u5));
        try testing.expectEqual(@as(u2, 0b01), try r.getFull(u2));
    }
}

test "read/write 2" {
    var buffer = [_]u8{0} ** 2;
    {
        var stream = std.io.fixedBufferStream(&buffer);
        var w = bitWriteWorkspace(u32, stream.writer());
        try w.safeAdd(1, 1);
        try w.safeAdd(0, 5);
        try w.safeAdd(22, 6);
        try w.finish();
    }

    {
        var stream = std.io.fixedBufferStream(&buffer);
        var r = bitReadWorkspace(u32, stream.reader());
        try testing.expectEqual(@as(u1, 1), try r.getFull(u1));
        try testing.expectEqual(@as(u5, 0), try r.getFull(u5));
        try testing.expectEqual(@as(u6, 22), try r.getFull(u6));
    }
}
