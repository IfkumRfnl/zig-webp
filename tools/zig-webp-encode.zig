//! Re-encodes a still WebP source as a lossy (VP8) WebP using the step 8a
//! baseline encoder. The input is decoded to RGBA, then encoded at the given
//! quality. Intended for the `compare-encode-lossy` oracle, which feeds the
//! output to `dwebp` to confirm libwebp accepts it.
//!
//! Usage: zig-webp-encode INPUT.webp OUTPUT.webp [QUALITY]
//! QUALITY is 0..100 (default 75).

const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const usage_text =
    "usage: zig-webp-encode INPUT.webp OUTPUT.webp [QUALITY]\n" ++
    "Decodes a still WebP and re-encodes it as a lossy (VP8) WebP with the\n" ++
    "step 8a baseline encoder. QUALITY is 0..100 (default 75).\n";

// Trusted local fixtures: relax the per-image limits to admit large canvases.
const tool_limits = webp.ResourceLimits{
    .output_pixels_max = std.math.maxInt(u32),
    .allocation_bytes_max = std.math.maxInt(u64),
    .animation_canvas_pixels_max = std.math.maxInt(u32),
};

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len < 3 or ctx.args.len > 4) ctx.usageError(usage_text);

    const input_path = ctx.args[1];
    const output_path = ctx.args[2];
    const quality: u8 = if (ctx.args.len == 4)
        (std.fmt.parseInt(u8, ctx.args[3], 10) catch ctx.usageError(usage_text))
    else
        75;

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
        .limits = tool_limits,
    });
    defer ctx.gpa.free(encoded);

    try ctx.writeOutput(output_path, encoded);
}
