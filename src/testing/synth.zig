//! Deterministic synthetic source images for the encode test harness.
//!
//! These are the *input* side of encoder testing: clean pixel buffers that the
//! encoder consumes, as opposed to the decode corpus (WebP files we decode).
//! They are generated at test time so they cost nothing in the repository and
//! stay fully reproducible.
//!
//! The set is curated to cross three axes that exercise distinct encoder code
//! paths:
//!
//! - Dimensions, with emphasis on VP8 macroblock geometry (luma 16x16, chroma
//!   8x8): exact multiples, one pixel over/under a macroblock, asymmetric
//!   partials, primes, 1xN/Nx1 strips, and a few larger canvases.
//! - Content: flat, smooth gradient, high-frequency checker, saturated bars,
//!   deterministic noise, radial, neutral-chroma ramp, and a hard two-tone
//!   edge.
//! - Alpha: opaque, an alpha ramp, binary alpha, and fully-transparent pixels
//!   carrying non-zero RGB (the case PLAN.MD step 8a calls "exact
//!   transparent-RGB handling", and which lossless encode must preserve).
//!
//! Every content generator is a pure function of (x, y, width, height), so the
//! output depends only on the `Source` description.

const std = @import("std");

const image = @import("../image.zig");

pub const Content = enum {
    flat,
    gradient,
    checker,
    bars,
    noise,
    radial,
    grayscale_ramp,
    two_tone,
    alpha_gradient,
    alpha_checker,
    alpha_transparent_rgb,
};

pub const Source = struct {
    name: []const u8,
    width: u32,
    height: u32,
    format: image.PixelFormat,
    content: Content,
};

/// The curated source set. Each entry's name encodes content, dimensions, and
/// pixel format so it reads clearly in test output and the encode report.
pub const sources = [_]Source{
    // Degenerate and tiny dimensions: exercise edge handling and the smallest
    // possible canvases.
    .{ .name = "flat_1x1_rgb", .width = 1, .height = 1, .format = .rgb, .content = .flat },
    .{ .name = "gradient_1x1_rgba", .width = 1, .height = 1, .format = .rgba, .content = .gradient },
    .{ .name = "gradient_1x17_rgb", .width = 1, .height = 17, .format = .rgb, .content = .gradient },
    .{ .name = "bars_17x1_rgb", .width = 17, .height = 1, .format = .rgb, .content = .bars },
    .{ .name = "checker_7x7_rgb", .width = 7, .height = 7, .format = .rgb, .content = .checker },
    .{ .name = "alpha_transparent_5x5_rgba", .width = 5, .height = 5, .format = .rgba, .content = .alpha_transparent_rgb },

    // Macroblock-boundary dimensions: 16 exact, 17 one-over, 15 one-under, and
    // asymmetric partials. These stress partial macroblocks and chroma
    // (8x8) rounding.
    .{ .name = "gradient_16x16_rgb", .width = 16, .height = 16, .format = .rgb, .content = .gradient },
    .{ .name = "checker_16x16_rgb", .width = 16, .height = 16, .format = .rgb, .content = .checker },
    .{ .name = "gradient_17x17_rgb", .width = 17, .height = 17, .format = .rgb, .content = .gradient },
    .{ .name = "checker_17x17_rgba", .width = 17, .height = 17, .format = .rgba, .content = .checker },
    .{ .name = "bars_15x15_rgb", .width = 15, .height = 15, .format = .rgb, .content = .bars },
    .{ .name = "gradient_16x17_rgb", .width = 16, .height = 17, .format = .rgb, .content = .gradient },
    .{ .name = "noise_17x16_rgb", .width = 17, .height = 16, .format = .rgb, .content = .noise },
    .{ .name = "grayscale_ramp_16x16_rgb", .width = 16, .height = 16, .format = .rgb, .content = .grayscale_ramp },

    // Odd and medium canvases, prime dimensions, mixed content and alpha.
    .{ .name = "noise_23x31_rgb", .width = 23, .height = 31, .format = .rgb, .content = .noise },
    .{ .name = "radial_32x32_rgb", .width = 32, .height = 32, .format = .rgb, .content = .radial },
    .{ .name = "two_tone_31x17_rgb", .width = 31, .height = 17, .format = .rgb, .content = .two_tone },
    .{ .name = "alpha_gradient_32x32_rgba", .width = 32, .height = 32, .format = .rgba, .content = .alpha_gradient },
    .{ .name = "alpha_checker_33x33_rgba", .width = 33, .height = 33, .format = .rgba, .content = .alpha_checker },
    .{ .name = "gradient_64x48_rgb", .width = 64, .height = 48, .format = .rgb, .content = .gradient },
    .{ .name = "bars_64x48_rgb", .width = 64, .height = 48, .format = .rgb, .content = .bars },
    .{ .name = "flat_40x40_rgba", .width = 40, .height = 40, .format = .rgba, .content = .flat },

    // 1xN / Nx1 strips.
    .{ .name = "gradient_100x1_rgb", .width = 100, .height = 1, .format = .rgb, .content = .gradient },
    .{ .name = "bars_1x100_rgb", .width = 1, .height = 100, .format = .rgb, .content = .bars },

    // Larger and odd canvases for more realistic entropy and transform work.
    .{ .name = "noise_129x97_rgb", .width = 129, .height = 97, .format = .rgb, .content = .noise },
    .{ .name = "radial_128x128_rgb", .width = 128, .height = 128, .format = .rgb, .content = .radial },
    .{ .name = "gradient_256x256_rgb", .width = 256, .height = 256, .format = .rgb, .content = .gradient },
    .{ .name = "alpha_transparent_64x64_rgba", .width = 64, .height = 64, .format = .rgba, .content = .alpha_transparent_rgb },
    .{ .name = "checker_128x128_rgba", .width = 128, .height = 128, .format = .rgba, .content = .checker },
    .{ .name = "grayscale_ramp_200x60_rgb", .width = 200, .height = 60, .format = .rgb, .content = .grayscale_ramp },
};

