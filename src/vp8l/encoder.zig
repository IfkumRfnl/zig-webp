//! VP8L lossless encoder.
//!
//! Slice 1 emits valid VP8L still-image bitstreams from ARGB literals only:
//! no LZ77 backward references, no transforms, and no color cache. Every
//! pixel is encoded as four literal channel symbols (green, red, blue, alpha)
//! under per-channel canonical Huffman codes built from the image histogram.
//! The output is read back bit-exactly by this project's VP8L decoder.
//!
//! The bitstream layout mirrors `decoder.zig` / `image_data.zig` (the readers
//! this encoder must invert):
//!   - 5-byte VP8L image header (signature + packed dimensions/alpha/version);
//!   - one "no transform" bit (transform list terminator);
//!   - color-cache-present bit = 0;
//!   - meta-prefix-present bit = 0 (single prefix-code group);
//!   - five prefix codes (green, red, blue, alpha, distance) in normal form;
//!   - the entropy-coded literal symbol stream.

const std = @import("std");
const assert = std.debug.assert;

const bit_writer = @import("../bit_writer.zig");
const container = @import("../container.zig");
const errors = @import("../errors.zig");
const header = @import("header.zig");
const huffman = @import("huffman.zig");
const huffman_writer = @import("huffman_writer.zig");
const image = @import("../image.zig");
const image_data = @import("image_data.zig");
const pixel = @import("pixel.zig");

pub const Error = errors.Error;

/// Maximum image dimensions accepted by the encoder, matching the decoder's
/// VP8L header limit.
pub const dimension_max = header.dimension_limit;

/// The five literal channels carry an 8-bit alphabet; the green channel's full
/// alphabet also spans length and color-cache symbols, but slice 1 never emits
/// those, so its histogram only ever populates the literal range.
const channel_count = 4;

/// Per-channel canonical Huffman code working storage.
const ChannelCode = struct {
    lengths: [huffman.literal_alphabet_size]u8 = .{0} ** huffman.literal_alphabet_size,
    codes: [huffman.literal_alphabet_size]u16 = .{0} ** huffman.literal_alphabet_size,

    fn code(self: *const ChannelCode) huffman_writer.Code {
        return .{
            .lengths = &self.lengths,
            .codes = &self.codes,
            .single_symbol = huffman_writer.singleSymbol(&self.lengths),
        };
    }
};

/// The green-channel code spans the literal alphabet only in slice 1 (no
/// length or color-cache symbols are produced), but its alphabet size is the
/// full literal+length range so the decoder reads it back correctly.
const green_alphabet_size = huffman.literal_alphabet_size + huffman.length_code_count;

const GreenCode = struct {
    lengths: [green_alphabet_size]u8 = .{0} ** green_alphabet_size,
    codes: [green_alphabet_size]u16 = .{0} ** green_alphabet_size,

    fn code(self: *const GreenCode) huffman_writer.Code {
        return .{
            .lengths = &self.lengths,
            .codes = &self.codes,
            .single_symbol = huffman_writer.singleSymbol(&self.lengths),
        };
    }
};

/// Distance code: slice 1 emits no copies, so this code is never used to emit a
/// symbol, but a valid prefix code must still be written for the decoder. A
/// single populated symbol (length 1) is the smallest valid code.
const distance_alphabet_size = huffman.distance_alphabet_size;

/// Returns a safe upper bound on the encoded byte length for the given
/// dimensions, so callers can size a buffer for `encodeInto`. It is an upper
/// bound (not exact) because the entropy-coded size depends on the histogram;
/// `encodeAlloc` trims the allocation to the exact length.
pub fn maxEncodedSize(dimensions: image.Dimensions) Error!usize {
    const pixel_count = try dimensions.pixelCount();
    // Header + generous bound for prefix-code descriptors + worst-case 15 bits
    // per channel symbol (4 channels per pixel) rounded up to bytes.
    const descriptor_bound: u64 = 4096;
    const symbol_bits: u64 = pixel_count * channel_count * huffman.max_code_bits;
    const symbol_bytes: u64 = (symbol_bits + 7) / 8;
    const total: u64 = header.byte_count + descriptor_bound + symbol_bytes + 16;
    if (total > std.math.maxInt(usize)) return error.OutputTooLarge;
    return @intCast(total);
}

