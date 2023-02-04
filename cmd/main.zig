const std = @import("std");
const zsc = @import("zsc");

const ZscMode = enum { compress, decompress };
const ZscAlgorithm = enum { gorilla, entropy };

const ZscCompressionParams = struct {
    algorithm: ZscAlgorithm,
    width: u32,
};

const ZscNumberType = enum { int, float };

const ZscConvertParams = struct {
    number_type: ZscNumberType,
    width: u32,
};

const ZscParams = union(enum) {
    compress: ZscCompressionParams,
    decompress: ZscCompressionParams,
    load: ZscConvertParams,
    dump: ZscConvertParams,
};

const ZscArgs = struct {
    input: std.fs.File,
    output: std.fs.File,
    params: ZscParams,
};

pub fn parseArgs(iterator: *std.process.ArgIterator) !ZscArgs {
    _ = iterator.skip();
    const command = iterator.next() orelse return error.CommandRequired;
    var input_file: ?std.fs.File = null;
    var output_file: ?std.fs.File = null;
    var width: u32 = 32;
    var algorithm: ZscAlgorithm = .gorilla;
    var number_type: ZscNumberType = .float;

    errdefer {
        if (input_file) |f| {
            f.close();
        }
        if (output_file) |f| {
            f.close();
        }
    }

    var dir = std.fs.cwd();
    while (iterator.next()) |token| {
        if (std.mem.eql(u8, token, "-i")) {
            const input = iterator.next() orelse return error.InputRequired;
            input_file = try dir.openFileZ(input, .{ .mode = .read_only });
        } else if (std.mem.eql(u8, token, "-o")) {
            const output = iterator.next() orelse return error.OutputRequired;
            output_file = try dir.createFileZ(output, .{});
        } else if (std.mem.eql(u8, token, "-a")) {
            const algorithm_string = iterator.next() orelse return error.AlgorithmRequired;
            algorithm = std.meta.stringToEnum(ZscAlgorithm, algorithm_string) orelse return error.UnknownAlgorithm;
        } else if (std.mem.eql(u8, token, "-w")) {
            const width_string = iterator.next() orelse return error.WidthRequired;
            width = try std.fmt.parseInt(u32, width_string, 10);
            if (width != 32 and width != 64) {
                return error.InvalidWidth;
            }
        } else if (std.mem.eql(u8, token, "-t")) {
            const number_type_string = iterator.next() orelse return error.NumberTypeRequired;
            number_type = std.meta.stringToEnum(ZscNumberType, number_type_string) orelse return error.UnknownNumberType;
        }
    }
    var params: ZscParams = undefined;
    if (std.mem.eql(u8, command, "compress")) {
        params = ZscParams{ .compress = .{ .width = width, .algorithm = algorithm } };
    } else if (std.mem.eql(u8, command, "decompress")) {
        params = ZscParams{ .decompress = .{ .width = width, .algorithm = algorithm } };
    } else if (std.mem.eql(u8, command, "load")) {
        params = ZscParams{ .load = .{ .number_type = number_type, .width = width } };
    } else if (std.mem.eql(u8, command, "dump")) {
        params = ZscParams{ .dump = .{ .number_type = number_type, .width = width } };
    } else {
        return error.UnknownCommand;
    }
    return .{
        .input = input_file orelse std.io.getStdIn(),
        .output = output_file orelse std.io.getStdOut(),
        .params = params,
    };
}

fn readAtLeast(reader: anytype, buffer: []u8, count: usize) !usize {
    var read_size: usize = 0;
    while (read_size < count) {
        const chunk_size = try reader.read(buffer[read_size..buffer.len]);
        read_size += chunk_size;
        if (chunk_size == 0) {
            break;
        }
    }
    return read_size;
}

fn pad(buffer: []u8, length: usize) void {
    var i = length;
    var first = true;
    while (i < buffer.len) : (i += 1) {
        buffer[i] = if (first) 1 else 0;
        first = false;
    }
}

fn unpad(buffer: []u8) []u8 {
    var i = buffer.len - 1;
    while (buffer[i] == 0) : (i -= 1) {}
    return buffer[0..i];
}

