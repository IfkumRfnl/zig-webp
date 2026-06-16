//! VP8L lossless encoder.
//!
//! Slice 2 builds compression on top of slice 1's literal output:
//!   - LZ77 back-reference matching with literal/copy Huffman coding (the
//!     length symbols extend the green-channel alphabet, distances use the
//!     distance prefix code), inverting the decoder's backward-reference path.
//!   - A subtract-green transform.
//!   - A palette / color-indexing transform for low-color images, with the
//!     bit-packing the decoder expects.
//!   - A predictor transform and a color transform (single global block each).
//!
//! Every transform is decision-gated: it is applied only when an estimate says
//! it shrinks the output, and the choice is encoded so the decoder inverts it.
//! Each transform's forward step is the exact inverse of the corresponding
//! `inverse_transform.zig` routine, so any combination round-trips bit-exactly
//! through this project's decoder (proven by the corpus round-trip test).
//!
//! The bitstream layout mirrors `decoder.zig` / `image_data.zig`:
//!   - 5-byte VP8L image header;
//!   - the transform list (each chosen transform, then a terminator 0 bit);
//!   - the main image stream (no color cache, single prefix-code group): the
//!     color-cache-present bit, the meta-prefix bit, five prefix codes, then
//!     the entropy-coded token stream.

const std = @import("std");
const assert = std.debug.assert;

const bit_writer = @import("../bit_writer.zig");
const container = @import("../container.zig");
const errors = @import("../errors.zig");
const forward_transform = @import("forward_transform.zig");
const header = @import("header.zig");
const huffman = @import("huffman.zig");
const huffman_writer = @import("huffman_writer.zig");
const image = @import("../image.zig");
const image_data = @import("image_data.zig");
const lz77 = @import("lz77.zig");
const pixel = @import("pixel.zig");
const transform = @import("transform.zig");

pub const Error = errors.Error;

/// Maximum image dimensions accepted by the encoder, matching the decoder's
/// VP8L header limit.
pub const dimension_max = header.dimension_limit;

/// The green channel's full alphabet spans literals + length codes (no color
/// cache symbols in this slice).
const green_alphabet_size = huffman.literal_alphabet_size + huffman.length_code_count;
const literal_alphabet_size = huffman.literal_alphabet_size;
const distance_alphabet_size = huffman.distance_alphabet_size;

/// Code-length-code alphabet size (19 meta symbols), reused for prefix-code
/// descriptors.
const code_length_code_count = huffman.code_length_code_count;

/// Maximum palette size for the color-indexing transform.
const palette_size_max = transform.color_table_size_max;

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
    if (dimensions.width == 0 or dimensions.height == 0) return error.InvalidVP8LHeader;
    if (dimensions.width > dimension_max or dimensions.height > dimension_max) {
        return error.InvalidVP8LHeader;
    }

    var encoder = try Encoder.init(gpa, dimensions, pixels);
    defer encoder.deinit();

    return encoder.run();
}

/// Internal encoder state: owns the scratch buffers and the growable output.
const Encoder = struct {
    gpa: std.mem.Allocator,
    dimensions: image.Dimensions,
    source: []const pixel.Pixel,
    has_alpha: bool,

    fn init(
        gpa: std.mem.Allocator,
        dimensions: image.Dimensions,
        source: []const pixel.Pixel,
    ) Error!Encoder {
        return .{
            .gpa = gpa,
            .dimensions = dimensions,
            .source = source,
            .has_alpha = imageHasAlpha(source),
        };
    }

    fn deinit(self: *Encoder) void {
        _ = self;
    }

    fn run(self: *Encoder) Error![]u8 {
        // Plan: decide the transform stack and produce the transformed main
        // image plus the transform records to emit.
        var plan = try Plan.build(self.gpa, self.dimensions, self.source);
        defer plan.deinit(self.gpa);

        // Tokenize the main image with LZ77.
        const main_pixels = plan.main_pixels;
        const main_dimensions = plan.main_dimensions;
        const main_pixel_count: usize = @intCast(try main_dimensions.pixelCount());
        assert(main_pixels.len == main_pixel_count);

        const tokens = try self.gpa.alloc(lz77.Token, main_pixel_count);
        defer self.gpa.free(tokens);
        const token_stream = try tokenize(self.gpa, main_dimensions, main_pixels, tokens);

        // Assemble the full bitstream into a single allocation sized by the
        // worst-case bound, then trim to the exact written length.
        const capacity = try maxEncodedSize(self.dimensions);
        const buffer = try self.gpa.alloc(u8, capacity);
        errdefer self.gpa.free(buffer);

        var writer = bit_writer.BitWriter.init(buffer[header.byte_count..]);

        // Transform list: emit each transform record, then a terminator 0 bit.
        // Spatial (predictor/color) transforms operate on the full image, so
        // their block sub-image grid derives from the original dimensions.
        for (plan.transforms()) |record| {
            try writeTransformRecord(&writer, record, self.dimensions);
        }
        try writer.writeBit(0); // no more transforms

        // Main image stream: no color cache, single prefix-code group.
        try writer.writeBit(0); // color cache present = 0
        try writer.writeBit(0); // meta-prefix present = 0

        try emitEntropyCoded(&writer, token_stream);

        const image_bytes = try writer.finish();
        const total_len = header.byte_count + image_bytes.len;

        // Write the header into the front of the buffer.
        writeImageHeader(buffer[0..header.byte_count], self.dimensions, self.has_alpha);

        // Trim to the exact encoded length.
        if (self.gpa.resize(buffer, total_len)) {
            return buffer[0..total_len];
        }
        const exact = try self.gpa.alloc(u8, total_len);
        @memcpy(exact, buffer[0..total_len]);
        self.gpa.free(buffer);
        return exact;
    }
};

