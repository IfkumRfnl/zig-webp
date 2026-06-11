//! VP8L lossless image-data prefix-code parsing.

const std = @import("std");
const assert = std.debug.assert;

const bit_reader = @import("../bit_reader.zig");
const bit_writer = @import("../bit_writer.zig");
const errors = @import("../errors.zig");
const huffman = @import("huffman.zig");
const image = @import("../image.zig");

pub const prefix_code_count = 5;
pub const color_cache_bits_min: u4 = 1;
pub const color_cache_bits_max: u4 = huffman.color_cache_bits_max;
pub const prefix_bits_min: u4 = 2;
pub const prefix_bits_max: u4 = 9;
pub const length_code_repeat_previous = 16;
pub const length_code_repeat_zero_short = 17;
pub const length_code_repeat_zero_long = 18;

pub const Role = enum {
    argb,
    transform,
};

pub const Channel = enum(u3) {
    green = 0,
    red = 1,
    blue = 2,
    alpha = 3,
    distance = 4,
};

pub const ColorCache = struct {
    bits: u4,
    size: u16,
};

pub const MetaPrefix = union(enum) {
    none: void,
    single: void,
};

pub const ImageData = struct {
    dimensions: image.Dimensions,
    role: Role,
    color_cache: ?ColorCache,
    meta_prefix: MetaPrefix,
    prefix_codes: PrefixCodeGroup,
};

pub const ScanSummary = struct {
    pixel_count: u64,
    literal_count: u64,
    copy_count: u64,
    color_cache_count: u64,
};

pub const PrefixCodeGroup = struct {
    green: huffman.SymbolTable,
    red: huffman.SymbolTable,
    blue: huffman.SymbolTable,
    alpha: huffman.SymbolTable,
    distance: huffman.SymbolTable,

    pub fn table(self: PrefixCodeGroup, channel: Channel) huffman.SymbolTable {
        return switch (channel) {
            .green => self.green,
            .red => self.red,
            .blue => self.blue,
            .alpha => self.alpha,
            .distance => self.distance,
        };
    }
};

pub const PrefixCodeGroupBuffers = struct {
    code_lengths: [huffman.green_alphabet_size_max]u8 = .{0} ** huffman.green_alphabet_size_max,
    code_length_entries: [huffman.CodeLengthTable.entry_count_limit]huffman.Entry = undefined,
    green_entries: [huffman.SymbolTable.entry_count_limit]huffman.Entry = undefined,
    red_entries: [huffman.SymbolTable.entry_count_limit]huffman.Entry = undefined,
    blue_entries: [huffman.SymbolTable.entry_count_limit]huffman.Entry = undefined,
    alpha_entries: [huffman.SymbolTable.entry_count_limit]huffman.Entry = undefined,
    distance_entries: [huffman.SymbolTable.entry_count_limit]huffman.Entry = undefined,
};

comptime {
    assert(prefix_code_count == 5);
    assert(color_cache_bits_min == 1);
    assert(color_cache_bits_max == 11);
    assert(prefix_bits_min == 2);
    assert(prefix_bits_max == prefix_bits_min + 7);
    assert(length_code_repeat_previous == 16);
    assert(length_code_repeat_zero_short == 17);
    assert(length_code_repeat_zero_long == 18);
}

pub fn readSingleGroup(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    role: Role,
    buffers: *PrefixCodeGroupBuffers,
) errors.Error!ImageData {
    const color_cache = try readColorCache(reader);
    const meta_prefix = try readMetaPrefix(reader, role);
    const prefix_codes = try readPrefixCodeGroup(
        reader,
        colorCacheSize(color_cache),
        buffers,
    );

    return .{
        .dimensions = dimensions,
        .role = role,
        .color_cache = color_cache,
        .meta_prefix = meta_prefix,
        .prefix_codes = prefix_codes,
    };
}

