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

        pub fn init(reader: Reader) Self {
            return .{ .workspace = 0, .position = 0, .capacity = 0, .reader = reader };
        }

        pub fn getBits(self: *Self, comptime ValueT: type, bits: anytype) !ValueT {
            if (self.capacity < bits) {
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
            // var i: usize = 0;
            // while (i < actual_bytes) : (i += 1) {
            //     std.debug.print("read byte: {x}\n", .{tmp[i]});
            // }
            const mask = ~std.math.shl(T, ~@as(T, 0), 8 * actual_bytes);
            self.workspace = (self.workspace & ~(std.math.shl(T, mask, self.capacity))) | std.math.shl(T, std.mem.readIntNative(T, &tmp) & mask, self.capacity);
            self.capacity += @intCast(u8, 8 * actual_bytes);
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

        pub fn add(self: *Self, value: anytype, bits: anytype) !usize {
            var flushed: usize = 0;
            if (bits == 0) {
                return flushed;
            }
            if (self.position + bits > @bitSizeOf(T)) {
                flushed = try self.flush();
            }
            const mask = ~std.math.shl(T, ~@as(T, 0), bits);
            self.workspace = (self.workspace & ~std.math.shl(T, mask, self.position)) | std.math.shl(T, value & mask, self.position);
            self.position += bits;
            return flushed;
        }

        pub fn finish(self: *Self) !usize {
            var size = try self.flush();
            size += try self.add(0, 1);
            size += try self.add((1 << 8) - 1, (8 - self.position % 8) % 8);
            size += try self.flush();
            return size;
        }

        fn flush(self: *Self) !usize {
            var ptr = @ptrCast(*[t_info.Int.bits / 8]u8, &self.workspace);
            var size = (self.position - self.position % 8) / 8;
            try self.writer.writeAll((&ptr.*)[0..size]);
            self.workspace = std.math.shr(T, self.workspace, self.position - self.position % 8);
            self.position %= 8;
            return size;
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
    try testing.expectEqual(@as(usize, 0), try w.add(0b10110011, 8));
    try testing.expectEqual(@as(usize, 0), try w.add(0b1100, 4));
    try testing.expectEqual(@as(usize, 0), try w.add(0b10001, 5));
    try testing.expectEqual(@as(usize, 3), try w.finish());

    try testing.expectEqual(@as(u8, 0b10110011), buffer[0]);
    try testing.expectEqual(@as(u8, 0b00011100), buffer[1]);
    try testing.expectEqual(@as(u8, 0b11111101), buffer[2]);
}

test "write: multiple flushes" {
    var buffer = [_]u8{0} ** 8;
    var stream = std.io.fixedBufferStream(&buffer);
    var w = bitWriteWorkspace(u32, stream.writer());
    try testing.expectEqual(@as(usize, 0), try w.add(0b10110011, 15));
    try testing.expectEqual(@as(usize, 0), try w.add(0b101, 3));
    try testing.expectEqual(@as(usize, 2), try w.flush());
    try testing.expectEqual(@as(usize, 0), try w.add(0b10001, 5));
    try testing.expectEqual(@as(usize, 0), try w.flush());
    try testing.expectEqual(@as(usize, 0), try w.add(0b01, 2));
    try testing.expectEqual(@as(usize, 1), try w.flush());
    try testing.expectEqual(@as(usize, 1), try w.finish());
    try testing.expectEqual(@as(u8, 0b10110011), buffer[0]);
    try testing.expectEqual(@as(u8, 0b10000000), buffer[1]);
    try testing.expectEqual(@as(u8, 0b11000110), buffer[2]);
    try testing.expectEqual(@as(u8, 0b11111100), buffer[3]);
}

test "write: empty finish" {
    var buffer = [_]u8{0} ** 8;
    var stream = std.io.fixedBufferStream(&buffer);
    var w = bitWriteWorkspace(u32, stream.writer());
    try testing.expectEqual(@as(usize, 1), try w.finish());
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
        try testing.expectEqual(@as(usize, 0), try w.add(0b10110011, 15));
        try testing.expectEqual(@as(usize, 0), try w.add(0b101, 3));
        try testing.expectEqual(@as(usize, 2), try w.flush());
        try testing.expectEqual(@as(usize, 0), try w.add(0b10001, 5));
        try testing.expectEqual(@as(usize, 0), try w.flush());
        try testing.expectEqual(@as(usize, 0), try w.add(0b01, 2));
        try testing.expectEqual(@as(usize, 1), try w.flush());
        try testing.expectEqual(@as(usize, 1), try w.finish());
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
        try testing.expectEqual(@as(usize, 0), try w.add(1, 1));
        try testing.expectEqual(@as(usize, 0), try w.add(0, 5));
        try testing.expectEqual(@as(usize, 0), try w.add(22, 6));
        try testing.expectEqual(@as(usize, 2), try w.finish());
    }

    {
        var stream = std.io.fixedBufferStream(&buffer);
        var r = bitReadWorkspace(u32, stream.reader());
        try testing.expectEqual(@as(u1, 1), try r.getFull(u1));
        try testing.expectEqual(@as(u5, 0), try r.getFull(u5));
        try testing.expectEqual(@as(u6, 22), try r.getFull(u6));
    }
}