/// Encodes the `width`x`height` ARGB pixel array (row-major, `pixel.Pixel` =
/// packed 0xAARRGGBB) as a VP8L bitstream into a freshly allocated buffer the
/// caller owns and frees with `gpa`. The result is a raw VP8L bitstream (the
/// payload of a `VP8L` chunk), ready to hand to `mux.encodeStatic`.
pub fn encodeAlloc(
    gpa: std.mem.Allocator,
    dimensions: image.Dimensions,
    pixels: []const pixel.Pixel,
) Error![]u8 {
    const pixel_count = try dimensions.pixelCount();
    if (pixels.len != pixel_count) return error.OutputTooLarge;
    if (dimensions.width > dimension_max or dimensions.height > dimension_max) {
        return error.InvalidVP8LHeader;
    }

    const capacity = try maxEncodedSize(dimensions);
    const buffer = try gpa.alloc(u8, capacity);
    errdefer gpa.free(buffer);

    const written = try encodeInto(buffer, dimensions, pixels);
    const len = written.len;

    // Shrink to the exact encoded length.
    if (gpa.resize(buffer, len)) {
        return buffer[0..len];
    }
    const exact = try gpa.alloc(u8, len);
    @memcpy(exact, written);
    gpa.free(buffer);
    return exact;
}

/// Encodes into a caller-provided buffer; returns the populated prefix. Fails
/// with `error.OutputTooLarge` if the buffer is too small. Use
/// `maxEncodedSize` to size it.
pub fn encodeInto(
    out: []u8,
    dimensions: image.Dimensions,
    pixels: []const pixel.Pixel,
) Error![]const u8 {
    const pixel_count = try dimensions.pixelCount();
    if (pixels.len != pixel_count) return error.OutputTooLarge;
    if (dimensions.width == 0 or dimensions.height == 0) return error.InvalidVP8LHeader;
    if (dimensions.width > dimension_max or dimensions.height > dimension_max) {
        return error.InvalidVP8LHeader;
    }
    if (out.len < header.byte_count) return error.OutputTooLarge;

    const has_alpha = imageHasAlpha(pixels);
    writeImageHeader(out[0..header.byte_count], dimensions, has_alpha);

    // Build per-channel histograms over the literal symbols.
    var green_counts: [green_alphabet_size]u32 = .{0} ** green_alphabet_size;
    var red_counts: [huffman.literal_alphabet_size]u32 = .{0} ** huffman.literal_alphabet_size;
    var blue_counts: [huffman.literal_alphabet_size]u32 = .{0} ** huffman.literal_alphabet_size;
    var alpha_counts: [huffman.literal_alphabet_size]u32 = .{0} ** huffman.literal_alphabet_size;

    for (pixels) |value| {
        green_counts[pixel.green(value)] += 1;
        red_counts[pixel.red(value)] += 1;
        blue_counts[pixel.blue(value)] += 1;
        alpha_counts[pixel.alpha(value)] += 1;
    }

    var green_code: GreenCode = .{};
    var red_code: ChannelCode = .{};
    var blue_code: ChannelCode = .{};
    var alpha_code: ChannelCode = .{};

    huffman_writer.build(&green_counts, &green_code.lengths, &green_code.codes);
    huffman_writer.build(&red_counts, &red_code.lengths, &red_code.codes);
    huffman_writer.build(&blue_counts, &blue_code.lengths, &blue_code.codes);
    huffman_writer.build(&alpha_counts, &alpha_code.lengths, &alpha_code.codes);

    var writer = bit_writer.BitWriter.init(out[header.byte_count..]);

    // Transform list: a single 0 bit means "no transform".
    try writer.writeBit(0);

    // Main image stream header: no color cache, single prefix-code group.
    try writer.writeBit(0); // color cache present = 0
    try writer.writeBit(0); // meta-prefix present = 0

    // Five prefix codes, in decoder order: green, red, blue, alpha, distance.
    try writeNormalPrefixCode(&writer, &green_code.lengths);
    try writeNormalPrefixCode(&writer, &red_code.lengths);
    try writeNormalPrefixCode(&writer, &blue_code.lengths);
    try writeNormalPrefixCode(&writer, &alpha_code.lengths);
    try writeDistancePrefixCode(&writer);

    // Entropy-coded literal stream: green, red, blue, alpha per pixel.
    const g = green_code.code();
    const r = red_code.code();
    const b = blue_code.code();
    const a = alpha_code.code();
    for (pixels) |value| {
        try g.writeSymbol(&writer, pixel.green(value));
        try r.writeSymbol(&writer, pixel.red(value));
        try b.writeSymbol(&writer, pixel.blue(value));
        try a.writeSymbol(&writer, pixel.alpha(value));
    }

    const image_data_bytes = try writer.finish();
    return out[0 .. header.byte_count + image_data_bytes.len];
}