/// Returns a safe upper bound on the encoded byte length for the given
/// dimensions. The transform records add a bounded amount; the token stream is
/// bounded by the literal worst case (no copies) at 15 bits per channel symbol.
pub fn maxEncodedSize(dimensions: image.Dimensions) Error!usize {
    const pixel_count = try dimensions.pixelCount();
    const descriptor_bound: u64 = 1 << 16;
    // Worst case: every pixel is four literal symbols at the max code width,
    // plus the transform sub-images (bounded by the same per-pixel budget).
    const symbol_bits: u64 = pixel_count * 4 * huffman.max_code_bits;
    const symbol_bytes: u64 = (symbol_bits + 7) / 8;
    const total: u64 = header.byte_count + descriptor_bound + 2 * symbol_bytes + 64;
    if (total > std.math.maxInt(usize)) return error.OutputTooLarge;
    return @intCast(total);
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

// ---------------------------------------------------------------------------
// Transform planning.
// ---------------------------------------------------------------------------

/// A transform to emit, with the forward-transformed sub-image data it carries.
const TransformRecord = union(enum) {
    subtract_green: void,
    color: ColorRecord,
    predictor: PredictorRecord,
    color_indexing: ColorIndexingRecord,
};

const ColorRecord = struct {
    element: forward_transform.ColorTransformElement,
};

const PredictorRecord = struct {
    mode: u8,
};

const ColorIndexingRecord = struct {
    /// Delta-coded palette entries (what the decoder reads, before prefix-sum).
    delta_table: []pixel.Pixel,
    color_table_size: u16,
    width_bits: u3,
};

/// The result of transform planning: the transform records (in stream order)
/// and the fully transformed main image plus its dimensions.
const Plan = struct {
    /// Fixed-capacity transform records, sliced via `transforms()` so the Plan
    /// can be returned by value without a self-referential slice field.
    transform_storage: [transform.transform_count_max]TransformRecord,
    transform_count: usize,
    main_pixels: []pixel.Pixel,
    main_dimensions: image.Dimensions,
    owns_main: bool,
    palette: ?[]pixel.Pixel,

    fn transforms(self: *const Plan) []const TransformRecord {
        return self.transform_storage[0..self.transform_count];
    }

    fn build(
        gpa: std.mem.Allocator,
        dimensions: image.Dimensions,
        source: []const pixel.Pixel,
    ) Error!Plan {
        var plan = Plan{
            .transform_storage = undefined,
            .transform_count = 0,
            .main_pixels = undefined,
            .main_dimensions = dimensions,
            .owns_main = false,
            .palette = null,
        };
        errdefer plan.deinit(gpa);

        // 1) Try the palette / color-indexing path for low-color images. When
        //    it applies, it is the only transform (the index image is encoded
        //    directly), matching libwebp's typical low-color layout.
        if (try tryBuildPalette(gpa, dimensions, source)) |built| {
            plan.palette = built.palette;
            plan.transform_storage[0] = .{ .color_indexing = built.record };
            plan.transform_count = 1;
            plan.main_pixels = built.index_pixels;
            plan.main_dimensions = built.index_dimensions;
            plan.owns_main = true;
            return plan;
        }

        // 2) Spatial transforms on a working copy of the source.
        const pixel_count: usize = @intCast(try dimensions.pixelCount());
        const working = try gpa.alloc(pixel.Pixel, pixel_count);
        @memcpy(working, source);
        plan.main_pixels = working;
        plan.owns_main = true;

        // Predictor transform: pick the single global mode with the lowest
        // residual entropy estimate; apply it if it beats the identity.
        if (try choosePredictor(gpa, dimensions, working)) |mode| {
            const residual = try gpa.alloc(pixel.Pixel, pixel_count);
            forward_transform.applyPredictor(
                mode,
                @intCast(dimensions.width),
                @intCast(dimensions.height),
                working,
                residual,
            );
            gpa.free(working);
            plan.main_pixels = residual;
            plan.addTransform(.{ .predictor = .{ .mode = mode } });
        }

        // Decorrelate the chroma channels. The color transform is a general
        // form of subtract-green; pick whichever lowers the residual more (or
        // neither). They are mutually exclusive so red/blue are not adjusted
        // twice.
        const color_element = chooseColorTransform(plan.main_pixels);
        const color_gain = colorTransformGain(plan.main_pixels, color_element);
        const subtract_gain = subtractGreenGain(plan.main_pixels);
        if (color_gain > subtract_gain and color_gain > 0) {
            forward_transform.applyColorTransform(color_element, plan.main_pixels);
            plan.addTransform(.{ .color = .{ .element = color_element } });
        } else if (subtract_gain > 0) {
            forward_transform.applySubtractGreen(plan.main_pixels);
            plan.addTransform(.{ .subtract_green = {} });
        }

        return plan;
    }

    fn addTransform(self: *Plan, record: TransformRecord) void {
        assert(self.transform_count < self.transform_storage.len);
        self.transform_storage[self.transform_count] = record;
        self.transform_count += 1;
    }

    fn deinit(self: *Plan, gpa: std.mem.Allocator) void {
        if (self.owns_main) gpa.free(self.main_pixels);
        if (self.palette) |palette| gpa.free(palette);
        for (self.transforms()) |record| {
            switch (record) {
                .color_indexing => |ci| gpa.free(ci.delta_table),
                else => {},
            }
        }
    }
};

const BuiltPalette = struct {
    record: ColorIndexingRecord,
    palette: []pixel.Pixel,
    index_pixels: []pixel.Pixel,
    index_dimensions: image.Dimensions,
};

/// Builds a palette + index image when the source has at most 256 distinct
/// colors. Returns null when the image has too many colors. The returned
/// `delta_table` is what the decoder reads (delta-coded palette).
fn tryBuildPalette(
    gpa: std.mem.Allocator,
    dimensions: image.Dimensions,
    source: []const pixel.Pixel,
) Error!?BuiltPalette {
    var palette_buffer: [palette_size_max]pixel.Pixel = undefined;
    var palette_count: usize = 0;

    // Collect distinct colors, bailing out past the palette limit.
    outer: for (source) |value| {
        for (palette_buffer[0..palette_count]) |existing| {
            if (existing == value) continue :outer;
        }
        if (palette_count == palette_size_max) return null;
        palette_buffer[palette_count] = value;
        palette_count += 1;
    }

    // A palette of one color still works, but offers little; require at least
    // two so the index image carries information (single-color images are
    // already tiny via the literal path).
    if (palette_count < 2) return null;

    // Sort the palette for deterministic, delta-friendly ordering.
    std.mem.sort(pixel.Pixel, palette_buffer[0..palette_count], {}, std.sort.asc(pixel.Pixel));

    const palette = try gpa.alloc(pixel.Pixel, palette_count);
    errdefer gpa.free(palette);
    @memcpy(palette, palette_buffer[0..palette_count]);

    const width_bits = colorTableWidthBits(@intCast(palette_count));
    const width_scale: u32 = @as(u32, 1) << @as(u5, width_bits);
    const index_width = divRoundUp(dimensions.width, width_scale);
    const index_dimensions = try image.Dimensions.init(index_width, dimensions.height);
    const index_pixel_count: usize = @intCast(try index_dimensions.pixelCount());

    const index_pixels = try gpa.alloc(pixel.Pixel, index_pixel_count);
    errdefer gpa.free(index_pixels);
    @memset(index_pixels, pixel.fromChannels(0, 0, 0, 0));

    try packIndices(
        dimensions,
        source,
        palette,
        index_pixels,
        index_dimensions,
        width_bits,
    );

    // Delta-code the palette as the decoder reads it.
    const delta_table = try gpa.alloc(pixel.Pixel, palette_count);
    errdefer gpa.free(delta_table);
    @memcpy(delta_table, palette);
    forward_transform.forwardColorTableDeltas(delta_table);

    return .{
        .record = .{
            .delta_table = delta_table,
            .color_table_size = @intCast(palette_count),
            .width_bits = width_bits,
        },
        .palette = palette,
        .index_pixels = index_pixels,
        .index_dimensions = index_dimensions,
    };
}

/// Packs per-pixel palette indices into the green channel of the index image,
/// bit-packing several indices per pixel when `width_bits > 0` (the inverse of
/// the decoder's `applyColorIndexingTransform` index extraction).
fn packIndices(
    dimensions: image.Dimensions,
    source: []const pixel.Pixel,
    palette: []const pixel.Pixel,
    index_pixels: []pixel.Pixel,
    index_dimensions: image.Dimensions,
    width_bits: u3,
) Error!void {
    const width: usize = @intCast(dimensions.width);
    const height: usize = @intCast(dimensions.height);
    const index_width: usize = @intCast(index_dimensions.width);

    const index_bits: u4 = if (width_bits == 0)
        8
    else
        @intCast(@as(u8, 8) >> width_bits);
    const per_pixel: usize = if (width_bits == 0) 1 else (@as(usize, 1) << width_bits);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const color = source[y * width + x];
            const color_index = paletteIndex(palette, color);

            const index_x = x >> width_bits;
            const dest = y * index_width + index_x;
            const slot: usize = if (width_bits == 0)
                0
            else
                (x & (per_pixel - 1));
            const shift: u3 = @intCast(slot * index_bits);

            const existing_green = pixel.green(index_pixels[dest]);
            const packed_green = existing_green | (color_index << shift);
            index_pixels[dest] = pixel.fromChannels(0, 0, packed_green, 0);
        }
    }
}

