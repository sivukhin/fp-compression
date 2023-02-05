const std = @import("std");
const testing = std.testing;
const bw = @import("bit-workspace.zig");

pub fn GorillaCompressor(comptime T: type, comptime Writer: type) type {
    const typeInfo = @typeInfo(T);
    if (typeInfo != .Int and typeInfo != .Float) {
        @compileError(std.fmt.comptimePrint("supported only integer types but given {}", .{T}));
    }
    const UIntType = std.meta.Int(.unsigned, @bitSizeOf(T));
    const WorkspaceType = std.meta.Int(.unsigned, 2 * @bitSizeOf(T));
    return struct {
        pub const width = @bitSizeOf(T);
        const Self = @This();

        prev: UIntType,
        prev_leading_zeros: u8,
        prev_trailing_zeros: u8,
        workspace: bw.BitWriteWorkspace(WorkspaceType, Writer),

        pub fn init(writer: Writer) Self {
            return .{
                .prev = 0,
                .prev_leading_zeros = 0,
                .prev_trailing_zeros = 0,
                .workspace = bw.bitWriteWorkspace(WorkspaceType, writer),
            };
        }
        pub fn add(self: *Self, element: T) !void {
            const leading_zeros_log = comptime @bitSizeOf(std.math.Log2Int(UIntType));
            const significant_bits_log = comptime @bitSizeOf(std.math.Log2Int(UIntType)) + 1;

            const current_bits = @bitCast(UIntType, element);

            const diff_bits = current_bits ^ self.prev;
            try self.workspace.unsafeAdd(if (diff_bits == 0) @as(u32, 0) else @as(u32, 1), 1);

            if (diff_bits != 0) {
                const leading_zeros = @clz(diff_bits);
                const trailing_zeros = @ctz(diff_bits);
                const significant_bits = @bitSizeOf(T) - leading_zeros - trailing_zeros;
                if (leading_zeros >= self.prev_leading_zeros and trailing_zeros >= self.prev_trailing_zeros) {
                    try self.workspace.unsafeAdd(0, 1);
                    try self.workspace.unsafeAdd(std.math.shr(UIntType, diff_bits, self.prev_trailing_zeros), @bitSizeOf(T) - self.prev_trailing_zeros - self.prev_leading_zeros);
                } else {
                    try self.workspace.unsafeAdd(1 | std.math.shl(UIntType, leading_zeros, 1) | std.math.shl(UIntType, significant_bits, (1 + leading_zeros_log)), 1 + leading_zeros_log + significant_bits_log);
                    try self.workspace.unsafeAdd(std.math.shr(UIntType, diff_bits, trailing_zeros), significant_bits);
                }
                self.prev_leading_zeros = leading_zeros;
                self.prev_trailing_zeros = trailing_zeros;
            }
            try self.workspace.flush();
            self.prev = current_bits;
        }
        pub fn finish(self: *Self) !void {
            try self.workspace.finish();
        }
    };
}

pub fn gorillaCompressor(comptime T: type, writer: anytype) GorillaCompressor(T, @TypeOf(writer)) {
    const Compressor = GorillaCompressor(T, @TypeOf(writer));
    return Compressor.init(writer);
}

pub fn GorillaDecompressor(comptime T: type, comptime Reader: type) type {
    const typeInfo = @typeInfo(T);
    if (typeInfo != .Int and typeInfo != .Float) {
        @compileError(std.fmt.comptimePrint("supported only integer types but given {}", .{T}));
    }
    const UIntType = std.meta.Int(.unsigned, @bitSizeOf(T));
    const WorkspaceType = std.meta.Int(.unsigned, 2 * @bitSizeOf(T));
    return struct {
        pub const width = @bitSizeOf(T);
        const Self = @This();
        prev: UIntType,
        prev_leading_zeros: u8,
        prev_trailing_zeros: u8,
        workspace: bw.BitReadWorkspace(WorkspaceType, Reader),

        pub fn init(reader: Reader) Self {
            return .{
                .prev = 0,
                .prev_leading_zeros = 0,
                .prev_trailing_zeros = 0,
                .workspace = bw.bitReadWorkspace(WorkspaceType, reader),
            };
        }
        pub fn get(self: *Self) !T {
            const zero_control = try self.workspace.getFull(u1);
            if (zero_control == 0) {
                return @bitCast(T, self.prev);
            }
            const change_control = try self.workspace.getFull(u1);
            const diff_bits = diff_bits_value: {
                if (change_control == 0) {
                    const significant_bits = try self.workspace.getBits(UIntType, @bitSizeOf(T) - self.prev_trailing_zeros - self.prev_leading_zeros);
                    break :diff_bits_value std.math.shl(UIntType, significant_bits, self.prev_trailing_zeros);
                } else {
                    const leading_zeros_len = try self.workspace.getBits(u8, @bitSizeOf(std.math.Log2Int(UIntType)));
                    const diff_bits_len = try self.workspace.getBits(u8, @bitSizeOf(std.math.Log2Int(UIntType)) + 1);
                    break :diff_bits_value std.math.shl(UIntType, try self.workspace.getBits(UIntType, diff_bits_len), @bitSizeOf(T) - leading_zeros_len - diff_bits_len);
                }
            };
            const current_bits = self.prev ^ diff_bits;
            self.prev = current_bits;
            self.prev_leading_zeros = @clz(diff_bits);
            self.prev_trailing_zeros = @ctz(diff_bits);
            return @bitCast(T, current_bits);
        }
    };
}

