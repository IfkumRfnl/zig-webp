//! Re-encodes a still WebP source as a lossy (VP8) WebP using the step 8a
//! baseline encoder. The input is decoded to RGBA, then encoded at the given
//! quality. Intended for the `compare-encode-lossy` oracle, which feeds the
//! output to `dwebp` to confirm libwebp accepts it.
//!
//! Usage: zig-webp-encode INPUT.webp OUTPUT.webp [QUALITY] [-sharp]
//! QUALITY is 0..100 (default 75). `-sharp` selects the sharp (iterative)
//! RGB->YUV chroma downsampling instead of the default box average.

const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const usage_text =
    "usage: zig-webp-encode INPUT.webp OUTPUT.webp [QUALITY] [-sharp]\n" ++
    "Decodes a still WebP and re-encodes it as a lossy (VP8) WebP with the\n" ++
    "step 8a baseline encoder. QUALITY is 0..100 (default 75). Pass -sharp to\n" ++
    "use the sharp (iterative) RGB->YUV chroma downsampling.\n";

// Trusted local fixtures: relax the per-image limits to admit large canvases.
const tool_limits = webp.ResourceLimits{
    .output_pixels_max = std.math.maxInt(u32),
    .allocation_bytes_max = std.math.maxInt(u64),
    .animation_canvas_pixels_max = std.math.maxInt(u32),
};

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len < 3) ctx.usageError(usage_text);

    const input_path = ctx.args[1];
    const output_path = ctx.args[2];

    // Optional trailing flags after the two paths: a quality integer and/or
    // `-sharp`, in any order.
    var quality: u8 = 75;
    var use_sharp_yuv = false;
    for (ctx.args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "-sharp")) {
            use_sharp_yuv = true;
        } else {
            quality = std.fmt.parseInt(u8, arg, 10) catch ctx.usageError(usage_text);
        }
    }

    const bytes = try ctx.readInput(input_path);
    defer ctx.gpa.free(bytes);

    var source = try webp.decodeStatic(ctx.gpa, bytes, .{
        .output_format = .rgba,
        .limits = tool_limits,
    });
    defer source.deinit();

    const encoded = try webp.encodeLossy(ctx.gpa, source.buffer, .{
        .format = .lossy,
        .quality = quality,
        .use_sharp_yuv = use_sharp_yuv,
        .limits = tool_limits,
    });
    defer ctx.gpa.free(encoded);

    try ctx.writeOutput(output_path, encoded);
}
