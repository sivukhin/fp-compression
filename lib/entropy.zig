const std = @import("std");
const testing = std.testing;
const bw = @import("bit-workspace.zig");

pub fn EntropyTable(comptime n: comptime_int) type {
    return struct {
        const Self = @This();
        length: [n + 1]u8,
        index_by_value: [1 << n]u32,
        value_by_index: [n + 1][1 << n]u32,
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
        var length: [n + 1]u8 = [_]u8{0} ** (n + 1);
        var index_by_value: [1 << n]u32 = undefined;
        var value_by_index: [n + 1][1 << n]u32 = undefined;
        index_by_value[0] = 0;
        index_by_value[(1 << n) - 1] = 0;
        value_by_index[0][0] = 0;
        value_by_index[n][0] = (1 << n) - 1;
        var i: u32 = (1 << n) - 2;
        while (i > 0) : (i -= 1) {
            const next = nextMask(i);
            if (next >= (1 << n)) {
                index_by_value[i] = 0;
            } else {
                index_by_value[i] = index_by_value[next] + 1;
            }
            value_by_index[@popCount(i)][index_by_value[i]] = i;
            length[@popCount(i)] = @intCast(u8, std.math.log2_int_ceil(u32, index_by_value[i] + 1));
        }
        return table{
            .length = length,
            .index_by_value = index_by_value,
            .value_by_index = value_by_index,
        };
    }
}

test "entropy table" {
    const table = entropyTable(8);
    const expected = [_]u8{ 0, 3, 5, 6, 7, 6, 5, 3, 0 };
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
        pub const width = @bitSizeOf(T);
        const Self = @This();
        const entropy_table = entropyTable(8);

        batch: [256]UIntType,
        batch_size: u32,
        counts: [@bitSizeOf(UIntType)]u8,
        workspace: bw.BitWriteWorkspace(WorkspaceType, Writer),

        pub fn init(writer: Writer) Self {
            return .{
                .batch = [_]UIntType{0} ** 256,
                .batch_size = 0,
                .counts = [_]u8{8} ** @bitSizeOf(UIntType),
                .workspace = bw.bitWriteWorkspace(WorkspaceType, writer),
            };
        }

        pub fn add(self: *Self, element: T) !void {
            self.batch[self.batch_size] = @bitCast(UIntType, element);
            self.batch_size += 1;
            if (self.batch_size < self.batch.len) {
                return;
            }
            try self.workspace.unsafeAdd(1, 1);
            try self.dump();
        }

        pub fn finish(self: *Self) !void {
            if (self.batch_size % 8 != 0) {
                try self.workspace.unsafeAdd(self.batch_size << 1, 9);
                while (self.batch_size % 8 != 0) : (self.batch_size += 1) {
                    self.batch[self.batch_size] = self.batch[self.batch_size - 1];
                }
                try self.dump();
            }
            try self.workspace.finish();
        }

        fn dump(self: *Self) !void {
            var i: u32 = 0;
            while (i < self.batch_size) : (i += 8) {
                try self.dump8(i);
            }
            self.batch_size = 0;
        }

        fn dump8(self: *Self, position: u32) !void {
            var bit: u32 = 0;
            while (bit < @bitSizeOf(UIntType)) : (bit += 1) {
                try self.workspace.flush();

                var number: u8 = 0;
                comptime var element_id: u32 = 0;
                inline while (element_id < 8) : (element_id += 1) {
                    number |= @intCast(u8, (std.math.shr(UIntType, self.batch[position + element_id], bit) & 1) << (element_id));
                }
                const ones_count = @popCount(number);
                const zero_count = 8 - ones_count;
                const min_count = std.math.min(ones_count, zero_count);
                if (self.counts[bit] > 1) {
                    try self.workspace.unsafeAdd(number, 8);
                } else {
                    try self.workspace.unsafeAdd(if (ones_count < zero_count) @as(u1, 1) else @as(u1, 0), 1);
                    try self.workspace.unsafeAdd(std.math.shl(u8, 1, min_count), min_count + 1);
                    try self.workspace.unsafeAdd(Self.entropy_table.index_by_value[number], Self.entropy_table.length[ones_count]);
                }
                self.counts[bit] = std.math.min(ones_count, zero_count);
            }
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
        pub const width = @bitSizeOf(T);
        const Self = @This();
        const entropy_table = entropyTable(8);

        batch: [256]UIntType,
        batch_position: u32,
        batch_capacity: u32,
        counts: [@bitSizeOf(UIntType)]u8,
        workspace: bw.BitReadWorkspace(WorkspaceType, Reader),

        pub fn init(reader: Reader) Self {
            return .{
                .batch = [_]UIntType{0} ** 256,
                .batch_position = 256,
                .batch_capacity = 256,
                .counts = [_]u8{8} ** @bitSizeOf(UIntType),
                .workspace = bw.bitReadWorkspace(WorkspaceType, reader),
            };
        }

        pub fn get(self: *Self) !T {
            if (self.batch_position == self.batch.len) {
                try self.load();
            }
            if (self.batch_position == self.batch_capacity) {
                return error.EndOfStream;
            }
            defer self.batch_position += 1;
            return @bitCast(T, self.batch[self.batch_position]);
        }

        fn load(self: *Self) !void {
            self.batch_position = 0;
            self.batch_capacity = if (try self.workspace.getFull(u1) == 0) try self.workspace.getBits(u8, 8) else 256;
            inline for (self.batch) |*value| {
                value.* = 0;
            }
            var i: u32 = 0;
            while (i < self.batch_capacity) : (i += 8) {
                try self.load8(i);
            }
        }

        fn load8(self: *Self, position: u32) !void {
            comptime var bit: u32 = 0;
            inline while (bit < @bitSizeOf(UIntType)) : (bit += 1) {
                var number: u8 = 0;
                var ones_count: u8 = 0;
                if (self.counts[bit] > 1) {
                    number = try self.workspace.getFull(u8);
                    ones_count = @popCount(number);
                } else {
                    var min_count: u8 = 0;
                    const first_bit = try self.workspace.getFull(u1);
                    while (try self.workspace.getFull(u1) == 0) : (min_count += 1) {}
                    ones_count = if (first_bit == 1) min_count else 8 - min_count;
                    const index = try self.workspace.getBits(u8, @as(u8, Self.entropy_table.length[ones_count]));
                    number = @intCast(u8, Self.entropy_table.value_by_index[ones_count][index]);
                }
                comptime var element_id: u32 = 0;
                inline while (element_id < 8) : (element_id += 1) {
                    self.batch[position + element_id] |= std.math.shl(UIntType, ((number >> element_id) & 1), bit);
                }
                self.counts[bit] = std.math.min(ones_count, 8 - ones_count);
            }
        }
    };
}

