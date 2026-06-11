//! VP8L entropy-coded image materialization.

const std = @import("std");
const assert = std.debug.assert;

const bit_reader = @import("../bit_reader.zig");
const errors = @import("../errors.zig");
const huffman = @import("huffman.zig");
const image = @import("../image.zig");
const image_data = @import("image_data.zig");
const bit_writer = @import("../bit_writer.zig");
const color_cache = @import("color_cache.zig");
const meta_prefix = @import("meta_prefix.zig");
const pixel = @import("pixel.zig");
const prefix_groups = @import("prefix_groups.zig");

pub const DecodeSummary = struct {
    pixel_count: u64,
    literal_count: u64,
    copy_count: u64,
    color_cache_count: u64,
};

pub fn decodeSingleGroup(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    role: image_data.Role,
    output: []pixel.Pixel,
    buffers: *image_data.PrefixCodeGroupBuffers,
) errors.Error!DecodeSummary {
    const data = try image_data.readSingleGroup(reader, dimensions, role, buffers);

    return decodeWithPrefixCodes(
        reader,
        data.dimensions,
        data.color_cache,
        data.prefix_codes,
        output,
    );
}

pub fn decodeWithPrefixCodes(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    color_cache_info: ?image_data.ColorCache,
    prefix_codes: image_data.PrefixCodeGroup,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    const pixel_count = try dimensions.pixelCount();
    if (pixel_count > output.len) return error.OutputTooLarge;

    const output_pixels = output[0..@intCast(pixel_count)];
    var cache_storage: color_cache.Cache = undefined;
    const cache = if (color_cache_info) |info| cache: {
        try cache_storage.init(info.bits);
        if (cache_storage.size != info.size) return error.InvalidVP8LImageData;
        break :cache &cache_storage;
    } else null;

    return decodeImage(reader, dimensions, cache, prefix_codes, output_pixels);
}

pub fn decodeWithGroupStore(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    color_cache_info: ?image_data.ColorCache,
    group_store: prefix_groups.Store,
    meta_prefix_info: meta_prefix.Info,
    entropy_image: []const pixel.Pixel,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    if (meta_prefix_info.image_dimensions.width != dimensions.width) {
        return error.InvalidVP8LImageData;
    }
    if (meta_prefix_info.image_dimensions.height != dimensions.height) {
        return error.InvalidVP8LImageData;
    }
    if (meta_prefix_info.group_count == 0) return error.InvalidVP8LImageData;
    if (meta_prefix_info.group_count > meta_prefix.group_count_max) {
        return error.InvalidVP8LImageData;
    }
    if (meta_prefix_info.group_count > group_store.initialized_count) {
        return error.InvalidVP8LImageData;
    }

    const pixel_count = try dimensions.pixelCount();
    if (pixel_count > output.len) return error.OutputTooLarge;

    const output_pixels = output[0..@intCast(pixel_count)];
    var cache_storage: color_cache.Cache = undefined;
    const cache = if (color_cache_info) |info| cache: {
        try cache_storage.init(info.bits);
        if (cache_storage.size != info.size) return error.InvalidVP8LImageData;
        break :cache &cache_storage;
    } else null;

    return decodeImageWithSelector(
        reader,
        dimensions,
        cache,
        .{
            .spatial = .{
                .store = group_store,
                .meta_prefix_info = meta_prefix_info,
                .entropy_image = entropy_image,
            },
        },
        output_pixels,
    );
}

fn decodeImage(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    cache: ?*color_cache.Cache,
    prefix_codes: image_data.PrefixCodeGroup,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    return decodeImageWithSelector(
        reader,
        dimensions,
        cache,
        .{ .single = prefix_codes },
        output,
    );
}

const PrefixCodeSelector = union(enum) {
    single: image_data.PrefixCodeGroup,
    spatial: SpatialPrefixCodeSelector,

    fn group(
        self: PrefixCodeSelector,
        dimensions: image.Dimensions,
        output_index: usize,
    ) errors.Error!image_data.PrefixCodeGroup {
        assert(output_index < try dimensions.pixelCount());

        return switch (self) {
            .single => |prefix_codes| prefix_codes,
            .spatial => |spatial| {
                const width: usize = @intCast(dimensions.width);
                const x: u32 = @intCast(output_index % width);
                const y: u32 = @intCast(output_index / width);

                return spatial.store.groupForPixel(
                    spatial.meta_prefix_info,
                    spatial.entropy_image,
                    x,
                    y,
                );
            },
        };
    }
};