fn paletteIndex(palette: []const pixel.Pixel, color: pixel.Pixel) u8 {
    // Binary search: palette is sorted ascending.
    var lo: usize = 0;
    var hi: usize = palette.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (palette[mid] < color) {
            lo = mid + 1;
        } else if (palette[mid] > color) {
            hi = mid;
        } else {
            return @intCast(mid);
        }
    }
    unreachable; // every source color is in the palette by construction
}

fn colorTableWidthBits(color_table_size: u16) u3 {
    assert(color_table_size > 0);
    assert(color_table_size <= palette_size_max);
    if (color_table_size <= 2) return 3;
    if (color_table_size <= 4) return 2;
    if (color_table_size <= 16) return 1;
    return 0;
}

/// Chooses a global predictor mode by minimizing the summed per-channel
/// absolute residual over a strided sample of the image. Returns null when no
/// mode beats mode 1 (left) by enough to justify the transform overhead — but
/// since the predictor sub-image is tiny (one block), we keep any improvement.
fn choosePredictor(
    gpa: std.mem.Allocator,
    dimensions: image.Dimensions,
    source: []const pixel.Pixel,
) Error!?u8 {
    const width: usize = @intCast(dimensions.width);
    const height: usize = @intCast(dimensions.height);
    if (width * height < 4) return null;

    const residual = try gpa.alloc(pixel.Pixel, source.len);
    defer gpa.free(residual);

    var best_mode: u8 = 0;
    var best_cost: u64 = std.math.maxInt(u64);
    // The identity (no transform) baseline: residual against zero, i.e. the
    // raw channel magnitudes.
    const identity_cost = residualCost(source);

    var mode: u8 = 0;
    while (mode < forward_transform.predictor_mode_count) : (mode += 1) {
        forward_transform.applyPredictor(mode, width, height, source, residual);
        const cost = residualCost(residual);
        if (cost < best_cost) {
            best_cost = cost;
            best_mode = mode;
        }
    }

    if (best_cost >= identity_cost) return null;
    return best_mode;
}

/// A coarse cost proxy: sum of wrap-around channel magnitudes (a residual of
/// 255 is "distance 1" from zero), which tracks the entropy-coded size well
/// enough for transform decisions.
fn residualCost(pixels: []const pixel.Pixel) u64 {
    var cost: u64 = 0;
    for (pixels) |value| {
        cost += channelMagnitude(pixel.red(value));
        cost += channelMagnitude(pixel.green(value));
        cost += channelMagnitude(pixel.blue(value));
        cost += channelMagnitude(pixel.alpha(value));
    }
    return cost;
}