pub fn scanSingleGroup(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    role: Role,
    buffers: *PrefixCodeGroupBuffers,
) errors.Error!ScanSummary {
    const data = try readSingleGroup(reader, dimensions, role, buffers);
    return scanEntropyCodedImage(reader, data.dimensions, data.color_cache, data.prefix_codes);
}

pub fn readPrefixCodeGroup(
    reader: *bit_reader.BitReader,
    color_cache_size: u16,
    buffers: *PrefixCodeGroupBuffers,
) errors.Error!PrefixCodeGroup {
    if (color_cache_size > huffman.color_cache_size_max) return error.InvalidVP8LImageData;

    return .{
        .green = try readPrefixCode(
            reader,
            alphabetSize(.green, color_cache_size),
            &buffers.green_entries,
            buffers,
        ),
        .red = try readPrefixCode(
            reader,
            alphabetSize(.red, color_cache_size),
            &buffers.red_entries,
            buffers,
        ),
        .blue = try readPrefixCode(
            reader,
            alphabetSize(.blue, color_cache_size),
            &buffers.blue_entries,
            buffers,
        ),
        .alpha = try readPrefixCode(
            reader,
            alphabetSize(.alpha, color_cache_size),
            &buffers.alpha_entries,
            buffers,
        ),
        .distance = try readPrefixCode(
            reader,
            alphabetSize(.distance, color_cache_size),
            &buffers.distance_entries,
            buffers,
        ),
    };
}

fn scanEntropyCodedImage(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    color_cache: ?ColorCache,
    prefix_codes: PrefixCodeGroup,
) errors.Error!ScanSummary {
    const pixel_count = try dimensions.pixelCount();
    var summary = ScanSummary{
        .pixel_count = 0,
        .literal_count = 0,
        .copy_count = 0,
        .color_cache_count = 0,
    };

    while (summary.pixel_count < pixel_count) {
        const green_symbol = try prefix_codes.green.decode(reader);
        if (green_symbol < huffman.literal_alphabet_size) {
            _ = try prefix_codes.red.decode(reader);
            _ = try prefix_codes.blue.decode(reader);
            _ = try prefix_codes.alpha.decode(reader);
            summary.pixel_count += 1;
            summary.literal_count += 1;
        } else if (green_symbol < huffman.literal_alphabet_size + huffman.length_code_count) {
            const length_prefix: u8 = @intCast(green_symbol - huffman.literal_alphabet_size);
            const length = try readPrefixValue(reader, length_prefix);
            if (length > pixel_count - summary.pixel_count) return error.InvalidVP8LImageData;

            const distance_prefix: u8 = @intCast(try prefix_codes.distance.decode(reader));
            const distance_code = try readPrefixValue(reader, distance_prefix);
            const distance = distanceFromCode(distance_code, dimensions.width);
            if (distance > summary.pixel_count) return error.InvalidVP8LImageData;

            summary.pixel_count += length;
            summary.copy_count += 1;
        } else {
            const cache = color_cache orelse return error.InvalidVP8LImageData;
            const cache_index = green_symbol -
                huffman.literal_alphabet_size -
                huffman.length_code_count;
            if (cache_index >= cache.size) return error.InvalidVP8LImageData;

            summary.pixel_count += 1;
            summary.color_cache_count += 1;
        }
    }

    assert(summary.pixel_count == pixel_count);
    return summary;
}

pub fn readPrefixValue(reader: *bit_reader.BitReader, prefix_code: u8) errors.Error!u32 {
    if (prefix_code >= huffman.distance_alphabet_size) return error.InvalidVP8LImageData;
    if (prefix_code < 4) return @as(u32, prefix_code) + 1;

    const extra_bits: u5 = @intCast((prefix_code - 2) >> 1);
    const offset = @as(u32, 2 + (prefix_code & 1)) << extra_bits;

    return offset + try reader.readBits(extra_bits) + 1;
}

pub fn distanceFromCode(distance_code: u32, image_width: u32) u64 {
    assert(distance_code > 0);
    assert(image_width > 0);

    if (distance_code > distance_map.len) return distance_code - distance_map.len;

    const offset = distance_map[distance_code - 1];
    const distance = @as(i64, offset.x) + @as(i64, offset.y) * @as(i64, image_width);
    if (distance < 1) return 1;

    return @intCast(distance);
}

