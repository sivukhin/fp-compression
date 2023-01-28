const std = @import("std");
const testing = std.testing;
const bw = @import("bit-workspace.zig");

pub fn EntropyTable(comptime n: comptime_int) type {
    return struct {
        const Self = @This();
        length: [n + 1]u32,
        index: [1 << n]u32,
    };
}

pub fn nextMask(mask: anytype) @TypeOf(mask) {
    if (mask == 0) {
        return 0;
    }
    const one = mask & (mask ^ (mask - 1));
    const block = ((mask + one - 1) ^ (mask + one)) & mask;
    const bits = @popCount(block);
    return (mask ^ block) | ((block << 1) ^ block ^ one) | ((1 << (bits - 1)) - 1);
}

test "nextMask" {
    comptime var m: u32 = 0b11011011;
    try testing.expectEqual(@as(u32, 0b11011101), comptime nextMask(m));
}

pub fn entropyTable(comptime n: comptime_int) EntropyTable(n) {
    comptime {
        @setEvalBranchQuota((1 << (n + 3)));
        var table = EntropyTable(n);
        var length: [n + 1]u32 = [_]u32{0} ** (n + 1);
        var index: [1 << n]u32 = undefined;
        index[0] = 0;
        index[(1 << n) - 1] = 0;
        var i: u32 = (1 << n) - 2;
        inline while (i > 0) : (i -= 1) {
            const next = nextMask(i);
            if (next >= (1 << n)) {
                index[i] = 0;
            } else {
                index[i] = index[next] + 1;
            }
            length[@popCount(i)] = std.math.log2_int_ceil(u32, index[i] + 1);
        }
        return table{ .length = length, .index = index };
    }
}

test "entropy table" {
    const table = entropyTable(8);
    const expected = [_]u32{ 0, 3, 5, 6, 7, 6, 5, 3, 0 };
    try testing.expectEqual(expected, table.length);
}

pub fn EntropyCompressor(comptime T: type, comptime Writer: type) type {
    const typeInfo = @typeInfo(T);
    if (typeInfo != .Int and typeInfo != .Float) {
        @compileError(std.fmt.comptimePrint("supported only integer types but given {}", .{T}));
    }
    const UIntType = std.meta.Int(.unsigned, @bitSizeOf(T));
    const WorkspaceType = std.meta.Int(.unsigned, 2 * @bitSizeOf(T));
    return struct {
        const Self = @This();
        const entropy_table = entropyTable(8);

        batch: [8]UIntType,
        counts: [@bitSizeOf(UIntType)]u8,
        batch_size: u32,
        workspace: bw.BitWriteWorkspace(WorkspaceType, Writer),

        pub fn init(writer: Writer) Self {
            return .{
                .batch = [_]UIntType{0} ** 8,
                .counts = [_]u8{8} ** @bitSizeOf(UIntType),
                .batch_size = 0,
                .workspace = bw.bitWriteWorkspace(WorkspaceType, writer),
            };
        }

        pub fn add(self: *Self, element: T) !void {
            self.batch[self.batch_size] = @bitCast(UIntType, element);
            self.batch_size += 1;
            if (self.batch_size < 8) {
                return;
            }
            comptime var bit: u32 = 0;
            inline while (bit < @bitSizeOf(UIntType)) : (bit += 1) {
                var number: u8 = 0;
                comptime var element_id: u32 = 0;
                inline while (element_id < 8) : (element_id += 1) {
                    number |= @intCast(u8, ((self.batch[element_id] >> bit) & 1) << (element_id));
                }
                const ones_count = @popCount(number);
                const zero_count = 8 - ones_count;
                if (self.counts[bit] > 1) {
                    _ = try self.workspace.add(number, 8);
                } else {
                    if (ones_count < zero_count) {
                        _ = try self.workspace.add(std.math.shl(u8, 1, (ones_count + 1)) - 1, ones_count + 1);
                    } else {
                        _ = try self.workspace.add(std.math.shl(u8, 1, zero_count), zero_count + 1);
                    }
                    _ = try self.workspace.add(Self.entropy_table.index[number], Self.entropy_table.length[ones_count]);
                }
                self.counts[bit] = std.math.min(ones_count, zero_count);
            }
            self.batch_size = 0;
        }

        pub fn flush(self: *Self) !void {
            while (self.batch_size != 0) {
                try self.add(0);
            }
            _ = try self.workspace.finish();
        }
    };
}