fn compress(reader: anytype, compressor: anytype) !void {
    const width = @typeInfo(@TypeOf(compressor)).Pointer.child.width / 8;
    var buffer: [width]u8 = undefined;
    while (readAtLeast(reader, &buffer, buffer.len)) |length| {
        pad(&buffer, length);
        const int = std.mem.readIntSliceNative(u32, &buffer);
        try compressor.add(int);
        if (length < buffer.len) {
            break;
        }
    } else |err| return err;
    try compressor.flush();
}

fn decompress(writer: anytype, decompressor: anytype) !void {
    const width = @typeInfo(@TypeOf(decompressor)).Pointer.child.width / 8;
    var buffer: [width]u8 = undefined;
    var first = true;
    while (decompressor.get()) |value| {
        if (!first) {
            try writer.writeAll(&buffer);
        }
        first = false;
        buffer = std.mem.toBytes(value);
    } else |err| {
        if (err != error.EndOfStream) return err;
    }
    try writer.writeAll(unpad(&buffer));
}

fn dump(reader: anytype, writer: anytype, params: ZscConvertParams) !void {
    const bytes = params.width / 8;
    var buffer: [32]u8 = undefined;
    var slice = (&buffer)[0..bytes];
    while (reader.readAll(slice)) |size| {
        if (size == 0) {
            break;
        }
        if (size != bytes) {
            return error.CorruptedInput;
        }
        if (params.width == 32 and params.number_type == .int) {
            try std.fmt.format(writer, "{} ", .{std.mem.readIntSliceNative(u32, slice)});
        } else if (params.width == 64 and params.number_type == .int) {
            try std.fmt.format(writer, "{} ", .{std.mem.readIntSliceNative(u64, slice)});
        } else if (params.width == 32 and params.number_type == .float) {
            try std.fmt.format(writer, "{} ", .{@bitCast(f32, std.mem.readIntSliceNative(u32, slice))});
        } else if (params.width == 64 and params.number_type == .float) {
            try std.fmt.format(writer, "{} ", .{@bitCast(f64, std.mem.readIntSliceNative(u64, slice))});
        }
    } else |err| {
        if (err != error.EndOfStream) return err;
    }
    try std.fmt.format(writer, "\n", .{});
}

fn load(reader: anytype, writer: anytype, params: ZscConvertParams) !void {
    var buffer: [1024]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buffer, ' ')) |token| {
        var number = std.mem.trim(u8, token, " \n");
        if (params.width == 32 and params.number_type == .int) {
            try writer.writeIntNative(u32, try std.fmt.parseInt(u32, number, 10));
        } else if (params.width == 64 and params.number_type == .int) {
            try writer.writeIntNative(u64, try std.fmt.parseInt(u64, number, 10));
        } else if (params.width == 32 and params.number_type == .float) {
            try writer.writeIntNative(u32, @bitCast(u32, try std.fmt.parseFloat(f32, number)));
        } else if (params.width == 64 and params.number_type == .float) {
            try writer.writeIntNative(u64, @bitCast(u64, try std.fmt.parseFloat(f64, number)));
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var process_args = try std.process.argsWithAllocator(gpa.allocator());
    defer process_args.deinit();

    const args = parseArgs(&process_args) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        return;
    };

    var reader = args.input.reader();
    var writer = args.output.writer();
    switch (args.params) {
        .compress => |c| {
            switch (c.algorithm) {
                .gorilla => {
                    var compressor = zsc.gorilla.gorillaCompressor(u32, writer);
                    try compress(reader, &compressor);
                },
                .entropy => {
                    var compressor = zsc.entropy.entropyCompressor(u32, writer);
                    try compress(reader, &compressor);
                },
            }
        },
        .decompress => |d| {
            switch (d.algorithm) {
                .gorilla => {
                    var decompressor = zsc.gorilla.gorillaDecompressor(u32, reader);
                    try decompress(writer, &decompressor);
                },
                .entropy => {
                    var decompressor = zsc.entropy.entropyDecompressor(u32, reader);
                    try decompress(writer, &decompressor);
                },
            }
        },
        .load => |l| try load(reader, writer, l),
        .dump => |d| try dump(reader, writer, d),
    }
}