fn readColorCache(reader: *bit_reader.BitReader) errors.Error!?ColorCache {
    const present = try reader.readBit();
    if (present == 0) return null;

    const bits: u4 = @intCast(try reader.readBits(4));
    if (bits < color_cache_bits_min) return error.InvalidVP8LImageData;
    if (bits > color_cache_bits_max) return error.InvalidVP8LImageData;

    return .{
        .bits = bits,
        .size = @as(u16, 1) << bits,
    };
}

fn readMetaPrefix(reader: *bit_reader.BitReader, role: Role) errors.Error!MetaPrefix {
    return switch (role) {
        .transform => .{ .none = {} },
        .argb => {
            const present = try reader.readBit();
            if (present == 0) return .{ .single = {} };

            return error.UnsupportedVP8LImageData;
        },
    };
}

fn readPrefixCode(
    reader: *bit_reader.BitReader,
    alphabet_size: u16,
    entries: []huffman.Entry,
    buffers: *PrefixCodeGroupBuffers,
) errors.Error!huffman.SymbolTable {
    assert(alphabet_size > 0);
    assert(alphabet_size <= huffman.green_alphabet_size_max);

    const code_lengths = buffers.code_lengths[0..alphabet_size];
    @memset(code_lengths, 0);

    const simple_code = try reader.readBit();
    if (simple_code == 1) {
        try readSimpleCodeLengths(reader, code_lengths);
    } else {
        try readNormalCodeLengths(reader, alphabet_size, code_lengths, buffers);
    }

    return huffman.SymbolTable.build(entries, code_lengths);
}

fn readSimpleCodeLengths(
    reader: *bit_reader.BitReader,
    code_lengths: []u8,
) errors.Error!void {
    assert(code_lengths.len > 0);
    assert(code_lengths.len <= huffman.green_alphabet_size_max);

    const symbol_count = @as(u2, try reader.readBit()) + 1;
    const is_first_8bits = try reader.readBit();
    const symbol0_bits: u6 = if (is_first_8bits == 1) 8 else 1;
    const symbol0 = try reader.readBits(symbol0_bits);
    if (symbol0 >= code_lengths.len) return error.InvalidVP8LImageData;
    code_lengths[@intCast(symbol0)] = 1;

    if (symbol_count == 2) {
        const symbol1 = try reader.readBits(8);
        if (symbol1 >= code_lengths.len) return error.InvalidVP8LImageData;
        code_lengths[@intCast(symbol1)] = 1;
    }
}

fn readNormalCodeLengths(
    reader: *bit_reader.BitReader,
    alphabet_size: u16,
    code_lengths: []u8,
    buffers: *PrefixCodeGroupBuffers,
) errors.Error!void {
    assert(alphabet_size > 0);
    assert(code_lengths.len == alphabet_size);

    var code_length_code_lengths: [huffman.code_length_code_count]u8 =
        .{0} ** huffman.code_length_code_count;
    const code_length_count = @as(usize, 4) + try reader.readBits(4);
    assert(code_length_count >= 4);
    assert(code_length_count <= huffman.code_length_code_count);

    var code_length_index: usize = 0;
    while (code_length_index < code_length_count) : (code_length_index += 1) {
        const ordered_index = huffman.code_length_code_order[code_length_index];
        code_length_code_lengths[ordered_index] = @intCast(try reader.readBits(3));
    }

    const code_length_table = try huffman.CodeLengthTable.build(
        &buffers.code_length_entries,
        &code_length_code_lengths,
    );
    const code_length_symbol_count = try readMaxSymbolCount(reader, alphabet_size);
    try readCodeLengthSymbols(
        reader,
        code_length_table,
        code_lengths,
        code_length_symbol_count,
    );
}