/// A rendered source: the owned pixel bytes plus a borrowing `image.Buffer`.
pub const Rendered = struct {
    gpa: std.mem.Allocator,
    pixels: []u8,
    buffer: image.Buffer,

    pub fn deinit(self: Rendered) void {
        self.gpa.free(self.pixels);
    }
};

/// Renders a source into a freshly allocated, tightly packed pixel buffer.
/// The returned `Rendered.buffer` borrows `Rendered.pixels`; free with
/// `Rendered.deinit`.
pub fn render(gpa: std.mem.Allocator, source: Source) !Rendered {
    const dimensions = try image.Dimensions.init(source.width, source.height);
    const channels: usize = @intCast(source.format.channelCount());
    const width: usize = source.width;
    const height: usize = source.height;
    const stride = width * channels;

    const pixels = try gpa.alloc(u8, stride * height);
    errdefer gpa.free(pixels);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const rgba = fillPixel(source.content, @intCast(x), @intCast(y), source.width, source.height);
            const base = y * stride + x * channels;
            packPixel(source.format, rgba, pixels[base..][0..channels]);
        }
    }

    return .{
        .gpa = gpa,
        .pixels = pixels,
        .buffer = .{
            .pixels = pixels,
            .dimensions = dimensions,
            .stride = @intCast(stride),
            .format = source.format,
        },
    };
}

/// Writes an RGBA sample into `out` in the destination format's channel order.
fn packPixel(format: image.PixelFormat, rgba: [4]u8, out: []u8) void {
    switch (format) {
        .rgb => {
            out[0] = rgba[0];
            out[1] = rgba[1];
            out[2] = rgba[2];
        },
        .rgba => {
            out[0] = rgba[0];
            out[1] = rgba[1];
            out[2] = rgba[2];
            out[3] = rgba[3];
        },
        .bgra => {
            out[0] = rgba[2];
            out[1] = rgba[1];
            out[2] = rgba[0];
            out[3] = rgba[3];
        },
        .argb => {
            out[0] = rgba[3];
            out[1] = rgba[0];
            out[2] = rgba[1];
            out[3] = rgba[2];
        },
    }
}

/// Linearly maps coordinate `i` in `[0, n)` to `[0, 255]`; midpoint for n == 1.
fn ramp(i: u32, n: u32) u8 {
    if (n <= 1) return 128;
    return @intCast((@as(u32, i) * 255) / (n - 1));
}

/// Deterministic per-coordinate hash (integer avalanche); no global state.
fn hashXY(x: u32, y: u32, salt: u32) u32 {
    var h: u32 = x *% 374761393 +% y *% 668265263 +% salt *% 2246822519;
    h = (h ^ (h >> 13)) *% 1274126177;
    return h ^ (h >> 16);
}