/// Estimated reduction in red+blue residual magnitude from subtract-green,
/// sampled over a stride for speed. Positive means it helps.
fn subtractGreenGain(pixels: []const pixel.Pixel) i64 {
    var before: i64 = 0;
    var after: i64 = 0;
    const stride = @max(pixels.len / 4096, 1);
    var i: usize = 0;
    while (i < pixels.len) : (i += stride) {
        const value = pixels[i];
        const g = pixel.green(value);
        const r = pixel.red(value);
        const b = pixel.blue(value);
        before += @intCast(channelMagnitude(r) + channelMagnitude(b));
        after += @intCast(channelMagnitude(r -% g) + channelMagnitude(b -% g));
    }
    return before - after;
}

/// Chooses color-transform multipliers by minimizing red/blue residual over a
/// strided sample. Each multiplier is searched independently over a small set
/// of signed 3.5 fixed-point values (the same encoding the decoder reads).
fn chooseColorTransform(pixels: []const pixel.Pixel) forward_transform.ColorTransformElement {
    const candidates = [_]i8{ -96, -64, -48, -32, -16, 0, 16, 32, 48, 64, 96 };
    const stride = @max(pixels.len / 4096, 1);

    // green -> red
    var best_gr: i8 = 0;
    var best_gr_cost: u64 = std.math.maxInt(u64);
    for (candidates) |m| {
        var cost: u64 = 0;
        var i: usize = 0;
        while (i < pixels.len) : (i += stride) {
            const g = pixel.green(pixels[i]);
            const r = pixel.red(pixels[i]);
            cost += channelMagnitude(subtractColorDelta(r, m, g));
        }
        if (cost < best_gr_cost) {
            best_gr_cost = cost;
            best_gr = m;
        }
    }

    // green -> blue and red -> blue, searched jointly in two passes.
    var best_gb: i8 = 0;
    var best_gb_cost: u64 = std.math.maxInt(u64);
    for (candidates) |m| {
        var cost: u64 = 0;
        var i: usize = 0;
        while (i < pixels.len) : (i += stride) {
            const g = pixel.green(pixels[i]);
            const b = pixel.blue(pixels[i]);
            cost += channelMagnitude(subtractColorDelta(b, m, g));
        }
        if (cost < best_gb_cost) {
            best_gb_cost = cost;
            best_gb = m;
        }
    }

    var best_rb: i8 = 0;
    var best_rb_cost: u64 = std.math.maxInt(u64);
    for (candidates) |m| {
        var cost: u64 = 0;
        var i: usize = 0;
        while (i < pixels.len) : (i += stride) {
            const g = pixel.green(pixels[i]);
            const r = pixel.red(pixels[i]);
            const b0 = subtractColorDelta(pixel.blue(pixels[i]), best_gb, g);
            cost += channelMagnitude(subtractColorDelta(b0, m, r));
        }
        if (cost < best_rb_cost) {
            best_rb_cost = cost;
            best_rb = m;
        }
    }

    return .{ .green_to_red = best_gr, .green_to_blue = best_gb, .red_to_blue = best_rb };
}

/// Estimated reduction in red+blue residual magnitude from applying `element`,
/// sampled over a stride. Positive means it helps.
fn colorTransformGain(
    pixels: []const pixel.Pixel,
    element: forward_transform.ColorTransformElement,
) i64 {
    var before: i64 = 0;
    var after: i64 = 0;
    const stride = @max(pixels.len / 4096, 1);
    var i: usize = 0;
    while (i < pixels.len) : (i += stride) {
        const g = pixel.green(pixels[i]);
        const r = pixel.red(pixels[i]);
        const b = pixel.blue(pixels[i]);
        before += @intCast(channelMagnitude(r) + channelMagnitude(b));
        const nr = subtractColorDelta(r, element.green_to_red, g);
        const nb = subtractColorDelta(
            subtractColorDelta(b, element.green_to_blue, g),
            element.red_to_blue,
            r,
        );
        after += @intCast(channelMagnitude(nr) + channelMagnitude(nb));
    }
    return before - after;
}

/// Subtracts a single color-transform delta from a channel value (mod 256),
/// matching `forward_transform.applyColorTransform`'s arithmetic so the
/// estimate reflects the actual transform.
fn subtractColorDelta(value: u8, multiplier: i8, channel: u8) u8 {
    const channel_signed: i8 = @bitCast(channel);
    const delta = (@as(i32, multiplier) * @as(i32, channel_signed)) >> 5;
    return @intCast(@mod(@as(i32, value) - delta, 256));
}

fn channelMagnitude(value: u8) u64 {
    const wrapped: u16 = if (value <= 128) value else @as(u16, 256) - value;
    return wrapped;
}

// ---------------------------------------------------------------------------
// LZ77 tokenization.
// ---------------------------------------------------------------------------

fn tokenize(
    gpa: std.mem.Allocator,
    dimensions: image.Dimensions,
    pixels: []const pixel.Pixel,
    tokens_out: []lz77.Token,
) Error![]lz77.Token {
    const head = try gpa.alloc(u32, 1 << 14);
    defer gpa.free(head);
    const prev = try gpa.alloc(u32, pixels.len);
    defer gpa.free(prev);

    const matcher = lz77.Matcher{ .pixels = pixels, .width = dimensions.width };
    return matcher.tokenize(tokens_out, head, prev);
}

// ---------------------------------------------------------------------------
// Entropy coding of the token stream.
// ---------------------------------------------------------------------------