fn readMaxSymbolCount(
    reader: *bit_reader.BitReader,
    alphabet_size: u16,
) errors.Error!usize {
    assert(alphabet_size > 0);
    assert(alphabet_size <= huffman.green_alphabet_size_max);

    const use_limited_alphabet = try reader.readBit();
    if (use_limited_alphabet == 0) return alphabet_size;

    const length_bits: u6 = @intCast(2 + 2 * try reader.readBits(3));
    const symbol_count = @as(usize, 2) + try reader.readBits(length_bits);
    if (symbol_count > alphabet_size) return error.InvalidVP8LImageData;

    return symbol_count;
}

fn readCodeLengthSymbols(
    reader: *bit_reader.BitReader,
    table: huffman.CodeLengthTable,
    code_lengths: []u8,
    code_length_symbol_count: usize,
) errors.Error!void {
    assert(code_lengths.len > 0);
    assert(code_lengths.len <= huffman.green_alphabet_size_max);
    assert(code_length_symbol_count <= code_lengths.len);

    var previous_nonzero_length: u8 = 8;
    var code_length_symbols_remaining = code_length_symbol_count;
    var symbol_index: usize = 0;
    while (symbol_index < code_lengths.len) {
        if (code_length_symbols_remaining == 0) break;
        code_length_symbols_remaining -= 1;

        const symbol = try table.decode(reader);
        switch (symbol) {
            0...15 => {
                const code_length: u8 = @intCast(symbol);
                code_lengths[symbol_index] = code_length;
                symbol_index += 1;
                if (code_length != 0) previous_nonzero_length = code_length;
            },
            length_code_repeat_previous => {
                const repeat_count = @as(usize, 3) + try reader.readBits(2);
                try repeatCodeLength(
                    code_lengths,
                    &symbol_index,
                    repeat_count,
                    previous_nonzero_length,
                );
            },
            length_code_repeat_zero_short => {
                const repeat_count = @as(usize, 3) + try reader.readBits(3);
                try repeatCodeLength(code_lengths, &symbol_index, repeat_count, 0);
            },
            length_code_repeat_zero_long => {
                const repeat_count = @as(usize, 11) + try reader.readBits(7);
                try repeatCodeLength(code_lengths, &symbol_index, repeat_count, 0);
            },
            else => return error.InvalidHuffmanCode,
        }
    }
}

fn repeatCodeLength(
    code_lengths: []u8,
    symbol_index: *usize,
    repeat_count: usize,
    code_length: u8,
) errors.Error!void {
    assert(symbol_index.* <= code_lengths.len);
    assert(code_length <= huffman.max_code_bits);

    if (repeat_count > code_lengths.len - symbol_index.*) {
        return error.InvalidVP8LImageData;
    }

    const start = symbol_index.*;
    const end = start + repeat_count;
    @memset(code_lengths[start..end], code_length);
    symbol_index.* = end;
}

fn colorCacheSize(color_cache: ?ColorCache) u16 {
    return if (color_cache) |cache| cache.size else 0;
}

fn alphabetSize(channel: Channel, color_cache_size: u16) u16 {
    assert(color_cache_size <= huffman.color_cache_size_max);

    return switch (channel) {
        .green => huffman.literal_alphabet_size + huffman.length_code_count + color_cache_size,
        .red,
        .blue,
        .alpha,
        => huffman.literal_alphabet_size,
        .distance => huffman.distance_alphabet_size,
    };
}

fn writeSimplePrefixCode(writer: *bit_writer.BitWriter, symbol: u8) errors.Error!void {
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(if (symbol <= 1) 0 else 1);
    try writer.writeBits(symbol, if (symbol <= 1) 1 else 8);
}

fn writeNormalTwoSymbolPrefixCode(writer: *bit_writer.BitWriter) errors.Error!void {
    try writer.writeBit(0);
    try writer.writeBits(0, 4);
    try writer.writeBits(0, 3);
    try writer.writeBits(0, 3);
    try writer.writeBits(0, 3);
    try writer.writeBits(1, 3);
    try writer.writeBit(1);
    try writer.writeBits(0, 3);
    try writer.writeBits(0, 2);
}