/// The content matrix: a pure function of position and canvas size returning a
/// non-premultiplied RGBA sample.
fn fillPixel(content: Content, x: u32, y: u32, w: u32, h: u32) [4]u8 {
    return switch (content) {
        .flat => .{ 58, 157, 200, 255 },
        .gradient => blk: {
            const r = ramp(x, w);
            const g = ramp(y, h);
            const b: u8 = @intCast((@as(u32, r) + @as(u32, g)) / 2);
            break :blk .{ r, g, b, 255 };
        },
        .checker => if ((x ^ y) & 1 == 0)
            .{ 220, 30, 30, 255 }
        else
            .{ 30, 30, 220, 255 },
        .bars => blk: {
            const palette = [_][3]u8{
                .{ 230, 20, 20 },  .{ 20, 200, 20 },  .{ 20, 20, 230 },   .{ 20, 200, 200 },
                .{ 220, 20, 220 }, .{ 220, 220, 20 }, .{ 240, 240, 240 }, .{ 10, 10, 10 },
            };
            const bar_w = @max(1, w / 8);
            const c = palette[(x / bar_w) % palette.len];
            break :blk .{ c[0], c[1], c[2], 255 };
        },
        .noise => blk: {
            const hv = hashXY(x, y, 0x9e3779b9);
            break :blk .{
                @truncate(hv),
                @truncate(hv >> 8),
                @truncate(hv >> 16),
                255,
            };
        },
        .radial => blk: {
            const cx = @as(i64, w) - 1;
            const cy = @as(i64, h) - 1;
            const dx = 2 * @as(i64, x) - cx;
            const dy = 2 * @as(i64, y) - cy;
            const dist2: u64 = @intCast(dx * dx + dy * dy);
            const max2: u64 = @intCast(cx * cx + cy * cy + 1);
            const r: u8 = @intCast((dist2 * 255) / max2);
            break :blk .{ r, 128, 255 - r, 255 };
        },
        .grayscale_ramp => blk: {
            const v = ramp(x, w);
            break :blk .{ v, v, v, 255 };
        },
        .two_tone => if (x < w / 2)
            .{ 200, 40, 40, 255 }
        else
            .{ 40, 40, 200, 255 },
        .alpha_gradient => .{ 120, 180, 90, ramp(x, w) },
        .alpha_checker => .{ 200, 120, 40, if ((x ^ y) & 1 == 0) 255 else 0 },
        // Fully transparent, but RGB still carries a gradient so a round-trip
        // must preserve the colour under a zero alpha.
        .alpha_transparent_rgb => .{ ramp(x, w), ramp(y, h), 128, 0 },
    };
}

const testing = std.testing;

test "every source renders to a validatable, correctly sized buffer" {
    for (sources) |source| {
        const rendered = try render(testing.allocator, source);
        defer rendered.deinit();

        try rendered.buffer.validate();
        const channels: usize = @intCast(source.format.channelCount());
        try testing.expectEqual(@as(usize, source.width) * source.height * channels, rendered.pixels.len);
        try testing.expectEqual(source.width, rendered.buffer.dimensions.width);
        try testing.expectEqual(source.height, rendered.buffer.dimensions.height);
    }
}

test "rendering is deterministic" {
    for (sources) |source| {
        const a = try render(testing.allocator, source);
        defer a.deinit();
        const b = try render(testing.allocator, source);
        defer b.deinit();
        try testing.expectEqualSlices(u8, a.pixels, b.pixels);
    }
}

test "source names are unique" {
    for (sources, 0..) |a, i| {
        for (sources[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "fully-transparent source carries zero alpha over non-zero RGB" {
    const source = Source{
        .name = "t",
        .width = 4,
        .height = 4,
        .format = .rgba,
        .content = .alpha_transparent_rgb,
    };
    const rendered = try render(testing.allocator, source);
    defer rendered.deinit();

    var saw_nonzero_rgb = false;
    var i: usize = 0;
    while (i < rendered.pixels.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 0), rendered.pixels[i + 3]); // alpha == 0
        if (rendered.pixels[i] != 0 or rendered.pixels[i + 1] != 0) saw_nonzero_rgb = true;
    }
    try testing.expect(saw_nonzero_rgb);
}

test "checker is high-frequency: adjacent pixels differ" {
    const source = Source{
        .name = "c",
        .width = 4,
        .height = 1,
        .format = .rgb,
        .content = .checker,
    };
    const rendered = try render(testing.allocator, source);
    defer rendered.deinit();

    // Pixels 0 and 1 must differ (the whole point of the checker).
    try testing.expect(!std.mem.eql(u8, rendered.pixels[0..3], rendered.pixels[3..6]));
}