pub fn entropyDecompressor(comptime T: type, reader: anytype) EntropyDecompressor(T, @TypeOf(reader)) {
    const Decompressor = EntropyDecompressor(T, @TypeOf(reader));
    return Decompressor.init(reader);
}

fn entropyTest(comptime T: type, data: []const T) !void {
    var buffer = [_]u8{0} ** (1 << 16);
    {
        var stream = std.io.fixedBufferStream(&buffer);
        var counting = std.io.countingWriter(stream.writer());
        var entropy = entropyCompressor(T, counting.writer());
        for (data) |f| {
            try entropy.add(f);
        }
        try entropy.finish();
        const total_size = counting.bytes_written;
        const raw_size = data.len * @sizeOf(T);
        std.debug.print("total size {} bytes, raw size {} bytes, savings: {d:.2}%\n", .{ total_size, raw_size, (1.0 - @intToFloat(f32, total_size) / @intToFloat(f32, raw_size)) * 100 });
    }
    {
        var stream = std.io.fixedBufferStream(&buffer);
        var entropy = entropyDecompressor(T, stream.reader());
        for (data) |f| {
            try testing.expectEqual(f, try entropy.get());
        }
    }
}

test "entropy f32 embeddings test" {
    var data = [_]f32{ 0.043154765, 0.164135829, -0.123626679, -0.167725742, -0.110710979, 0.102363497, 0.022291092, -0.187514856, -0.157604620, -0.065454222, 0.034411345, -0.226510420, 0.228433594, -0.070296884, -0.068169087, 0.049356200, -0.042770151, 0.151971295, 0.402687907, -0.366405696, 0.034094390, 0.051680047, -0.067786627, 0.160439745, -0.048753500, -0.196946219, 0.045420300, 0.189751863, 0.018866321, -0.002804127, -0.247762606, 0.365801245, 1.000000000, 0.405465096, -2.120258808 };
    try entropyTest(f32, &data);
}

test "entropy f64 embeddings test" {
    var data = [_]f64{ 0.043154765, 0.164135829, -0.123626679, -0.167725742, -0.110710979, 0.102363497, 0.022291092, -0.187514856, -0.157604620, -0.065454222, 0.034411345, -0.226510420, 0.228433594, -0.070296884, -0.068169087, 0.049356200, -0.042770151, 0.151971295, 0.402687907, -0.366405696, 0.034094390, 0.051680047, -0.067786627, 0.160439745, -0.048753500, -0.196946219, 0.045420300, 0.189751863, 0.018866321, -0.002804127, -0.247762606, 0.365801245, 1.000000000, 0.405465096, -2.120258808 };
    try entropyTest(f64, &data);
}

test "entropy f32 cpu usage test" {
    var data = [_]f32{ 15.904462, 16.393611, 16.775417, 16.912917, 16.88375, 16.376875, 16.208681, 16.586528, 17.123681, 16.650278, 16.534792, 16.692425, 16.456776, 15.761528, 16.051944, 15.914444, 16.04, 16.158194, 16.242292, 16.281528, 17.261042, 16.457639, 17.093681, 16.904653, 15.960417, 16.016667, 16.188 };
    try entropyTest(f32, &data);
}

test "entropy f64 cpu usage test" {
    var data = [_]f64{ 15.904462, 16.393611, 16.775417, 16.912917, 16.88375, 16.376875, 16.208681, 16.586528, 17.123681, 16.650278, 16.534792, 16.692425, 16.456776, 15.761528, 16.051944, 15.914444, 16.04, 16.158194, 16.242292, 16.281528, 17.261042, 16.457639, 17.093681, 16.904653, 15.960417, 16.016667, 16.188 };
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

test "entropy stress" {
    var random = std.rand.DefaultPrng.init(0);
    var data = [_]f32{0} ** (1 << 13);
    for (data) |*value| {
        value.* = random.random().floatNorm(f32);
    }
    try entropyTest(f32, &data);
}