pub fn entropyCompressor(comptime T: type, writer: anytype) EntropyCompressor(T, @TypeOf(writer)) {
    const Compressor = EntropyCompressor(T, @TypeOf(writer));
    return Compressor.init(writer);
}

pub fn EntropyDecompressor(comptime T: type, comptime Reader: type) type {
    const typeInfo = @typeInfo(T);
    if (typeInfo != .Int and typeInfo != .Float) {
        @compileError(std.fmt.comptimePrint("supported only integer types but given {}", .{T}));
    }
    const UIntType = std.meta.Int(.unsigned, @bitSizeOf(T));
    const WorkspaceType = std.meta.Int(.unsigned, 2 * @bitSizeOf(T));
    return struct {
        const Self = @This();
        const entropy_table = entropyTable(8);

        batch: [8]UIntType,
        batch_position: u32,
        workspace: bw.BitReadWorkspace(WorkspaceType, Reader),

        pub fn init(reader: Reader) Self {
            return .{
                .batch = [_]UIntType{0} ** 8,
                .batch_position = 8,
                .workspace = bw.bitReadWorkspace(WorkspaceType, reader),
            };
        }

        // pub fn get(self: *Self) !T {
        //     if (self.batch_position < 8) {
        //         defer self.batch_position += 1;
        //         return @bitCast(T, self.batch[self.batch_position]);
        //     }
        //     self.batch_position = 0;
        //     comptime var bit: u32 = 0;
        //     inline while (bit < @bitSizeOf(UIntType)) : (bit += 1) {
        //         var number = try self.workspace.getBits(
        //         var number: u8 = 0;
        //         comptime var element_id: u32 = 0;
        //         inline while (element_id < 8) : (element_id += 1) {
        //             number |= @intCast(u8, ((self.batch[element_id] >> bit) & 1) << (element_id));
        //         }
        //         const ones_count = @popCount(number);
        //         const zero_count = 8 - ones_count;
        //         if (ones_count < zero_count) {
        //             _ = try self.workspace.add(std.math.shl(u8, 1, ones_count) - 1, ones_count + 1);
        //         } else {
        //             _ = try self.workspace.add(std.math.shl(u8, 1, zero_count), zero_count + 1);
        //         }
        //         _ = try self.workspace.add(Self.entropy_table.index[number], Self.entropy_table.length[ones_count]);
        //     }
        // }
    };
}

pub fn entropyDecompressor(comptime T: type, reader: anytype) EntropyDecompressor(T, @TypeOf(reader)) {
    const Decompressor = EntropyDecompressor(T, @TypeOf(reader));
    return Decompressor.init(reader);
}

fn entropyTest(comptime T: type, data: []const T) !void {
    var buffer = [_]u8{0} ** 1024;
    {
        var stream = std.io.fixedBufferStream(&buffer);
        var counting = std.io.countingWriter(stream.writer());
        var entropy = entropyCompressor(T, counting.writer());
        for (data) |f| {
            try entropy.add(f);
        }
        try entropy.flush();
        const total_size = counting.bytes_written;
        const raw_size = data.len * @sizeOf(T);
        std.debug.print("total size {} bytes, raw size {} bytes, savings: {d:.2}%\n", .{ total_size, raw_size, (1.0 - @intToFloat(f32, total_size) / @intToFloat(f32, raw_size)) * 100 });
    }
}