const SpatialPrefixCodeSelector = struct {
    store: prefix_groups.Store,
    meta_prefix_info: meta_prefix.Info,
    entropy_image: []const pixel.Pixel,
};

fn decodeImageWithSelector(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    cache: ?*color_cache.Cache,
    selector: PrefixCodeSelector,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    assert(output.len == try dimensions.pixelCount());

    var summary = DecodeSummary{
        .pixel_count = 0,
        .literal_count = 0,
        .copy_count = 0,
        .color_cache_count = 0,
    };

    var output_index: usize = 0;
    while (output_index < output.len) {
        const prefix_codes = try selector.group(dimensions, output_index);
        const green_symbol = try prefix_codes.green.decode(reader);
        if (green_symbol < huffman.literal_alphabet_size) {
            const value = try readLiteral(reader, prefix_codes, green_symbol);
            output[output_index] = value;
            if (cache) |color_cache_pointer| color_cache_pointer.insert(value);

            output_index += 1;
            summary.literal_count += 1;
        } else if (green_symbol < huffman.literal_alphabet_size + huffman.length_code_count) {
            output_index = try copyBackwardReference(
                reader,
                dimensions,
                prefix_codes,
                cache,
                output,
                output_index,
                green_symbol,
            );
            summary.copy_count += 1;
        } else {
            const value = try readColorCachePixel(green_symbol, cache);
            output[output_index] = value;

            output_index += 1;
            summary.color_cache_count += 1;
        }
    }

    summary.pixel_count = output_index;
    assert(summary.pixel_count == output.len);

    return summary;
}

fn readLiteral(
    reader: *bit_reader.BitReader,
    prefix_codes: image_data.PrefixCodeGroup,
    green_symbol: u16,
) errors.Error!pixel.Pixel {
    assert(green_symbol < huffman.literal_alphabet_size);

    const green: u8 = @intCast(green_symbol);
    const red = try readChannel(reader, prefix_codes.red);
    const blue = try readChannel(reader, prefix_codes.blue);
    const alpha = try readChannel(reader, prefix_codes.alpha);

    return pixel.fromChannels(alpha, red, green, blue);
}

fn readChannel(
    reader: *bit_reader.BitReader,
    table: huffman.SymbolTable,
) errors.Error!u8 {
    const symbol = try table.decode(reader);
    if (symbol >= huffman.literal_alphabet_size) return error.InvalidVP8LImageData;

    return @intCast(symbol);
}

fn copyBackwardReference(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    prefix_codes: image_data.PrefixCodeGroup,
    cache: ?*color_cache.Cache,
    output: []pixel.Pixel,
    output_index_start: usize,
    green_symbol: u16,
) errors.Error!usize {
    assert(green_symbol >= huffman.literal_alphabet_size);
    assert(green_symbol < huffman.literal_alphabet_size + huffman.length_code_count);
    assert(output_index_start < output.len);

    const length_prefix: u8 = @intCast(green_symbol - huffman.literal_alphabet_size);
    const length = try image_data.readPrefixValue(reader, length_prefix);
    if (length > output.len - output_index_start) return error.InvalidVP8LImageData;

    const distance_prefix_symbol = try prefix_codes.distance.decode(reader);
    if (distance_prefix_symbol >= huffman.distance_alphabet_size) {
        return error.InvalidVP8LImageData;
    }

    const distance_prefix: u8 = @intCast(distance_prefix_symbol);
    const distance_code = try image_data.readPrefixValue(reader, distance_prefix);
    const distance = image_data.distanceFromCode(distance_code, dimensions.width);
    if (distance > output_index_start) return error.InvalidVP8LImageData;

    const distance_pixels: usize = @intCast(distance);
    assert(distance_pixels > 0);
    assert(distance_pixels <= output_index_start);

    var output_index = output_index_start;
    var copied_count: u32 = 0;
    while (copied_count < length) : (copied_count += 1) {
        const value = output[output_index - distance_pixels];
        output[output_index] = value;
        if (cache) |color_cache_pointer| color_cache_pointer.insert(value);
        output_index += 1;
    }

    return output_index;
}

fn readColorCachePixel(
    green_symbol: u16,
    cache: ?*color_cache.Cache,
) errors.Error!pixel.Pixel {
    const color_cache_pointer = cache orelse return error.InvalidVP8LImageData;
    const cache_index: u16 = green_symbol -
        huffman.literal_alphabet_size -
        huffman.length_code_count;

    return color_cache_pointer.lookup(cache_index);
}

