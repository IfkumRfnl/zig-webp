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
    return decodeSingleGroupInternal(true, reader, dimensions, role, output, buffers);
}

pub fn decodeSingleGroupDiscardSummary(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    role: image_data.Role,
    output: []pixel.Pixel,
    buffers: *image_data.PrefixCodeGroupBuffers,
) errors.Error!DecodeSummary {
    return decodeSingleGroupInternal(false, reader, dimensions, role, output, buffers);
}

fn decodeSingleGroupInternal(
    comptime collect_summary: bool,
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    role: image_data.Role,
    output: []pixel.Pixel,
    buffers: *image_data.PrefixCodeGroupBuffers,
) errors.Error!DecodeSummary {
    const data = try image_data.readSingleGroup(reader, dimensions, role, buffers);
    return decodeWithPrefixCodesInternal(
        collect_summary,
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
    return decodeWithPrefixCodesInternal(
        true,
        reader,
        dimensions,
        color_cache_info,
        prefix_codes,
        output,
    );
}

pub fn decodeWithPrefixCodesDiscardSummary(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    color_cache_info: ?image_data.ColorCache,
    prefix_codes: image_data.PrefixCodeGroup,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    return decodeWithPrefixCodesInternal(
        false,
        reader,
        dimensions,
        color_cache_info,
        prefix_codes,
        output,
    );
}

fn decodeWithPrefixCodesInternal(
    comptime collect_summary: bool,
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

    return decodeImage(
        collect_summary,
        reader,
        dimensions,
        cache,
        prefix_codes,
        output_pixels,
    );
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
    return decodeWithGroupStoreInternal(
        true,
        reader,
        dimensions,
        color_cache_info,
        group_store,
        meta_prefix_info,
        entropy_image,
        output,
    );
}

pub fn decodeWithGroupStoreDiscardSummary(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    color_cache_info: ?image_data.ColorCache,
    group_store: prefix_groups.Store,
    meta_prefix_info: meta_prefix.Info,
    entropy_image: []const pixel.Pixel,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    return decodeWithGroupStoreInternal(
        false,
        reader,
        dimensions,
        color_cache_info,
        group_store,
        meta_prefix_info,
        entropy_image,
        output,
    );
}

fn decodeWithGroupStoreInternal(
    comptime collect_summary: bool,
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
        collect_summary,
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
    comptime collect_summary: bool,
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    cache: ?*color_cache.Cache,
    prefix_codes: image_data.PrefixCodeGroup,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    if (constantLiteral(prefix_codes)) |value| {
        @memset(output, value);
        const pixel_count: u64 = @intCast(output.len);
        return .{
            .pixel_count = pixel_count,
            .literal_count = pixel_count,
            .copy_count = 0,
            .color_cache_count = 0,
        };
    }

    if (prefix_codes.green.single_symbol) |green_symbol| {
        if (green_symbol < huffman.literal_alphabet_size) {
            for (output) |*value| {
                value.* = try readLiteral(reader, &prefix_codes, green_symbol);
            }
            const pixel_count: u64 = @intCast(output.len);
            return .{
                .pixel_count = pixel_count,
                .literal_count = pixel_count,
                .copy_count = 0,
                .color_cache_count = 0,
            };
        }
    }

    if (cache == null) {
        if (prefix_codes.red.single_symbol != null) {
            if (prefix_codes.blue.single_symbol != null) {
                if (prefix_codes.alpha.single_symbol != null) {
                    return decodeLoop(
                        collect_summary,
                        false,
                        false,
                        true,
                        reader,
                        dimensions,
                        {},
                        prefix_codes,
                        undefined,
                        output,
                    );
                }
            }
        }
    }

    return decodeImageWithSelector(
        collect_summary,
        reader,
        dimensions,
        cache,
        .{ .single = prefix_codes },
        output,
    );
}

fn constantLiteral(prefix_codes: image_data.PrefixCodeGroup) ?pixel.Pixel {
    const green_symbol = prefix_codes.green.single_symbol orelse return null;
    const red_symbol = prefix_codes.red.single_symbol orelse return null;
    const blue_symbol = prefix_codes.blue.single_symbol orelse return null;
    const alpha_symbol = prefix_codes.alpha.single_symbol orelse return null;
    if (green_symbol >= huffman.literal_alphabet_size) return null;

    return pixel.fromChannels(
        @intCast(alpha_symbol),
        @intCast(red_symbol),
        @intCast(green_symbol),
        @intCast(blue_symbol),
    );
}

inline fn constantChannelLiteral(
    prefix_codes: *const image_data.PrefixCodeGroup,
    green_symbol: u16,
) pixel.Pixel {
    assert(green_symbol < huffman.literal_alphabet_size);
    const red_symbol = prefix_codes.red.single_symbol.?;
    const blue_symbol = prefix_codes.blue.single_symbol.?;
    const alpha_symbol = prefix_codes.alpha.single_symbol.?;
    return pixel.fromChannels(
        @intCast(alpha_symbol),
        @intCast(red_symbol),
        @intCast(green_symbol),
        @intCast(blue_symbol),
    );
}

const PrefixCodeSelector = union(enum) {
    single: image_data.PrefixCodeGroup,
    spatial: SpatialPrefixCodeSelector,
};

const SpatialPrefixCodeSelector = struct {
    store: prefix_groups.Store,
    meta_prefix_info: meta_prefix.Info,
    entropy_image: []const pixel.Pixel,
};

fn decodeImageWithSelector(
    comptime collect_summary: bool,
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    cache: ?*color_cache.Cache,
    selector: PrefixCodeSelector,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    assert(output.len == try dimensions.pixelCount());

    return switch (selector) {
        .single => |prefix_codes| if (cache) |color_cache_pointer|
            decodeLoop(collect_summary, true, false, false, reader, dimensions, color_cache_pointer, prefix_codes, undefined, output)
        else
            decodeLoop(collect_summary, false, false, false, reader, dimensions, {}, prefix_codes, undefined, output),
        .spatial => |spatial| if (cache) |color_cache_pointer|
            decodeLoop(collect_summary, true, true, false, reader, dimensions, color_cache_pointer, undefined, spatial, output)
        else
            decodeLoop(collect_summary, false, true, false, reader, dimensions, {}, undefined, spatial, output),
    };
}

fn decodeLoop(
    comptime collect_summary: bool,
    comptime has_cache: bool,
    comptime spatial: bool,
    comptime constant_channels: bool,
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    cache: if (has_cache) *color_cache.Cache else void,
    single_codes: if (spatial) void else image_data.PrefixCodeGroup,
    spatial_selector: if (spatial) SpatialPrefixCodeSelector else void,
    output: []pixel.Pixel,
) errors.Error!DecodeSummary {
    assert(output.len == try dimensions.pixelCount());
    if (spatial) assert(!constant_channels);

    var summary = DecodeSummary{
        .pixel_count = 0,
        .literal_count = 0,
        .copy_count = 0,
        .color_cache_count = 0,
    };

    const width: u32 = dimensions.width;
    var prefix_codes: *const image_data.PrefixCodeGroup =
        if (spatial) undefined else &single_codes;
    var run_remaining: u32 = 0;

    var output_index: usize = 0;
    while (output_index < output.len) {
        if (spatial and run_remaining == 0) {
            const x: u32 = @intCast(output_index % @as(usize, width));
            const y: u32 = @intCast(output_index / @as(usize, width));
            prefix_codes = try spatial_selector.store.groupForPixelPtr(
                spatial_selector.meta_prefix_info,
                spatial_selector.entropy_image,
                x,
                y,
            );
            const block_size = spatial_selector.meta_prefix_info.block_size;
            const into_tile = x & (block_size - 1);
            run_remaining = @min(block_size - into_tile, width - x);
            assert(run_remaining > 0);
        }

        reader.fill();
        const green_symbol = try prefix_codes.green.decodeBuffered(reader);
        if (green_symbol < huffman.literal_alphabet_size) {
            const value = if (constant_channels)
                constantChannelLiteral(prefix_codes, green_symbol)
            else
                try readLiteral(reader, prefix_codes, green_symbol);
            output[output_index] = value;
            if (has_cache) cache.insert(value);

            output_index += 1;
            if (spatial) run_remaining -= 1;
            if (collect_summary) summary.literal_count += 1;
        } else if (green_symbol < huffman.literal_alphabet_size + huffman.length_code_count) {
            output_index = try copyBackwardReference(
                has_cache,
                reader,
                dimensions,
                prefix_codes,
                cache,
                output,
                output_index,
                green_symbol,
            );
            if (spatial) run_remaining = 0;
            if (collect_summary) summary.copy_count += 1;
        } else {
            if (!has_cache) return error.InvalidVP8LImageData;
            const value = try readColorCachePixel(green_symbol, cache);
            output[output_index] = value;

            output_index += 1;
            if (spatial) run_remaining -= 1;
            if (collect_summary) summary.color_cache_count += 1;

            // Color-cache symbols do not mutate the cache. Consume a run while
            // the green code remains a root-table hit and, for spatial
            // streams, stays inside the current prefix-code tile.
            while (output_index < output.len and (!spatial or run_remaining > 0)) {
                const peeked = prefix_codes.green.peekBuffered(reader) orelse break;
                if (peeked.symbol <
                    huffman.literal_alphabet_size + huffman.length_code_count)
                {
                    break;
                }

                const cached = try readColorCachePixel(peeked.symbol, cache);
                if (peeked.bit_count > 0) reader.dropBitsBuffered(peeked.bit_count);
                output[output_index] = cached;
                output_index += 1;
                if (spatial) run_remaining -= 1;
                if (collect_summary) summary.color_cache_count += 1;
            }
        }
    }

    summary.pixel_count = output_index;
    assert(summary.pixel_count == output.len);

    return summary;
}

inline fn readLiteral(
    reader: *bit_reader.BitReader,
    prefix_codes: *const image_data.PrefixCodeGroup,
    green_symbol: u16,
) errors.Error!pixel.Pixel {
    assert(green_symbol < huffman.literal_alphabet_size);

    const green: u8 = @intCast(green_symbol);
    const channel_bits_max: u6 = 3 * huffman.max_code_bits;
    if (reader.bufferedBits() < channel_bits_max and
        reader.remainingBits() >= channel_bits_max)
    {
        reader.fill();
    }
    if (reader.bufferedBits() >= channel_bits_max) {
        const red = try readChannelPrefilled(reader, &prefix_codes.red);
        const blue = try readChannelPrefilled(reader, &prefix_codes.blue);
        const alpha = try readChannelPrefilled(reader, &prefix_codes.alpha);
        return pixel.fromChannels(alpha, red, green, blue);
    }
    const red = try readChannel(reader, &prefix_codes.red);
    const blue = try readChannel(reader, &prefix_codes.blue);
    const alpha = try readChannel(reader, &prefix_codes.alpha);
    return pixel.fromChannels(alpha, red, green, blue);
}

inline fn readChannel(
    reader: *bit_reader.BitReader,
    table: *const huffman.SymbolTable,
) errors.Error!u8 {
    const symbol = try table.decodeBuffered(reader);
    if (symbol >= huffman.literal_alphabet_size) return error.InvalidVP8LImageData;

    return @intCast(symbol);
}
inline fn readChannelPrefilled(
    reader: *bit_reader.BitReader,
    table: *const huffman.SymbolTable,
) errors.Error!u8 {
    const symbol = try table.decodePrefilled(reader);
    if (symbol >= huffman.literal_alphabet_size) return error.InvalidVP8LImageData;

    return @intCast(symbol);
}

inline fn readPrefixValueBuffered(
    reader: *bit_reader.BitReader,
    prefix_code: u8,
) errors.Error!u32 {
    if (prefix_code >= huffman.distance_alphabet_size) {
        return error.InvalidVP8LImageData;
    }
    if (prefix_code < 4) return @as(u32, prefix_code) + 1;

    const extra_bits: u5 = @intCast((prefix_code - 2) >> 1);
    const offset = @as(u32, 2 + (prefix_code & 1)) << extra_bits;
    return offset + try reader.readBitsBuffered(extra_bits) + 1;
}

fn copyBackwardReference(
    comptime has_cache: bool,
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    prefix_codes: *const image_data.PrefixCodeGroup,
    cache: if (has_cache) *color_cache.Cache else void,
    output: []pixel.Pixel,
    output_index_start: usize,
    green_symbol: u16,
) errors.Error!usize {
    assert(green_symbol >= huffman.literal_alphabet_size);
    assert(green_symbol < huffman.literal_alphabet_size + huffman.length_code_count);
    assert(output_index_start < output.len);

    const length_prefix: u8 = @intCast(green_symbol - huffman.literal_alphabet_size);
    const length = try readPrefixValueBuffered(reader, length_prefix);
    if (length > output.len - output_index_start) return error.InvalidVP8LImageData;

    const distance_prefix_symbol = try prefix_codes.distance.decodeBuffered(reader);
    if (distance_prefix_symbol >= huffman.distance_alphabet_size) {
        return error.InvalidVP8LImageData;
    }

    const distance_prefix: u8 = @intCast(distance_prefix_symbol);
    const distance_code = try readPrefixValueBuffered(reader, distance_prefix);
    const distance = image_data.distanceFromCode(distance_code, dimensions.width);
    if (distance > output_index_start) return error.InvalidVP8LImageData;

    const distance_pixels: usize = @intCast(distance);
    const length_pixels: usize = @intCast(length);
    assert(distance_pixels > 0);
    assert(distance_pixels <= output_index_start);
    assert(length_pixels > 0);
    assert(output_index_start + length_pixels <= output.len);

    if (distance_pixels == 1) {
        const value = output[output_index_start - 1];
        const dst = output[output_index_start..][0..length_pixels];
        @memset(dst, value);
        if (has_cache) cache.insert(value);
        return output_index_start + length_pixels;
    }

    if (has_cache) {
        var output_index = output_index_start;
        var copied_count: usize = 0;
        while (copied_count < length_pixels) : (copied_count += 1) {
            const value = output[output_index - distance_pixels];
            output[output_index] = value;
            cache.insert(value);
            output_index += 1;
        }
        return output_index;
    }

    const dst = output[output_index_start..][0..length_pixels];
    if (distance_pixels >= length_pixels) {
        const src = output[output_index_start - distance_pixels ..][0..length_pixels];
        // Validated distance/length guarantee the ranges are disjoint (adjacent at most).
        assert(output_index_start - distance_pixels + length_pixels <= output_index_start);
        @memcpy(dst, src);
    } else {
        var remaining = length_pixels;
        var output_index = output_index_start;
        while (remaining > 0) {
            const chunk = @min(distance_pixels, remaining);
            const src = output[output_index - distance_pixels ..][0..chunk];
            const chunk_dst = output[output_index..][0..chunk];
            // Each chunk length is <= distance, so source ends at or before dest start.
            assert(output_index - distance_pixels + chunk <= output_index);
            @memcpy(chunk_dst, src);
            output_index += chunk;
            remaining -= chunk;
        }
    }

    return output_index_start + length_pixels;
}

fn readColorCachePixel(
    green_symbol: u16,
    cache: *color_cache.Cache,
) errors.Error!pixel.Pixel {
    const cache_index: u16 = green_symbol -
        huffman.literal_alphabet_size -
        huffman.length_code_count;

    return cache.lookup(cache_index);
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

fn threeSymbolTable(
    entries: []huffman.Entry,
    symbol0: u16,
    symbol1: u16,
    symbol2: u16,
    alphabet_size: u16,
) errors.Error!huffman.SymbolTable {
    assert(symbol0 < symbol1);
    assert(symbol1 < symbol2);
    assert(symbol2 < alphabet_size);

    var code_lengths: [huffman.green_alphabet_size_max]u8 =
        .{0} ** huffman.green_alphabet_size_max;
    code_lengths[symbol0] = 1;
    code_lengths[symbol1] = 2;
    code_lengths[symbol2] = 2;

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

test "VP8L entropy repeats a single-symbol color-cache code without consuming bits" {
    const cache_bits: u4 = 1;
    const cache_size: u16 = @as(u16, 1) << cache_bits;
    const cache_symbol = huffman.literal_alphabet_size + huffman.length_code_count;

    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    const prefix_codes = image_data.PrefixCodeGroup{
        .green = try singleSymbolTable(
            &buffers.green_entries,
            cache_symbol,
            huffman.literal_alphabet_size + huffman.length_code_count + cache_size,
        ),
        .red = try singleSymbolTable(&buffers.red_entries, 0, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers.blue_entries, 0, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers.alpha_entries, 0, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers.distance_entries,
            0,
            huffman.distance_alphabet_size,
        ),
    };

    var reader = bit_reader.BitReader.init(&.{});
    var output: [2]pixel.Pixel = undefined;
    const summary = try decodeWithPrefixCodes(
        &reader,
        try image.Dimensions.init(2, 1),
        .{ .bits = cache_bits, .size = cache_size },
        prefix_codes,
        &output,
    );

    try std.testing.expectEqual(@as(u64, 2), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 0), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 0), summary.copy_count);
    try std.testing.expectEqual(@as(u64, 2), summary.color_cache_count);
    try std.testing.expectEqual(@as(pixel.Pixel, 0), output[0]);
    try std.testing.expectEqual(@as(pixel.Pixel, 0), output[1]);
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
        &buffers.prefix_code_group,
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
        &buffers.prefix_code_group,
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

fn cloneSymbolTable(
    gpa: std.mem.Allocator,
    table: huffman.SymbolTable,
) errors.Error!huffman.SymbolTable {
    const source_entries = table.entriesSlice();
    const entries = try gpa.alloc(huffman.Entry, source_entries.len);
    errdefer gpa.free(entries);
    @memcpy(entries, source_entries);
    return .{
        .entries_ptr = entries.ptr,
        .entries_len = @intCast(entries.len),
        .single_symbol = table.single_symbol,
    };
}

fn clonePrefixCodeGroup(
    gpa: std.mem.Allocator,
    group: image_data.PrefixCodeGroup,
) errors.Error!image_data.PrefixCodeGroup {
    var copied: image_data.PrefixCodeGroup = undefined;
    copied.green = try cloneSymbolTable(gpa, group.green);
    errdefer gpa.free(copied.green.entriesSlice());
    copied.red = try cloneSymbolTable(gpa, group.red);
    errdefer gpa.free(copied.red.entriesSlice());
    copied.blue = try cloneSymbolTable(gpa, group.blue);
    errdefer gpa.free(copied.blue.entriesSlice());
    copied.alpha = try cloneSymbolTable(gpa, group.alpha);
    errdefer gpa.free(copied.alpha.entriesSlice());
    copied.distance = try cloneSymbolTable(gpa, group.distance);
    return copied;
}

fn testGroupStore(
    gpa: std.mem.Allocator,
    groups: []const image_data.PrefixCodeGroup,
) errors.Error!prefix_groups.Store {
    const owned = try gpa.alloc(image_data.PrefixCodeGroup, groups.len);
    errdefer gpa.free(owned);

    var store = prefix_groups.Store{
        .gpa = gpa,
        .groups = owned,
        .initialized_count = 0,
    };
    errdefer store.deinit();

    for (groups, 0..) |group, index| {
        store.groups[index] = try clonePrefixCodeGroup(gpa, group);
        store.initialized_count += 1;
    }

    return store;
}

test "VP8L entropy no-cache distance-one copy fills a run" {
    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    const prefix_codes = image_data.PrefixCodeGroup{
        .green = try twoSymbolTable(
            &buffers.green_entries,
            7,
            huffman.literal_alphabet_size + 2,
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
    var output: [4]pixel.Pixel = undefined;
    const summary = try decodeWithPrefixCodes(
        &reader,
        try image.Dimensions.init(4, 1),
        null,
        prefix_codes,
        &output,
    );

    const expected = pixel.fromChannels(4, 2, 7, 3);
    try std.testing.expectEqual(@as(u64, 4), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 1), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 1), summary.copy_count);
    try std.testing.expectEqual(@as(u64, 0), summary.color_cache_count);
    for (output) |value| {
        try std.testing.expectEqual(expected, value);
    }
}

test "VP8L entropy distance-one copy refreshes the color cache" {
    const cache_bits: u4 = 1;
    const stale: pixel.Pixel = 1;
    const repeated: pixel.Pixel = 0;
    const repeated_index = color_cache.hash(cache_bits, repeated);
    try std.testing.expectEqual(repeated_index, color_cache.hash(cache_bits, stale));

    var cache: color_cache.Cache = undefined;
    try cache.init(cache_bits);
    cache.insert(stale);
    try std.testing.expectEqual(stale, try cache.lookup(repeated_index));

    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    const prefix_codes = image_data.PrefixCodeGroup{
        .green = try singleSymbolTable(
            &buffers.green_entries,
            huffman.literal_alphabet_size,
            huffman.literal_alphabet_size + huffman.length_code_count,
        ),
        .red = try singleSymbolTable(&buffers.red_entries, 0, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers.blue_entries, 0, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers.alpha_entries, 0, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers.distance_entries,
            1,
            huffman.distance_alphabet_size,
        ),
    };

    var reader = bit_reader.BitReader.init(&.{});
    var output = [_]pixel.Pixel{ repeated, undefined };
    const output_index = try copyBackwardReference(
        true,
        &reader,
        try image.Dimensions.init(2, 1),
        &prefix_codes,
        &cache,
        &output,
        1,
        huffman.literal_alphabet_size,
    );

    try std.testing.expectEqual(@as(usize, 2), output_index);
    try std.testing.expectEqual(repeated, output[1]);
    try std.testing.expectEqual(repeated, try cache.lookup(repeated_index));
}

test "VP8L entropy no-cache overlapping copy repeats prior pixels" {
    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    const prefix_codes = image_data.PrefixCodeGroup{
        .green = try threeSymbolTable(
            &buffers.green_entries,
            5,
            7,
            huffman.literal_alphabet_size + 3,
            huffman.literal_alphabet_size + huffman.length_code_count,
        ),
        .red = try singleSymbolTable(&buffers.red_entries, 2, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers.blue_entries, 3, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers.alpha_entries, 4, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers.distance_entries,
            4,
            huffman.distance_alphabet_size,
        ),
    };

    // Green codes: 5=0, 7=01, length=11; distance prefix 4 + extra 1 => distance 2.
    var encoded: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0); // literal A (green 5)
    try writer.writeBit(1); // literal B (green 7)
    try writer.writeBit(0);
    try writer.writeBit(1); // length 4
    try writer.writeBit(1);
    try writer.writeBit(1); // distance_code 6 -> distance 2

    var reader = bit_reader.BitReader.init(try writer.finish());
    var output: [6]pixel.Pixel = undefined;
    const summary = try decodeWithPrefixCodes(
        &reader,
        try image.Dimensions.init(6, 1),
        null,
        prefix_codes,
        &output,
    );

    const expected_a = pixel.fromChannels(4, 2, 5, 3);
    const expected_b = pixel.fromChannels(4, 2, 7, 3);
    try std.testing.expectEqual(@as(u64, 6), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 2), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 1), summary.copy_count);
    try std.testing.expectEqual(@as(u64, 0), summary.color_cache_count);
    try std.testing.expectEqual(expected_a, output[0]);
    try std.testing.expectEqual(expected_b, output[1]);
    try std.testing.expectEqual(expected_a, output[2]);
    try std.testing.expectEqual(expected_b, output[3]);
    try std.testing.expectEqual(expected_a, output[4]);
    try std.testing.expectEqual(expected_b, output[5]);
}