/// Per-channel canonical Huffman code working storage for the four literal
/// channels and the distance channel.
fn ChannelCode(comptime alphabet_size: usize) type {
    return struct {
        lengths: [alphabet_size]u8 = .{0} ** alphabet_size,
        codes: [alphabet_size]u16 = .{0} ** alphabet_size,

        const Self = @This();

        fn code(self: *const Self) huffman_writer.Code {
            return .{
                .lengths = &self.lengths,
                .codes = &self.codes,
                .single_symbol = huffman_writer.singleSymbol(&self.lengths),
            };
        }
    };
}

const GreenCode = ChannelCode(green_alphabet_size);
const LiteralCode = ChannelCode(literal_alphabet_size);
const DistanceCode = ChannelCode(distance_alphabet_size);

fn emitEntropyCoded(
    writer: *bit_writer.BitWriter,
    tokens: []const lz77.Token,
) Error!void {
    // Histograms over each symbol stream.
    var green_counts: [green_alphabet_size]u32 = .{0} ** green_alphabet_size;
    var red_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var blue_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var alpha_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var distance_counts: [distance_alphabet_size]u32 = .{0} ** distance_alphabet_size;

    for (tokens) |token| {
        switch (token) {
            .literal => |value| {
                green_counts[pixel.green(value)] += 1;
                red_counts[pixel.red(value)] += 1;
                blue_counts[pixel.blue(value)] += 1;
                alpha_counts[pixel.alpha(value)] += 1;
            },
            .copy => |copy| {
                const length_prefix = lz77.prefixForValue(copy.length);
                const green_symbol = literal_alphabet_size + length_prefix.symbol;
                green_counts[green_symbol] += 1;

                const distance_code = lz77.distanceCodeForPixels(copy.distance);
                const distance_prefix = lz77.prefixForValue(distance_code);
                distance_counts[distance_prefix.symbol] += 1;
            },
        }
    }

    // Ensure the distance code is always valid even if there are no copies: a
    // single populated symbol is the minimal valid prefix code.
    if (sumCounts(&distance_counts) == 0) distance_counts[0] = 1;

    var green_code: GreenCode = .{};
    var red_code: LiteralCode = .{};
    var blue_code: LiteralCode = .{};
    var alpha_code: LiteralCode = .{};
    var distance_codes: DistanceCode = .{};

    huffman_writer.build(&green_counts, &green_code.lengths, &green_code.codes);
    huffman_writer.build(&red_counts, &red_code.lengths, &red_code.codes);
    huffman_writer.build(&blue_counts, &blue_code.lengths, &blue_code.codes);
    huffman_writer.build(&alpha_counts, &alpha_code.lengths, &alpha_code.codes);
    huffman_writer.build(&distance_counts, &distance_codes.lengths, &distance_codes.codes);

    // Five prefix codes, in decoder order: green, red, blue, alpha, distance.
    try writeNormalPrefixCode(writer, &green_code.lengths);
    try writeNormalPrefixCode(writer, &red_code.lengths);
    try writeNormalPrefixCode(writer, &blue_code.lengths);
    try writeNormalPrefixCode(writer, &alpha_code.lengths);
    try writeNormalPrefixCode(writer, &distance_codes.lengths);

    const g = green_code.code();
    const r = red_code.code();
    const b = blue_code.code();
    const a = alpha_code.code();
    const d = distance_codes.code();

    for (tokens) |token| {
        switch (token) {
            .literal => |value| {
                try g.writeSymbol(writer, pixel.green(value));
                try r.writeSymbol(writer, pixel.red(value));
                try b.writeSymbol(writer, pixel.blue(value));
                try a.writeSymbol(writer, pixel.alpha(value));
            },
            .copy => |copy| {
                const length_prefix = lz77.prefixForValue(copy.length);
                try g.writeSymbol(writer, literal_alphabet_size + length_prefix.symbol);
                if (length_prefix.extra_bits > 0) {
                    try writer.writeBits(length_prefix.extra_value, length_prefix.extra_bits);
                }

                const distance_code = lz77.distanceCodeForPixels(copy.distance);
                const distance_prefix = lz77.prefixForValue(distance_code);
                try d.writeSymbol(writer, distance_prefix.symbol);
                if (distance_prefix.extra_bits > 0) {
                    try writer.writeBits(distance_prefix.extra_value, distance_prefix.extra_bits);
                }
            },
        }
    }
}

fn sumCounts(counts: []const u32) u64 {
    var total: u64 = 0;
    for (counts) |c| total += c;
    return total;
}

// ---------------------------------------------------------------------------
// Transform record emission.
// ---------------------------------------------------------------------------

fn writeTransformRecord(
    writer: *bit_writer.BitWriter,
    record: TransformRecord,
    dimensions: image.Dimensions,
) Error!void {
    try writer.writeBit(1); // a transform is present
    switch (record) {
        .predictor => |predictor| {
            try writer.writeBits(@intFromEnum(transform.Kind.predictor), 2);
            try writeBlockTransformImage(
                writer,
                dimensions,
                pixel.fromChannels(255, 0, predictor.mode, 0),
            );
        },
        .color => |color| {
            try writer.writeBits(@intFromEnum(transform.Kind.color), 2);
            try writeBlockTransformImage(writer, dimensions, color.element.toPixel());
        },
        .subtract_green => {
            try writer.writeBits(@intFromEnum(transform.Kind.subtract_green), 2);
        },
        .color_indexing => |color_indexing| {
            try writer.writeBits(@intFromEnum(transform.Kind.color_indexing), 2);
            // color_table_size - 1 in 8 bits.
            try writer.writeBits(color_indexing.color_table_size - 1, 8);
            // The palette is a 1 x color_table_size sub-image: encode its
            // delta-coded entries as literals.
            try writeLiteralSubImage(writer, color_indexing.delta_table);
        },
    }
}