fn writeNormalSingleLengthSymbol256PrefixCode(
    writer: *bit_writer.BitWriter,
) errors.Error!void {
    try writer.writeBit(0);
    try writer.writeBits(0, 4);
    try writer.writeBits(0, 3);
    try writer.writeBits(1, 3);
    try writer.writeBits(0, 3);
    try writer.writeBits(1, 3);
    try writer.writeBit(1);
    try writer.writeBits(0, 3);
    try writer.writeBits(1, 2);

    try writer.writeBits(1, 1);
    try writer.writeBits(127, 7);
    try writer.writeBits(1, 1);
    try writer.writeBits(107, 7);
    try writer.writeBits(0, 1);
}

fn writeLiteralOnlyPrefixCodeGroup(writer: *bit_writer.BitWriter) errors.Error!void {
    var code_index: usize = 0;
    while (code_index < prefix_code_count) : (code_index += 1) {
        try writeSimplePrefixCode(writer, @intFromBool(code_index == 0));
    }
}

fn writeSimplePrefixCodeGroup(writer: *bit_writer.BitWriter) errors.Error!void {
    var code_index: usize = 0;
    while (code_index < prefix_code_count) : (code_index += 1) {
        try writeSimplePrefixCode(writer, 0);
    }
}

const DistanceOffset = struct {
    x: i8,
    y: i8,
};

