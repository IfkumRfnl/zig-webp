const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const not_lossy_exit_code = 3;

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    const parsed_args = cli.parseNoFilterTwoPaths(
        ctx,
        "usage: zig-webp-yuv [--nofilter] INPUT.webp OUTPUT.raw\n" ++
            "Writes decoded Y, U, V planes (cropped, tightly packed) like\n" ++
            "`dwebp -yuv` without the appended alpha plane. Pass --nofilter\n" ++
            "to skip the in-loop deblocking filter (matches `dwebp -nofilter`).\n" ++
            "Exits 3 when the file is not a static lossy image.\n",
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
        ctx.exitWithMessage("not a static lossy image\n", not_lossy_exit_code);
    }
    const image_chunk = parsed.features.image_data orelse {
        ctx.exitWithMessage("missing VP8 chunk\n", not_lossy_exit_code);
    };

    var frame = try webp.vp8_decoder.decodeFrame(ctx.gpa, image_chunk.payload(bytes), .{
        .apply_loop_filter = !parsed_args.nofilter,
    });
    defer frame.deinit();

    const chroma_width = frame.chromaWidth();
    const chroma_height = frame.chromaHeight();
    const total = @as(usize, frame.width) * frame.height +
        2 * @as(usize, chroma_width) * chroma_height;
    const output = try ctx.gpa.alloc(u8, total);
    defer ctx.gpa.free(output);

    var offset: usize = 0;
    for (0..frame.height) |row| {
        @memcpy(
            output[offset..][0..frame.width],
            frame.luma[row * frame.luma_stride ..][0..frame.width],
        );
        offset += frame.width;
    }
    for ([2][]const u8{ frame.chroma_u, frame.chroma_v }) |plane| {
        for (0..chroma_height) |row| {
            @memcpy(
                output[offset..][0..chroma_width],
                plane[row * frame.chroma_stride ..][0..chroma_width],
            );
            offset += chroma_width;
        }
    }
    std.debug.assert(offset == total);

    try ctx.writeOutput(output_path, output);
}
