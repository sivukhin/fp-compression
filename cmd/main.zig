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
    input_name: ?[:0]const u8,
    output_name: ?[:0]const u8,
    params: ZscParams,
};

pub fn parseArgs(iterator: *std.process.ArgIterator) !ZscArgs {
    _ = iterator.skip();
    const command = iterator.next() orelse return error.CommandRequired;
    var input_name: ?[:0]const u8 = null;
    var output_name: ?[:0]const u8 = null;
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
            input_name = input;
            input_file = try dir.openFileZ(input, .{ .mode = .read_only });
        } else if (std.mem.eql(u8, token, "-o")) {
            const output = iterator.next() orelse return error.OutputRequired;
            output_name = output;
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
        .input_name = input_name,
        .output_name = output_name,
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
    try compressor.finish();
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
    defer {
        args.input.close();
        args.output.close();
    }

    var buffered_reader = std.io.bufferedReader(args.input.reader());
    var buffered_writer = std.io.bufferedWriter(args.output.writer());
    defer buffered_writer.flush() catch unreachable;

    var counting_reader = std.io.countingReader(buffered_reader.reader());
    var counting_writer = std.io.countingWriter(buffered_writer.writer());

    var reader = counting_reader.reader();
    var writer = counting_writer.writer();
    switch (args.params) {
        .compress => |c| {
            switch (c.algorithm) {
                .gorilla => {
                    if (c.width == 32) {
                        var compressor = zsc.gorilla.gorillaCompressor(u32, writer);
                        try compress(reader, &compressor);
                    } else if (c.width == 64) {
                        var compressor = zsc.gorilla.gorillaCompressor(u64, writer);
                        try compress(reader, &compressor);
                    }
                },
                .entropy => {
                    if (c.width == 32) {
                        var compressor = zsc.entropy.entropyCompressor(u32, writer);
                        try compress(reader, &compressor);
                    } else if (c.width == 64) {
                        var compressor = zsc.entropy.entropyCompressor(u64, writer);
                        try compress(reader, &compressor);
                    }
                },
            }
        },
        .decompress => |d| {
            switch (d.algorithm) {
                .gorilla => {
                    if (d.width == 32) {
                        var decompressor = zsc.gorilla.gorillaDecompressor(u32, reader);
                        try decompress(writer, &decompressor);
                    } else if (d.width == 64) {
                        var decompressor = zsc.gorilla.gorillaDecompressor(u64, reader);
                        try decompress(writer, &decompressor);
                    }
                },
                .entropy => {
                    if (d.width == 32) {
                        var decompressor = zsc.entropy.entropyDecompressor(u32, reader);
                        try decompress(writer, &decompressor);
                    } else if (d.width == 64) {
                        var decompressor = zsc.entropy.entropyDecompressor(u64, reader);
                        try decompress(writer, &decompressor);
                    }
                },
            }
        },
        .load => |l| try load(reader, writer, l),
        .dump => |d| try dump(reader, writer, d),
    }
    std.debug.print("{s}: {s} => {s} : {d:.2}% ({} => {} bytes)\n", .{
        @tagName(args.params),
        args.input_name orelse "stdin",
        args.output_name orelse "stdout",
        @intToFloat(f32, counting_writer.bytes_written) / @intToFloat(f32, counting_reader.bytes_read) * 100,
        counting_reader.bytes_read,
        counting_writer.bytes_written,
    });
}