const distance_map = [_]DistanceOffset{
    .{ .x = 0, .y = 1 },
    .{ .x = 1, .y = 0 },
    .{ .x = 1, .y = 1 },
    .{ .x = -1, .y = 1 },
    .{ .x = 0, .y = 2 },
    .{ .x = 2, .y = 0 },
    .{ .x = 1, .y = 2 },
    .{ .x = -1, .y = 2 },
    .{ .x = 2, .y = 1 },
    .{ .x = -2, .y = 1 },
    .{ .x = 2, .y = 2 },
    .{ .x = -2, .y = 2 },
    .{ .x = 0, .y = 3 },
    .{ .x = 3, .y = 0 },
    .{ .x = 1, .y = 3 },
    .{ .x = -1, .y = 3 },
    .{ .x = 3, .y = 1 },
    .{ .x = -3, .y = 1 },
    .{ .x = 2, .y = 3 },
    .{ .x = -2, .y = 3 },
    .{ .x = 3, .y = 2 },
    .{ .x = -3, .y = 2 },
    .{ .x = 0, .y = 4 },
    .{ .x = 4, .y = 0 },
    .{ .x = 1, .y = 4 },
    .{ .x = -1, .y = 4 },
    .{ .x = 4, .y = 1 },
    .{ .x = -4, .y = 1 },
    .{ .x = 3, .y = 3 },
    .{ .x = -3, .y = 3 },
    .{ .x = 2, .y = 4 },
    .{ .x = -2, .y = 4 },
    .{ .x = 4, .y = 2 },
    .{ .x = -4, .y = 2 },
    .{ .x = 0, .y = 5 },
    .{ .x = 3, .y = 4 },
    .{ .x = -3, .y = 4 },
    .{ .x = 4, .y = 3 },
    .{ .x = -4, .y = 3 },
    .{ .x = 5, .y = 0 },
    .{ .x = 1, .y = 5 },
    .{ .x = -1, .y = 5 },
    .{ .x = 5, .y = 1 },
    .{ .x = -5, .y = 1 },
    .{ .x = 2, .y = 5 },
    .{ .x = -2, .y = 5 },
    .{ .x = 5, .y = 2 },
    .{ .x = -5, .y = 2 },
    .{ .x = 4, .y = 4 },
    .{ .x = -4, .y = 4 },
    .{ .x = 3, .y = 5 },
    .{ .x = -3, .y = 5 },
    .{ .x = 5, .y = 3 },
    .{ .x = -5, .y = 3 },
    .{ .x = 0, .y = 6 },
    .{ .x = 6, .y = 0 },
    .{ .x = 1, .y = 6 },
    .{ .x = -1, .y = 6 },
    .{ .x = 6, .y = 1 },
    .{ .x = -6, .y = 1 },
    .{ .x = 2, .y = 6 },
    .{ .x = -2, .y = 6 },
    .{ .x = 6, .y = 2 },
    .{ .x = -6, .y = 2 },
    .{ .x = 4, .y = 5 },
    .{ .x = -4, .y = 5 },
    .{ .x = 5, .y = 4 },
    .{ .x = -5, .y = 4 },
    .{ .x = 3, .y = 6 },
    .{ .x = -3, .y = 6 },
    .{ .x = 6, .y = 3 },
    .{ .x = -6, .y = 3 },
    .{ .x = 0, .y = 7 },
    .{ .x = 7, .y = 0 },
    .{ .x = 1, .y = 7 },
    .{ .x = -1, .y = 7 },
    .{ .x = 5, .y = 5 },
    .{ .x = -5, .y = 5 },
    .{ .x = 7, .y = 1 },
    .{ .x = -7, .y = 1 },
    .{ .x = 4, .y = 6 },
    .{ .x = -4, .y = 6 },
    .{ .x = 6, .y = 4 },
    .{ .x = -6, .y = 4 },
    .{ .x = 2, .y = 7 },
    .{ .x = -2, .y = 7 },
    .{ .x = 7, .y = 2 },
    .{ .x = -7, .y = 2 },
    .{ .x = 3, .y = 7 },
    .{ .x = -3, .y = 7 },
    .{ .x = 7, .y = 3 },
    .{ .x = -7, .y = 3 },
    .{ .x = 5, .y = 6 },
    .{ .x = -5, .y = 6 },
    .{ .x = 6, .y = 5 },
    .{ .x = -6, .y = 5 },
    .{ .x = 8, .y = 0 },
    .{ .x = 4, .y = 7 },
    .{ .x = -4, .y = 7 },
    .{ .x = 7, .y = 4 },
    .{ .x = -7, .y = 4 },
    .{ .x = 8, .y = 1 },
    .{ .x = 8, .y = 2 },
    .{ .x = 6, .y = 6 },
    .{ .x = -6, .y = 6 },
    .{ .x = 8, .y = 3 },
    .{ .x = 5, .y = 7 },
    .{ .x = -5, .y = 7 },
    .{ .x = 7, .y = 5 },
    .{ .x = -7, .y = 5 },
    .{ .x = 8, .y = 4 },
    .{ .x = 6, .y = 7 },
    .{ .x = -6, .y = 7 },
    .{ .x = 7, .y = 6 },
    .{ .x = -7, .y = 6 },
    .{ .x = 8, .y = 5 },
    .{ .x = 7, .y = 7 },
    .{ .x = -7, .y = 7 },
    .{ .x = 8, .y = 6 },
    .{ .x = 8, .y = 7 },
};

comptime {
    assert(distance_map.len == 120);
}

test "VP8L image data parses a single ARGB prefix-code group" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeNormalTwoSymbolPrefixCode(&writer);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    const parsed = try readSingleGroup(
        &reader,
        try image.Dimensions.init(5, 3),
        .argb,
        &buffers,
    );

    try std.testing.expectEqual(Role.argb, parsed.role);
    try std.testing.expectEqual(@as(?ColorCache, null), parsed.color_cache);
    switch (parsed.meta_prefix) {
        .single => {},
        .none => return error.InvalidVP8LImageData,
    }

    var green_bits: [1]u8 = undefined;
    var green_writer = bit_writer.BitWriter.init(&green_bits);
    try green_writer.writeBits(0, 1);
    try green_writer.writeBits(1, 1);

    var green_reader = bit_reader.BitReader.init(try green_writer.finish());
    try std.testing.expectEqual(
        @as(u16, 0),
        try parsed.prefix_codes.table(.green).decode(&green_reader),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        try parsed.prefix_codes.table(.green).decode(&green_reader),
    );
}