test "VP8L entropy no-cache disjoint copy memcpy reproduces source pixels" {
    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    const prefix_codes = image_data.PrefixCodeGroup{
        .green = try threeSymbolTable(
            &buffers.green_entries,
            5,
            7,
            huffman.literal_alphabet_size + 1,
            huffman.literal_alphabet_size + huffman.length_code_count,
        ),
        .red = try singleSymbolTable(&buffers.red_entries, 2, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers.blue_entries, 3, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers.alpha_entries, 4, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers.distance_entries,
            4,
            huffman.distance_alphabet_size,
        ),
    };

    // Green codes: 5=0, 7=01, length=11; distance prefix 4 + extra 1 => distance 2 (>= length 2).
    var encoded: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBit(0); // literal A (green 5)
    try writer.writeBit(1); // literal B (green 7)
    try writer.writeBit(0);
    try writer.writeBit(1); // length 2
    try writer.writeBit(1);
    try writer.writeBit(1); // distance 2 >= length 2

    var reader = bit_reader.BitReader.init(try writer.finish());
    var output: [4]pixel.Pixel = undefined;
    const summary = try decodeWithPrefixCodes(
        &reader,
        try image.Dimensions.init(4, 1),
        null,
        prefix_codes,
        &output,
    );

    const expected_a = pixel.fromChannels(4, 2, 5, 3);
    const expected_b = pixel.fromChannels(4, 2, 7, 3);
    try std.testing.expectEqual(@as(u64, 4), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 2), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 1), summary.copy_count);
    try std.testing.expectEqual(@as(u64, 0), summary.color_cache_count);
    try std.testing.expectEqual(expected_a, output[0]);
    try std.testing.expectEqual(expected_b, output[1]);
    try std.testing.expectEqual(expected_a, output[2]);
    try std.testing.expectEqual(expected_b, output[3]);
}