/// Emits a predictor/color transform's block sub-image. `block_bits` is the
/// maximum (512-pixel blocks), so the sub-image is `ceil(w/512) x ceil(h/512)`
/// (1x1 for images up to 512x512). Every block pixel carries the same constant
/// `fill`, so the decoder applies one global predictor mode / color element.
fn writeBlockTransformImage(
    writer: *bit_writer.BitWriter,
    dimensions: image.Dimensions,
    fill: pixel.Pixel,
) Error!void {
    const block_bits: u4 = transform.block_bits_max;
    try writer.writeBits(block_bits - transform.block_bits_min, 3);

    const block_size: u32 = @as(u32, 1) << @as(u5, block_bits);
    const sub_width = divRoundUp(dimensions.width, block_size);
    const sub_height = divRoundUp(dimensions.height, block_size);
    const sub_count: usize = @as(usize, sub_width) * @as(usize, sub_height);
    assert(sub_count >= 1);

    // Emit the sub-image as a constant literal stream of `sub_count` copies of
    // `fill` (no allocation: a constant prefix code, then sub_count symbols).
    try writeConstantSubImage(writer, fill, sub_count);
}

/// Emits a transform sub-image whose every pixel equals `value`, using a
/// single-leaf prefix code per channel (the value's channel symbol) so each
/// of `count` pixels costs zero data bits.
fn writeConstantSubImage(
    writer: *bit_writer.BitWriter,
    value: pixel.Pixel,
    count: usize,
) Error!void {
    assert(count >= 1);

    var green_counts: [green_alphabet_size]u32 = .{0} ** green_alphabet_size;
    var red_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var blue_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var alpha_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var distance_counts: [distance_alphabet_size]u32 = .{0} ** distance_alphabet_size;

    green_counts[pixel.green(value)] = @intCast(count);
    red_counts[pixel.red(value)] = @intCast(count);
    blue_counts[pixel.blue(value)] = @intCast(count);
    alpha_counts[pixel.alpha(value)] = @intCast(count);
    distance_counts[0] = 1;

    var green_code: GreenCode = .{};
    var red_code: LiteralCode = .{};
    var blue_code: LiteralCode = .{};
    var alpha_code: LiteralCode = .{};
    var distance_codes: DistanceCode = .{};

    huffman_writer.build(&green_counts, &green_code.lengths, &green_code.codes);
    huffman_writer.build(&red_counts, &red_code.lengths, &red_code.codes);
    huffman_writer.build(&blue_counts, &blue_code.lengths, &blue_code.codes);
    huffman_writer.build(&alpha_counts, &alpha_code.lengths, &alpha_code.codes);
    huffman_writer.build(&distance_counts, &distance_codes.lengths, &distance_codes.codes);

    // A transform sub-image is read with the `.transform` role: the decoder
    // reads a color-cache-present bit (no meta-prefix bit) before the prefix
    // codes. Emit color-cache = 0.
    try writer.writeBit(0);

    try writeNormalPrefixCode(writer, &green_code.lengths);
    try writeNormalPrefixCode(writer, &red_code.lengths);
    try writeNormalPrefixCode(writer, &blue_code.lengths);
    try writeNormalPrefixCode(writer, &alpha_code.lengths);
    try writeNormalPrefixCode(writer, &distance_codes.lengths);

    const g = green_code.code();
    const r = red_code.code();
    const b = blue_code.code();
    const a = alpha_code.code();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try g.writeSymbol(writer, pixel.green(value));
        try r.writeSymbol(writer, pixel.red(value));
        try b.writeSymbol(writer, pixel.blue(value));
        try a.writeSymbol(writer, pixel.alpha(value));
    }
}

/// Emits a small sub-image as a literal stream under per-channel constant
/// prefix codes (every pixel identical). Used for the palette (color-indexing)
/// table and, indirectly, block-transform images.
fn writeLiteralSubImage(
    writer: *bit_writer.BitWriter,
    pixels: []const pixel.Pixel,
) Error!void {
    assert(pixels.len > 0);

    // Build per-channel Huffman codes over just these pixels and emit them.
    var green_counts: [green_alphabet_size]u32 = .{0} ** green_alphabet_size;
    var red_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var blue_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var alpha_counts: [literal_alphabet_size]u32 = .{0} ** literal_alphabet_size;
    var distance_counts: [distance_alphabet_size]u32 = .{0} ** distance_alphabet_size;
    distance_counts[0] = 1;

    for (pixels) |value| {
        green_counts[pixel.green(value)] += 1;
        red_counts[pixel.red(value)] += 1;
        blue_counts[pixel.blue(value)] += 1;
        alpha_counts[pixel.alpha(value)] += 1;
    }

    var green_code: GreenCode = .{};
    var red_code: LiteralCode = .{};
    var blue_code: LiteralCode = .{};
    var alpha_code: LiteralCode = .{};
    var distance_codes: DistanceCode = .{};

    huffman_writer.build(&green_counts, &green_code.lengths, &green_code.codes);
    huffman_writer.build(&red_counts, &red_code.lengths, &red_code.codes);
    huffman_writer.build(&blue_counts, &blue_code.lengths, &blue_code.codes);
    huffman_writer.build(&alpha_counts, &alpha_code.lengths, &alpha_code.codes);
    huffman_writer.build(&distance_counts, &distance_codes.lengths, &distance_codes.codes);

    // A transform sub-image is read with the `.transform` role: a color-cache
    // bit (no meta-prefix bit), then the five prefix codes, then the literals.
    try writer.writeBit(0); // color cache present = 0
    try writeNormalPrefixCode(writer, &green_code.lengths);
    try writeNormalPrefixCode(writer, &red_code.lengths);
    try writeNormalPrefixCode(writer, &blue_code.lengths);
    try writeNormalPrefixCode(writer, &alpha_code.lengths);
    try writeNormalPrefixCode(writer, &distance_codes.lengths);

    const g = green_code.code();
    const r = red_code.code();
    const b = blue_code.code();
    const a = alpha_code.code();
    for (pixels) |value| {
        try g.writeSymbol(writer, pixel.green(value));
        try r.writeSymbol(writer, pixel.red(value));
        try b.writeSymbol(writer, pixel.blue(value));
        try a.writeSymbol(writer, pixel.alpha(value));
    }
}