fn writeSimplePrefixCode(writer: *bit_writer.BitWriter, symbol: u8) errors.Error!void {
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(if (symbol <= 1) 0 else 1);
    try writer.writeBits(symbol, if (symbol <= 1) 1 else 8);
}

fn writeLiteralOnlyPrefixCodeGroup(writer: *bit_writer.BitWriter) errors.Error!void {
    var code_index: usize = 0;
    while (code_index < image_data.prefix_code_count) : (code_index += 1) {
        try writeSimplePrefixCode(writer, @intFromBool(code_index == 0));
    }
}

fn writeConstantPrefixCodeGroup(
    writer: *bit_writer.BitWriter,
    green_symbol: u8,
) errors.Error!void {
    try writeSimplePrefixCode(writer, green_symbol);
    try writeSimplePrefixCode(writer, 0);
    try writeSimplePrefixCode(writer, 0);
    try writeSimplePrefixCode(writer, 0);
    try writeSimplePrefixCode(writer, 0);
}

fn singleSymbolTable(
    entries: []huffman.Entry,
    symbol: u16,
    alphabet_size: u16,
) errors.Error!huffman.SymbolTable {
    assert(symbol < alphabet_size);

    var code_lengths: [huffman.green_alphabet_size_max]u8 =
        .{0} ** huffman.green_alphabet_size_max;
    code_lengths[symbol] = 1;

    return huffman.SymbolTable.build(entries, code_lengths[0..alphabet_size]);
}

fn twoSymbolTable(
    entries: []huffman.Entry,
    symbol0: u16,
    symbol1: u16,
    alphabet_size: u16,
) errors.Error!huffman.SymbolTable {
    assert(symbol0 < symbol1);
    assert(symbol1 < alphabet_size);

    var code_lengths: [huffman.green_alphabet_size_max]u8 =
        .{0} ** huffman.green_alphabet_size_max;
    code_lengths[symbol0] = 1;
    code_lengths[symbol1] = 1;

    return huffman.SymbolTable.build(entries, code_lengths[0..alphabet_size]);
}

test "VP8L entropy materializes a single-prefix-group literal stream" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeLiteralOnlyPrefixCodeGroup(&writer);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    var output: [2]pixel.Pixel = undefined;
    const summary = try decodeSingleGroup(
        &reader,
        try image.Dimensions.init(2, 1),
        .argb,
        &output,
        &buffers,
    );

    try std.testing.expectEqual(@as(u64, 2), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 2), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 0), summary.copy_count);
    try std.testing.expectEqual(@as(u64, 0), summary.color_cache_count);
    try std.testing.expectEqual(pixel.fromChannels(0, 0, 1, 0), output[0]);
    try std.testing.expectEqual(pixel.fromChannels(0, 0, 1, 0), output[1]);
}

test "VP8L entropy expands overlapping backward references" {
    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    const prefix_codes = image_data.PrefixCodeGroup{
        .green = try twoSymbolTable(
            &buffers.green_entries,
            7,
            huffman.literal_alphabet_size,
            huffman.literal_alphabet_size + huffman.length_code_count,
        ),
        .red = try singleSymbolTable(&buffers.red_entries, 2, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers.blue_entries, 3, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers.alpha_entries, 4, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers.distance_entries,
            1,
            huffman.distance_alphabet_size,
        ),
    };

    var encoded: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(1);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var output: [2]pixel.Pixel = undefined;
    const summary = try decodeWithPrefixCodes(
        &reader,
        try image.Dimensions.init(2, 1),
        null,
        prefix_codes,
        &output,
    );

    const expected = pixel.fromChannels(4, 2, 7, 3);
    try std.testing.expectEqual(@as(u64, 2), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 1), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 1), summary.copy_count);
    try std.testing.expectEqual(expected, output[0]);
    try std.testing.expectEqual(expected, output[1]);
}