fn imageHasAlpha(pixels: []const pixel.Pixel) bool {
    for (pixels) |value| {
        if (pixel.alpha(value) != 255) return true;
    }
    return false;
}

fn writeImageHeader(
    payload: *[header.byte_count]u8,
    dimensions: image.Dimensions,
    has_alpha: bool,
) void {
    assert(dimensions.width > 0);
    assert(dimensions.width <= header.dimension_limit);
    assert(dimensions.height > 0);
    assert(dimensions.height <= header.dimension_limit);

    payload[0] = header.signature;
    const bits = (dimensions.width - 1) |
        ((dimensions.height - 1) << 14) |
        (@as(u32, @intFromBool(has_alpha)) << 28);
    container.writeLittleU32(payload[1..header.byte_count], bits);
}

/// The code-length-code alphabet has 19 symbols; the reader walks them in the
/// fixed `code_length_code_order`. Slice 1 always sends all 19 (count field 15)
/// so the descriptor is simple and order-independent.
const code_length_code_count = huffman.code_length_code_count;

/// Writes one prefix code in the decoder's "normal" form: the code-length
/// symbols are themselves Huffman-coded by a code-length-code (a 19-symbol
/// meta-Huffman code). Slice 1 emits each per-symbol code length directly
/// (symbols 0..15), never the repeat codes 16/17/18, which keeps the encoder
/// simple while staying a valid stream the reader accepts.
fn writeNormalPrefixCode(writer: *bit_writer.BitWriter, lengths: []const u8) Error!void {
    assert(lengths.len > 0);
    assert(lengths.len <= huffman.green_alphabet_size_max);

    // Histogram of code-length symbols actually used (only values 0..15 here).
    var cl_counts: [code_length_code_count]u32 = .{0} ** code_length_code_count;
    for (lengths) |l| {
        assert(l <= huffman.max_code_bits);
        cl_counts[l] += 1;
    }

    // Build the code-length-code (its own canonical Huffman code). The format
    // caps it at 7 bits, so build with that explicit length limit.
    var cl_lengths: [code_length_code_count]u8 = .{0} ** code_length_code_count;
    var cl_codes: [code_length_code_count]u16 = .{0} ** code_length_code_count;
    huffman_writer.buildLimited(
        &cl_counts,
        &cl_lengths,
        &cl_codes,
        huffman.code_length_code_bits_max,
    );

    // simple_code bit = 0 (normal form).
    try writer.writeBit(0);

    // num_code_lengths = 4 + N (we send all 19 -> N = 15).
    const num_extra: u32 = code_length_code_count - 4;
    try writer.writeBits(num_extra, 4);

    // Code-length-code lengths, in the fixed order, 3 bits each.
    for (huffman.code_length_code_order) |ordered_index| {
        try writer.writeBits(cl_lengths[ordered_index], 3);
    }

    // max_symbol selector: 0 means "use the full alphabet"; we always emit a
    // code length for every symbol in the alphabet.
    try writer.writeBit(0);

    // Emit each symbol's code length under the code-length-code.
    const cl_code = huffman_writer.Code{
        .lengths = &cl_lengths,
        .codes = &cl_codes,
        .single_symbol = huffman_writer.singleSymbol(&cl_lengths),
    };
    for (lengths) |l| {
        try cl_code.writeSymbol(writer, l);
    }
}

/// Writes a minimal valid distance prefix code. Slice 1 emits no copies, so the
/// distance code is never used to emit a symbol; a single-symbol code (one
/// symbol with length 1) is the smallest valid code the reader accepts.
fn writeDistancePrefixCode(writer: *bit_writer.BitWriter) Error!void {
    var counts: [distance_alphabet_size]u32 = .{0} ** distance_alphabet_size;
    counts[0] = 1; // one populated symbol -> the single-leaf exception.

    var lengths: [distance_alphabet_size]u8 = .{0} ** distance_alphabet_size;
    var codes: [distance_alphabet_size]u16 = .{0} ** distance_alphabet_size;
    huffman_writer.build(&counts, &lengths, &codes);

    try writeNormalPrefixCode(writer, &lengths);
}