pub fn gorillaDecompressor(comptime T: type, reader: anytype) GorillaDecompressor(T, @TypeOf(reader)) {
    const Decompressor = GorillaDecompressor(T, @TypeOf(reader));
    return Decompressor.init(reader);
}

fn gorillaTest(comptime T: type, data: []const T) !void {
    var buffer = [_]u8{0} ** (16 * 1024);
    {
        var stream = std.io.fixedBufferStream(&buffer);
        var counting = std.io.countingWriter(stream.writer());
        var gorilla = gorillaCompressor(T, counting.writer());
        for (data) |f| {
            try gorilla.add(f);
        }
        try gorilla.finish();
        const total_size = counting.bytes_written;
        const raw_size = data.len * @sizeOf(T);
        std.debug.print("total size {} bytes, raw size {} bytes, savings: {d:.2}%\n", .{ total_size, raw_size, (1.0 - @intToFloat(f32, total_size) / @intToFloat(f32, raw_size)) * 100 });
    }
    {
        var stream = std.io.fixedBufferStream(&buffer);
        var gorilla = gorillaDecompressor(T, stream.reader());
        for (data) |f| {
            try testing.expectEqual(f, try gorilla.get());
        }
    }
}

test "gorilla f32 embeddings test" {
    var data = [_]f32{ 0.043154765, 0.164135829, -0.123626679, -0.167725742, -0.110710979, 0.102363497, 0.022291092, -0.187514856, -0.157604620, -0.065454222, 0.034411345, -0.226510420, 0.228433594, -0.070296884, -0.068169087, 0.049356200, -0.042770151, 0.151971295, 0.402687907, -0.366405696, 0.034094390, 0.051680047, -0.067786627, 0.160439745, -0.048753500, -0.196946219, 0.045420300, 0.189751863, 0.018866321, -0.002804127, -0.247762606, 0.365801245, 1.000000000, 0.405465096, -2.120258808 };
    try gorillaTest(f32, &data);
}

test "gorilla f64 embeddings test" {
    var data = [_]f64{ 0.043154765, 0.164135829, -0.123626679, -0.167725742, -0.110710979, 0.102363497, 0.022291092, -0.187514856, -0.157604620, -0.065454222, 0.034411345, -0.226510420, 0.228433594, -0.070296884, -0.068169087, 0.049356200, -0.042770151, 0.151971295, 0.402687907, -0.366405696, 0.034094390, 0.051680047, -0.067786627, 0.160439745, -0.048753500, -0.196946219, 0.045420300, 0.189751863, 0.018866321, -0.002804127, -0.247762606, 0.365801245, 1.000000000, 0.405465096, -2.120258808 };
    try gorillaTest(f64, &data);
}

test "gorilla f32 cpu usage test" {
    var data = [_]f32{ 15.904462, 16.393611, 16.775417, 16.912917, 16.88375, 16.376875, 16.208681, 16.586528, 17.123681, 16.650278, 16.534792, 16.692425, 16.456776, 15.761528, 16.051944, 15.914444, 16.04, 16.158194, 16.242292, 16.281528, 17.261042, 16.457639, 17.093681, 16.904653, 15.960417, 16.016667, 16.188 };
    try gorillaTest(f32, &data);
}

test "gorilla f64 cpu usage test" {
    var data = [_]f64{ 15.904462, 16.393611, 16.775417, 16.912917, 16.88375, 16.376875, 16.208681, 16.586528, 17.123681, 16.650278, 16.534792, 16.692425, 16.456776, 15.761528, 16.051944, 15.914444, 16.04, 16.158194, 16.242292, 16.281528, 17.261042, 16.457639, 17.093681, 16.904653, 15.960417, 16.016667, 16.188 };
    try gorillaTest(f64, &data);
}

test "gorilla f32 sample from paper" {
    var data = [_]f32{ 15.5, 14.0625, 3.25, 8.625, 13.1 };
    try gorillaTest(f32, &data);
}

test "gorilla f64 sample from paper" {
    var data = [_]f64{ 15.5, 14.0625, 3.25, 8.625, 13.1 };
    try gorillaTest(f64, &data);
}
