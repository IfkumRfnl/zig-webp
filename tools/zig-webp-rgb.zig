const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const skip_exit_code = 3;

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    const parsed_args = cli.parseNoFilterTwoPaths(
        ctx,
        "usage: zig-webp-rgb [--nofilter] INPUT.webp OUTPUT.pam\n" ++
            "Decodes a static lossy WebP to RGBA via fancy chroma upsampling\n" ++
            "and writes a PAM file, matching `dwebp -pam`. A decoded ALPH\n" ++
            "plane, if present, is composed into the alpha channel. Pass\n" ++
            "--nofilter to skip the in-loop deblocking filter (matches\n" ++
            "`dwebp -nofilter`). Exits 3 when the file is not a static lossy\n" ++
            "image.\n",
    );

    const input_path = parsed_args.input_path;
    const output_path = parsed_args.output_path;

    const bytes = try ctx.readInput(input_path);
    defer ctx.gpa.free(bytes);

    var parsed = try webp.parseWebP(ctx.gpa, bytes, .{
        .limits = .{
            .output_pixels_max = std.math.maxInt(u32),
            .animation_canvas_pixels_max = std.math.maxInt(u32),
        },
    });
    defer parsed.deinit();

    const skip = parsed.features.is_animation or
        (parsed.features.format orelse .lossless) != .lossy;
    if (skip) {
        ctx.exitWithMessage("not a static lossy image\n", skip_exit_code);
    }
    const image_chunk = parsed.features.image_data orelse {
        ctx.exitWithMessage("missing VP8 chunk\n", skip_exit_code);
    };

    var frame = try webp.vp8_decoder.decodeFrame(ctx.gpa, image_chunk.payload(bytes), .{
        .apply_loop_filter = !parsed_args.nofilter,
    });
    defer frame.deinit();

    const channels = 4;
    const row_bytes = @as(usize, frame.width) * channels;
    const rgba = try ctx.gpa.alloc(u8, row_bytes * @as(usize, frame.height));
    defer ctx.gpa.free(rgba);

    webp.color.upsampleFancy(.rgba, .{
        .luma = frame.luma,
        .chroma_u = frame.chroma_u,
        .chroma_v = frame.chroma_v,
        .luma_stride = frame.luma_stride,
        .chroma_stride = frame.chroma_stride,
        .width = frame.width,
        .height = frame.height,
    }, rgba, row_bytes);

    // Compose the decoded ALPH plane over the opaque alpha `upsampleFancy`
    // wrote, so the output matches `dwebp -pam`'s composited RGBA.
    if (parsed.features.alpha) |location| {
        const pixel_count = @as(usize, frame.width) * @as(usize, frame.height);
        const alpha_plane = try ctx.gpa.alloc(u8, pixel_count);
        defer ctx.gpa.free(alpha_plane);
        _ = try webp.alpha.decodePlaneAlloc(
            ctx.gpa,
            location.payload(bytes),
            parsed.features.canvas,
            alpha_plane,
        );
        for (alpha_plane, 0..) |sample, i| rgba[i * channels + 3] = sample;
    }

    const header = try cli.pamHeaderRgbaAlloc(ctx.gpa, frame.width, frame.height);
    defer ctx.gpa.free(header);

    const pam = try cli.pamConcatAlloc(ctx.gpa, header, rgba);
    defer ctx.gpa.free(pam);

    try ctx.writeOutput(output_path, pam);
}