const testing = std.testing;

fn decodeRoundTrip(
    gpa: std.mem.Allocator,
    dimensions: image.Dimensions,
    pixels: []const pixel.Pixel,
) !void {
    const decoder = @import("decoder.zig");

    const encoded = try encodeAlloc(gpa, dimensions, pixels);
    defer gpa.free(encoded);

    const pixel_count: usize = @intCast(try dimensions.pixelCount());
    const output = try gpa.alloc(pixel.Pixel, pixel_count);
    defer gpa.free(output);

    var buffers: decoder.WorkBuffers = .{};
    const result = try decoder.decodeARGB(encoded, output, &buffers);

    try testing.expectEqual(dimensions.width, result.header.dimensions.width);
    try testing.expectEqual(dimensions.height, result.header.dimensions.height);
    try testing.expectEqualSlices(pixel.Pixel, pixels, output);
}

test "encodes and round-trips a 1x1 image" {
    const dims = try image.Dimensions.init(1, 1);
    const pixels = [_]pixel.Pixel{pixel.fromChannels(0xab, 0x12, 0x34, 0x56)};
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encodes and round-trips a solid-color image" {
    const dims = try image.Dimensions.init(8, 8);
    var pixels: [64]pixel.Pixel = undefined;
    @memset(&pixels, pixel.fromChannels(255, 10, 20, 30));
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encodes and round-trips a two-axis gradient" {
    const width = 17;
    const height = 13;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height]pixel.Pixel = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            const b: u8 = @intCast((x + y) % 256);
            pixels[y * width + x] = pixel.fromChannels(255, r, g, b);
        }
    }
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encodes and round-trips full-range alpha" {
    const dims = try image.Dimensions.init(16, 16);
    var pixels: [256]pixel.Pixel = undefined;
    for (&pixels, 0..) |*p, i| {
        const v: u8 = @intCast(i);
        p.* = pixel.fromChannels(v, v, 255 - v, v ^ 0x55);
    }
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encodes and round-trips a single-row image" {
    const dims = try image.Dimensions.init(64, 1);
    var pixels: [64]pixel.Pixel = undefined;
    for (&pixels, 0..) |*p, i| p.* = pixel.fromChannels(255, @intCast(i * 3 % 256), @intCast(i), 0);
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encodes and round-trips a single-column image" {
    const dims = try image.Dimensions.init(1, 64);
    var pixels: [64]pixel.Pixel = undefined;
    for (&pixels, 0..) |*p, i| p.* = pixel.fromChannels(128, 0, @intCast(i), @intCast(255 - i));
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encoder marks opaque images as alpha-free in the header" {
    const dims = try image.Dimensions.init(2, 2);
    const opaque_pixels = [_]pixel.Pixel{
        pixel.fromChannels(255, 1, 2, 3),
        pixel.fromChannels(255, 4, 5, 6),
        pixel.fromChannels(255, 7, 8, 9),
        pixel.fromChannels(255, 10, 11, 12),
    };
    const encoded = try encodeAlloc(testing.allocator, dims, &opaque_pixels);
    defer testing.allocator.free(encoded);

    const parsed = try header.parse(encoded);
    try testing.expect(!parsed.has_alpha);

    const translucent = [_]pixel.Pixel{
        pixel.fromChannels(255, 1, 2, 3),
        pixel.fromChannels(254, 4, 5, 6),
        pixel.fromChannels(255, 7, 8, 9),
        pixel.fromChannels(255, 10, 11, 12),
    };
    const encoded2 = try encodeAlloc(testing.allocator, dims, &translucent);
    defer testing.allocator.free(encoded2);
    const parsed2 = try header.parse(encoded2);
    try testing.expect(parsed2.has_alpha);
}

test "encoder rejects a pixel count that disagrees with dimensions" {
    const dims = try image.Dimensions.init(4, 4);
    const pixels = [_]pixel.Pixel{pixel.fromChannels(0, 0, 0, 0)} ** 4;
    try testing.expectError(error.OutputTooLarge, encodeAlloc(testing.allocator, dims, &pixels));
}