test "VP8L image data scans a bounded literal-only stream" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeLiteralOnlyPrefixCodeGroup(&writer);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    const summary = try scanSingleGroup(
        &reader,
        try image.Dimensions.init(3, 2),
        .argb,
        &buffers,
    );

    try std.testing.expectEqual(@as(u64, 6), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 6), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 0), summary.copy_count);
    try std.testing.expectEqual(@as(u64, 0), summary.color_cache_count);
}

test "VP8L image data allows limited code-length repeat expansion" {
    var encoded: [64]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeNormalSingleLengthSymbol256PrefixCode(&writer);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    const parsed = try readSingleGroup(
        &reader,
        try image.Dimensions.init(3, 1),
        .argb,
        &buffers,
    );

    var symbol_reader = bit_reader.BitReader.init(&.{});
    try std.testing.expectEqual(
        @as(u16, 256),
        try parsed.prefix_codes.green.decode(&symbol_reader),
    );
}

test "VP8L image data rejects copy distances before the decoded prefix" {
    var encoded: [64]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeNormalSingleLengthSymbol256PrefixCode(&writer);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    try std.testing.expectError(
        error.InvalidVP8LImageData,
        scanSingleGroup(
            &reader,
            try image.Dimensions.init(3, 1),
            .argb,
            &buffers,
        ),
    );
}

test "VP8L image data parses color cache metadata" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(1);
    try writer.writeBits(4, 4);
    try writer.writeBit(0);
    try writeSimplePrefixCodeGroup(&writer);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    const parsed = try readSingleGroup(
        &reader,
        try image.Dimensions.init(1, 1),
        .argb,
        &buffers,
    );

    try std.testing.expectEqual(@as(u4, 4), parsed.color_cache.?.bits);
    try std.testing.expectEqual(@as(u16, 16), parsed.color_cache.?.size);
}

test "VP8L image data transform role omits the meta-prefix bit" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writeSimplePrefixCodeGroup(&writer);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    const parsed = try readSingleGroup(
        &reader,
        try image.Dimensions.init(2, 2),
        .transform,
        &buffers,
    );

    switch (parsed.meta_prefix) {
        .none => {},
        .single => return error.InvalidVP8LImageData,
    }
}

test "VP8L image data rejects invalid color cache sizes" {
    var zero_bits: [1]u8 = undefined;
    var zero_writer = bit_writer.BitWriter.init(&zero_bits);
    try zero_writer.writeBit(1);
    try zero_writer.writeBits(0, 4);

    var zero_reader = bit_reader.BitReader.init(try zero_writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    try std.testing.expectError(
        error.InvalidVP8LImageData,
        readSingleGroup(
            &zero_reader,
            try image.Dimensions.init(1, 1),
            .argb,
            &buffers,
        ),
    );

    var oversized_bits: [1]u8 = undefined;
    var oversized_writer = bit_writer.BitWriter.init(&oversized_bits);
    try oversized_writer.writeBit(1);
    try oversized_writer.writeBits(12, 4);

    var oversized_reader = bit_reader.BitReader.init(try oversized_writer.finish());
    try std.testing.expectError(
        error.InvalidVP8LImageData,
        readSingleGroup(
            &oversized_reader,
            try image.Dimensions.init(1, 1),
            .argb,
            &buffers,
        ),
    );
}

test "VP8L image data reports unsupported meta-prefix images explicitly" {
    var encoded: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(1);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    try std.testing.expectError(
        error.UnsupportedVP8LImageData,
        readSingleGroup(
            &reader,
            try image.Dimensions.init(1, 1),
            .argb,
            &buffers,
        ),
    );
}

test "VP8L image data rejects symbols outside a channel alphabet" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 255);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: PrefixCodeGroupBuffers = .{};
    try std.testing.expectError(
        error.InvalidVP8LImageData,
        readSingleGroup(
            &reader,
            try image.Dimensions.init(1, 1),
            .argb,
            &buffers,
        ),
    );
}