/// One code-length-code instruction in the normal-form descriptor: either a
/// literal length symbol (0..15) or a repeat code (16/17/18) with extra bits.
const CodeLengthOp = struct {
    symbol: u8,
    extra_bits: u5,
    extra_value: u32,
};

/// Writes one prefix code descriptor, choosing the cheapest of:
///   - the simple form (1 or 2 equal-length symbols), or
///   - the normal form with code-length-code + run-length (16/17/18) packing.
/// Both forms are exactly what `image_data.zig` reads back.
fn writeNormalPrefixCode(writer: *bit_writer.BitWriter, lengths: []const u8) Error!void {
    assert(lengths.len > 0);
    assert(lengths.len <= huffman.green_alphabet_size_max);

    if (trySimpleForm(lengths)) |simple| {
        return writeSimpleForm(writer, simple);
    }
    return writeNormalForm(writer, lengths);
}

const SimpleForm = struct {
    count: u2,
    symbol0: u16,
    symbol1: u16,
};

/// Detects whether the code is expressible in the decoder's simple form: one or
/// two symbols, each with code length exactly 1.
fn trySimpleForm(lengths: []const u8) ?SimpleForm {
    var used: [2]u16 = undefined;
    var count: usize = 0;
    for (lengths, 0..) |l, symbol| {
        if (l == 0) continue;
        if (l != 1) return null; // simple form only encodes length-1 symbols
        if (count == 2) return null;
        // The simple form's symbol field is at most 8 bits, so symbols beyond
        // the literal range (length/cache codes) cannot use it.
        if (symbol > 255) return null;
        used[count] = @intCast(symbol);
        count += 1;
    }
    if (count == 0) return null;
    if (count == 1) return .{ .count = 1, .symbol0 = used[0], .symbol1 = 0 };
    // Two symbols: the reader assigns canonical codes 0 and 1 in symbol order,
    // so emit the smaller symbol first.
    return .{ .count = 2, .symbol0 = used[0], .symbol1 = used[1] };
}

fn writeSimpleForm(writer: *bit_writer.BitWriter, simple: SimpleForm) Error!void {
    try writer.writeBit(1); // simple_code = 1
    try writer.writeBit(@intCast(simple.count - 1)); // num_symbols - 1
    const first_8bits: u1 = if (simple.symbol0 > 1) 1 else 0;
    try writer.writeBit(first_8bits);
    try writer.writeBits(simple.symbol0, if (first_8bits == 1) 8 else 1);
    if (simple.count == 2) {
        try writer.writeBits(simple.symbol1, 8);
    }
}

fn writeNormalForm(writer: *bit_writer.BitWriter, lengths: []const u8) Error!void {
    // Build the code-length-code instruction sequence with run-length packing,
    // mirroring the reader's repeat semantics:
    //   16: repeat previous nonzero length (3 + 2 extra bits, 3..6 times)
    //   17: repeat zero (3 + 3 extra bits, 3..10 times)
    //   18: repeat zero (11 + 7 extra bits, 11..138 times)
    var ops: [huffman.green_alphabet_size_max]CodeLengthOp = undefined;
    var op_count: usize = 0;

    // Emit instructions covering the entire alphabet (no trailing-zero trim),
    // so the full-alphabet selector lets the reader stop on output-full. Long
    // zero tails are compressed by the repeat-18 code below, so the overhead is
    // small while the encode stays simple and unambiguous.
    const emit_count = lengths.len;

    var i: usize = 0;
    while (i < emit_count) {
        const value = lengths[i];
        // Count the run of identical values starting at i.
        var run: usize = 1;
        while (i + run < emit_count and lengths[i + run] == value) run += 1;

        if (value == 0) {
            var remaining = run;
            while (remaining >= 11) {
                const chunk = @min(remaining, 138);
                ops[op_count] = .{ .symbol = 18, .extra_bits = 7, .extra_value = @intCast(chunk - 11) };
                op_count += 1;
                remaining -= chunk;
            }
            while (remaining >= 3) {
                const chunk = @min(remaining, 10);
                ops[op_count] = .{ .symbol = 17, .extra_bits = 3, .extra_value = @intCast(chunk - 3) };
                op_count += 1;
                remaining -= chunk;
            }
            while (remaining > 0) : (remaining -= 1) {
                ops[op_count] = .{ .symbol = 0, .extra_bits = 0, .extra_value = 0 };
                op_count += 1;
            }
        } else {
            // Emit the value once literally, then repeat-previous (16) for the
            // rest of the run. Repeat-16 only applies after a literal of the
            // same nonzero value.
            ops[op_count] = .{ .symbol = value, .extra_bits = 0, .extra_value = 0 };
            op_count += 1;
            var remaining = run - 1;
            while (remaining >= 3) {
                const chunk = @min(remaining, 6);
                ops[op_count] = .{ .symbol = 16, .extra_bits = 2, .extra_value = @intCast(chunk - 3) };
                op_count += 1;
                remaining -= chunk;
            }
            while (remaining > 0) : (remaining -= 1) {
                ops[op_count] = .{ .symbol = value, .extra_bits = 0, .extra_value = 0 };
                op_count += 1;
            }
        }
        i += run;
    }

    // Histogram of code-length-code symbols actually emitted.
    var cl_counts: [code_length_code_count]u32 = .{0} ** code_length_code_count;
    for (ops[0..op_count]) |op| cl_counts[op.symbol] += 1;

    var cl_lengths: [code_length_code_count]u8 = .{0} ** code_length_code_count;
    var cl_codes: [code_length_code_count]u16 = .{0} ** code_length_code_count;
    huffman_writer.buildLimited(
        &cl_counts,
        &cl_lengths,
        &cl_codes,
        huffman.code_length_code_bits_max,
    );

    try writer.writeBit(0); // simple_code = 0 (normal form)

    // num_code_lengths = 4 + N. Trim trailing zero cl-lengths in the fixed
    // order so we send only as many as needed (>= 4).
    var sent: usize = code_length_code_count;
    while (sent > 4 and cl_lengths[huffman.code_length_code_order[sent - 1]] == 0) {
        sent -= 1;
    }
    try writer.writeBits(@intCast(sent - 4), 4);
    var k: usize = 0;
    while (k < sent) : (k += 1) {
        try writer.writeBits(cl_lengths[huffman.code_length_code_order[k]], 3);
    }

    // max_symbol selector: full alphabet (we emit instructions for the whole
    // alphabet, so the reader stops on output-full).
    try writer.writeBit(0);
    assert(emit_count == lengths.len);

    const cl_code = huffman_writer.Code{
        .lengths = &cl_lengths,
        .codes = &cl_codes,
        .single_symbol = huffman_writer.singleSymbol(&cl_lengths),
    };
    for (ops[0..op_count]) |op| {
        try cl_code.writeSymbol(writer, op.symbol);
        if (op.extra_bits > 0) {
            try writer.writeBits(op.extra_value, op.extra_bits);
        }
    }
}