test "VP8L entropy no-cache rejects color-cache symbols" {
    const cache_symbol = huffman.literal_alphabet_size + huffman.length_code_count;
    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    const prefix_codes = image_data.PrefixCodeGroup{
        .green = try singleSymbolTable(
            &buffers.green_entries,
            cache_symbol,
            huffman.literal_alphabet_size + huffman.length_code_count + 1,
        ),
        .red = try singleSymbolTable(&buffers.red_entries, 0, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers.blue_entries, 0, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers.alpha_entries, 0, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers.distance_entries,
            0,
            huffman.distance_alphabet_size,
        ),
    };

    var reader = bit_reader.BitReader.init(&.{});
    var output: [1]pixel.Pixel = undefined;
    try std.testing.expectError(
        error.InvalidVP8LImageData,
        decodeWithPrefixCodes(
            &reader,
            try image.Dimensions.init(1, 1),
            null,
            prefix_codes,
            &output,
        ),
    );
}

test "VP8L entropy spatial decode switches groups at tile boundaries" {
    var buffers0: image_data.PrefixCodeGroupBuffers = .{};
    var buffers1: image_data.PrefixCodeGroupBuffers = .{};
    const group0 = image_data.PrefixCodeGroup{
        .green = try singleSymbolTable(&buffers0.green_entries, 0, huffman.literal_alphabet_size + huffman.length_code_count),
        .red = try singleSymbolTable(&buffers0.red_entries, 0, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers0.blue_entries, 0, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers0.alpha_entries, 0, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(&buffers0.distance_entries, 0, huffman.distance_alphabet_size),
    };
    const group1 = image_data.PrefixCodeGroup{
        .green = try singleSymbolTable(&buffers1.green_entries, 1, huffman.literal_alphabet_size + huffman.length_code_count),
        .red = try singleSymbolTable(&buffers1.red_entries, 0, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers1.blue_entries, 0, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers1.alpha_entries, 0, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(&buffers1.distance_entries, 0, huffman.distance_alphabet_size),
    };

    var store = try testGroupStore(std.testing.allocator, &.{ group0, group1 });
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
    try std.testing.expectEqual(@as(u64, 0), summary.copy_count);
    for (output[0..4]) |value| {
        try std.testing.expectEqual(pixel.fromChannels(0, 0, 0, 0), value);
    }
    for (output[4..8]) |value| {
        try std.testing.expectEqual(pixel.fromChannels(0, 0, 1, 0), value);
    }
}

test "VP8L entropy spatial decode refetches after a cross-row copy" {
    var buffers0: image_data.PrefixCodeGroupBuffers = .{};
    var buffers1: image_data.PrefixCodeGroupBuffers = .{};
    const group0 = image_data.PrefixCodeGroup{
        .green = try twoSymbolTable(
            &buffers0.green_entries,
            5,
            huffman.literal_alphabet_size + 2,
            huffman.literal_alphabet_size + huffman.length_code_count,
        ),
        .red = try singleSymbolTable(&buffers0.red_entries, 1, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers0.blue_entries, 2, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers0.alpha_entries, 3, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers0.distance_entries,
            1,
            huffman.distance_alphabet_size,
        ),
    };
    const group1 = image_data.PrefixCodeGroup{
        .green = try singleSymbolTable(
            &buffers1.green_entries,
            9,
            huffman.literal_alphabet_size + huffman.length_code_count,
        ),
        .red = try singleSymbolTable(&buffers1.red_entries, 4, huffman.literal_alphabet_size),
        .blue = try singleSymbolTable(&buffers1.blue_entries, 5, huffman.literal_alphabet_size),
        .alpha = try singleSymbolTable(&buffers1.alpha_entries, 6, huffman.literal_alphabet_size),
        .distance = try singleSymbolTable(
            &buffers1.distance_entries,
            0,
            huffman.distance_alphabet_size,
        ),
    };

    var store = try testGroupStore(std.testing.allocator, &.{ group0, group1 });
    defer store.deinit();

    // block_size 4 needs height > 4 for a second entropy row. Rows 0..3 use group 0;
    // row 4 uses group 1.
    const info = meta_prefix.Info{
        .prefix_bits = 2,
        .block_size = 4,
        .image_dimensions = try image.Dimensions.init(4, 5),
        .entropy_dimensions = try image.Dimensions.init(1, 2),
        .group_count = 2,
    };
    const entropy_image = [_]pixel.Pixel{
        pixel.fromChannels(0, 0, 0, 0),
        pixel.fromChannels(0, 0, 1, 0),
    };

    // 15 literals fill indices 0..14; a length-3 distance-1 copy starts at the last
    // pixel of tile-row 3 (index 15) and continues into row 4. Remaining row-4 pixels
    // are literals from group 1, proving the post-copy refetch.
    var encoded: [2]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    var literal_index: usize = 0;
    while (literal_index < 15) : (literal_index += 1) {
        try writer.writeBit(0);
    }
    try writer.writeBit(1);

    var image_reader = bit_reader.BitReader.init(try writer.finish());
    var output: [20]pixel.Pixel = undefined;
    const summary = try decodeWithGroupStore(
        &image_reader,
        try image.Dimensions.init(4, 5),
        null,
        store,
        info,
        &entropy_image,
        &output,
    );

    const from_group0 = pixel.fromChannels(3, 1, 5, 2);
    const from_group1 = pixel.fromChannels(6, 4, 9, 5);
    try std.testing.expectEqual(@as(u64, 20), summary.pixel_count);
    try std.testing.expectEqual(@as(u64, 17), summary.literal_count);
    try std.testing.expectEqual(@as(u64, 1), summary.copy_count);
    try std.testing.expectEqual(@as(u64, 0), summary.color_cache_count);

    for (output[0..18]) |value| {
        try std.testing.expectEqual(from_group0, value);
    }
    try std.testing.expectEqual(from_group1, output[18]);
    try std.testing.expectEqual(from_group1, output[19]);
}