test "VP8L entropy resolves color-cache references" {
    const cached_pixel = pixel.fromChannels(4, 2, 5, 3);
    const cache_bits: u4 = 1;
    const cache_size: u16 = @as(u16, 1) << cache_bits;
    const cache_index = color_cache.hash(cache_bits, cached_pixel);
    const cache_symbol = huffman.literal_alphabet_size +
        huffman.length_code_count +
        cache_index;

    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    const prefix_codes = image_data.PrefixCodeGroup{
        .green = try twoSymbolTable(
            &buffers.green_entries,
            5,
            cache_symbol,
            huffman.literal_alphabet_size + huffman.length_code_count + cache_size,
        ),
        .red = try singleSymbolTable(&buffers.red_entries, 2, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers.blue_entries, 3, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers.alpha_entries, 4, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers.distance_entries,
            0,
            huffman.distance_alphabet_size,
        ),
    };

    var encoded: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0);
    try writer.writeBit(1);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var output: [2]pixel.Pixel = undefined;
    const summary = try decodeWithPrefixCodes(
        &reader,
        try image.Dimensions.init(2, 1),
        .{ .bits = cache_bits, .size = cache_size },
        prefix_codes,
        &output,
    );

    try std.testing.expectEqual(@as(u64, 2), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 1), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 0), summary.copy_count);
    try std.testing.expectEqual(@as(u64, 1), summary.color_cache_count);
    try std.testing.expectEqual(cached_pixel, output[0]);
    try std.testing.expectEqual(cached_pixel, output[1]);
}

test "VP8L entropy selects prefix groups from meta-prefix blocks" {
    var group_bytes: [32]u8 = undefined;
    var group_writer = bit_writer.BitWriter.init(&group_bytes);
    try writeConstantPrefixCodeGroup(&group_writer, 0);
    try writeConstantPrefixCodeGroup(&group_writer, 1);

    var group_reader = bit_reader.BitReader.init(try group_writer.finish());
    const buffers = try std.testing.allocator.create(prefix_groups.WorkBuffers);
    defer std.testing.allocator.destroy(buffers);
    buffers.* = .{};

    var store = try prefix_groups.Store.readAll(
        std.testing.allocator,
        &group_reader,
        2,
        0,
        .{},
        buffers,
    );
    defer store.deinit();

    const info = meta_prefix.Info{
        .prefix_bits = 2,
        .block_size = 4,
        .image_dimensions = try image.Dimensions.init(8, 1),
        .entropy_dimensions = try image.Dimensions.init(2, 1),
        .group_count = 2,
    };
    const entropy_image = [_]pixel.Pixel{
        pixel.fromChannels(0, 0, 0, 0),
        pixel.fromChannels(0, 0, 1, 0),
    };

    var image_reader = bit_reader.BitReader.init(&.{});
    var output: [8]pixel.Pixel = undefined;
    const summary = try decodeWithGroupStore(
        &image_reader,
        try image.Dimensions.init(8, 1),
        null,
        store,
        info,
        &entropy_image,
        &output,
    );

    try std.testing.expectEqual(@as(u64, 8), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 8), summary.literal_count);
    for (output[0..4]) |value| {
        try std.testing.expectEqual(pixel.fromChannels(0, 0, 0, 0), value);
    }
    for (output[4..8]) |value| {
        try std.testing.expectEqual(pixel.fromChannels(0, 0, 1, 0), value);
    }
}

test "VP8L entropy rejects meta-prefix groups that were not read" {
    var group_bytes: [16]u8 = undefined;
    var group_writer = bit_writer.BitWriter.init(&group_bytes);
    try writeConstantPrefixCodeGroup(&group_writer, 0);

    var group_reader = bit_reader.BitReader.init(try group_writer.finish());
    const buffers = try std.testing.allocator.create(prefix_groups.WorkBuffers);
    defer std.testing.allocator.destroy(buffers);
    buffers.* = .{};

    var store = try prefix_groups.Store.readAll(
        std.testing.allocator,
        &group_reader,
        1,
        0,
        .{},
        buffers,
    );
    defer store.deinit();

    const info = meta_prefix.Info{
        .prefix_bits = 2,
        .block_size = 4,
        .image_dimensions = try image.Dimensions.init(4, 1),
        .entropy_dimensions = try image.Dimensions.init(1, 1),
        .group_count = 2,
    };
    const entropy_image = [_]pixel.Pixel{
        pixel.fromChannels(0, 0, 1, 0),
    };

    var image_reader = bit_reader.BitReader.init(&.{});
    var output: [4]pixel.Pixel = undefined;
    try std.testing.expectError(
        error.InvalidVP8LImageData,
        decodeWithGroupStore(
            &image_reader,
            try image.Dimensions.init(4, 1),
            null,
            store,
            info,
            &entropy_image,
            &output,
        ),
    );
}