fn divRoundUp(numerator: u32, denominator: u32) u32 {
    assert(numerator > 0);
    assert(denominator > 0);
    return ((numerator - 1) / denominator) + 1;
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

    // Generous transform/entropy scratch for the decoder.
    const transform_pixels = try gpa.alloc(pixel.Pixel, pixel_count + palette_size_max + 16);
    defer gpa.free(transform_pixels);
    const entropy_pixels = try gpa.alloc(pixel.Pixel, pixel_count);
    defer gpa.free(entropy_pixels);

    var buffers = decoder.WorkBuffers{
        .transform_pixels = transform_pixels,
        .entropy_image = entropy_pixels,
    };
    const result = try decoder.decodeARGBAlloc(gpa, encoded, output, &buffers);

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

test "encodes and round-trips a low-color palette image" {
    const width = 32;
    const height = 8;
    const dims = try image.Dimensions.init(width, height);
    const colors = [_]pixel.Pixel{
        pixel.fromChannels(255, 200, 10, 10),
        pixel.fromChannels(255, 10, 200, 10),
        pixel.fromChannels(255, 10, 10, 200),
        pixel.fromChannels(128, 50, 60, 70),
    };
    var pixels: [width * height]pixel.Pixel = undefined;
    for (&pixels, 0..) |*p, i| p.* = colors[i % colors.len];
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encodes and round-trips a two-color (1-bit packed) palette image" {
    const width = 31; // odd width to exercise index packing remainder
    const height = 5;
    const dims = try image.Dimensions.init(width, height);
    const a = pixel.fromChannels(255, 0, 0, 0);
    const b = pixel.fromChannels(255, 255, 255, 255);
    var pixels: [width * height]pixel.Pixel = undefined;
    for (&pixels, 0..) |*p, i| p.* = if ((i * 7 + i / 3) % 3 == 0) a else b;
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encodes and round-trips a repetitive pattern exercising LZ77 copies" {
    const width = 64;
    const height = 16;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height]pixel.Pixel = undefined;
    // A horizontally repeating run of many distinct colors so a palette is not
    // selected and LZ77 finds long matches.
    for (0..height) |y| {
        for (0..width) |x| {
            const t: u8 = @intCast((x % 13) * 19);
            pixels[y * width + x] = pixel.fromChannels(255, t, @intCast((x % 13) * 7), @intCast(y));
        }
    }
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encodes and round-trips a chroma-correlated image favoring color transform" {
    // Red and blue track green strongly, so the color transform decorrelates
    // them; many distinct colors keep the palette path out of the way and the
    // gradient defeats a trivial predictor, so the color transform is chosen.
    const width = 48;
    const height = 40;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height]pixel.Pixel = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const g: u8 = @intCast((x * 5 + y * 3) % 256);
            const r: u8 = @intCast((@as(u32, g) +% (x % 7)) & 0xff);
            const b: u8 = @intCast((@as(u32, g) +% (y % 11)) & 0xff);
            pixels[y * width + x] = pixel.fromChannels(255, r, g, b);
        }
    }
    try decodeRoundTrip(testing.allocator, dims, &pixels);
}

test "encoder applies a color transform on a chroma-correlated image" {
    // White-box check that the color-transform decision path is actually taken
    // (and emitted) for a suitable image, so the round-trip above truly
    // exercises the color transform rather than another path.
    const width = 48;
    const height = 40;
    const dims = try image.Dimensions.init(width, height);
    const pixel_count: usize = @intCast(try dims.pixelCount());
    const pixels = try testing.allocator.alloc(pixel.Pixel, pixel_count);
    defer testing.allocator.free(pixels);
    // Spatially noisy green (so a predictor does not help much) with red and
    // blue tightly tracking green via a fixed linear relation (so the color
    // transform decorrelates them). Many distinct colors keep the palette out.
    var rng: u32 = 0x12345;
    for (pixels) |*p| {
        rng = rng *% 1664525 +% 1013904223;
        const g: u8 = @intCast((rng >> 16) & 0xff);
        const r: u8 = @intCast((rng >> 8) & 0xff);
        // Blue equals red: only the color transform's red->blue multiplier
        // (32 == 1.0 in 3.5 fixed point) can zero this residual; subtract-green
        // cannot (it only subtracts green). So the color transform strictly
        // wins the decorrelation decision.
        const b: u8 = r;
        p.* = pixel.fromChannels(255, r, g, b);
    }

    var plan = try Plan.build(testing.allocator, dims, pixels);
    defer plan.deinit(testing.allocator);

    var saw_color = false;
    for (plan.transforms()) |record| {
        if (record == .color) saw_color = true;
    }
    try testing.expect(saw_color);
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