test "entropy f32 embeddings test" {
    // var data = [_]f32{ 0.043154765, 0.164135829, -0.123626679, -0.167725742, -0.110710979, 0.102363497, 0.022291092, -0.187514856, -0.157604620, -0.065454222, 0.034411345, -0.226510420, 0.228433594, -0.070296884, -0.068169087, 0.049356200, -0.042770151, 0.151971295, 0.402687907, -0.366405696, 0.034094390, 0.051680047, -0.067786627, 0.160439745, -0.048753500, -0.196946219, 0.045420300, 0.189751863, 0.018866321, -0.002804127, -0.247762606, 0.365801245, 1.000000000, 0.405465096, -2.120258808 };
    var data = [_]f32{ 0.043154765, 0.164135829, -0.123626679, -0.167725742, -0.110710979, 0.102363497, 0.022291092, -0.187514856, -0.157604620, -0.065454222, 0.034411345, -0.226510420, 0.228433594, -0.070296884, -0.068169087, 0.049356200, -0.042770151, 0.151971295, 0.402687907, -0.366405696, 0.034094390, 0.051680047, -0.067786627, 0.160439745, -0.048753500, -0.196946219, 0.045420300, 0.189751863, 0.018866321, -0.002804127, -0.247762606, 0.365801245 };
    try entropyTest(f32, &data);
}

test "entropy f64 embeddings test" {
    // var data = [_]f64{ 0.043154765, 0.164135829, -0.123626679, -0.167725742, -0.110710979, 0.102363497, 0.022291092, -0.187514856, -0.157604620, -0.065454222, 0.034411345, -0.226510420, 0.228433594, -0.070296884, -0.068169087, 0.049356200, -0.042770151, 0.151971295, 0.402687907, -0.366405696, 0.034094390, 0.051680047, -0.067786627, 0.160439745, -0.048753500, -0.196946219, 0.045420300, 0.189751863, 0.018866321, -0.002804127, -0.247762606, 0.365801245, 1.000000000, 0.405465096, -2.120258808 };
    var data = [_]f64{ 0.043154765, 0.164135829, -0.123626679, -0.167725742, -0.110710979, 0.102363497, 0.022291092, -0.187514856, -0.157604620, -0.065454222, 0.034411345, -0.226510420, 0.228433594, -0.070296884, -0.068169087, 0.049356200, -0.042770151, 0.151971295, 0.402687907, -0.366405696, 0.034094390, 0.051680047, -0.067786627, 0.160439745, -0.048753500, -0.196946219, 0.045420300, 0.189751863, 0.018866321, -0.002804127, -0.247762606, 0.365801245 };
    try entropyTest(f64, &data);
}

test "entropy f32 cpu usage test" {
    // var data = [_]f32{ 15.904462, 16.393611, 16.775417, 16.912917, 16.88375, 16.376875, 16.208681, 16.586528, 17.123681, 16.650278, 16.534792, 16.692425, 16.456776, 15.761528, 16.051944, 15.914444, 16.04, 16.158194, 16.242292, 16.281528, 17.261042, 16.457639, 17.093681, 16.904653, 15.960417, 16.016667, 16.188 };
    var data = [_]f32{ 15.904462, 16.393611, 16.775417, 16.912917, 16.88375, 16.376875, 16.208681, 16.586528, 17.123681, 16.650278, 16.534792, 16.692425, 16.456776, 15.761528, 16.051944, 15.914444, 16.04, 16.158194, 16.242292, 16.281528, 17.261042, 16.457639, 17.093681, 16.904653 };
    try entropyTest(f32, &data);
}

test "entropy f64 cpu usage test" {
    // var data = [_]f64{ 15.904462, 16.393611, 16.775417, 16.912917, 16.88375, 16.376875, 16.208681, 16.586528, 17.123681, 16.650278, 16.534792, 16.692425, 16.456776, 15.761528, 16.051944, 15.914444, 16.04, 16.158194, 16.242292, 16.281528, 17.261042, 16.457639, 17.093681, 16.904653, 15.960417, 16.016667, 16.188 };
    var data = [_]f64{ 15.904462, 16.393611, 16.775417, 16.912917, 16.88375, 16.376875, 16.208681, 16.586528, 17.123681, 16.650278, 16.534792, 16.692425, 16.456776, 15.761528, 16.051944, 15.914444, 16.04, 16.158194, 16.242292, 16.281528, 17.261042, 16.457639, 17.093681, 16.904653 };
    try entropyTest(f64, &data);
}

test "entropy f32 sample from paper" {
    var data = [_]f32{ 15.5, 14.0625, 3.25, 8.625, 13.1 };
    try entropyTest(f32, &data);
}

test "entropy f64 sample from paper" {
    var data = [_]f64{ 15.5, 14.0625, 3.25, 8.625, 13.1 };
    try entropyTest(f64, &data);
}
