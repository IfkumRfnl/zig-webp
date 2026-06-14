const std = @import("std");
const webp = @import("webp");

const not_lossy_exit_code = 3;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var nofilter = false;
    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--nofilter")) {
            nofilter = true;
        } else if (positional_count < 2) {
            positional[positional_count] = arg;
            positional_count += 1;
        } else {
            positional_count = 3;
            break;
        }
    }
    if (positional_count != 2) {
        try std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: zig-webp-yuv [--nofilter] INPUT.webp OUTPUT.raw\n" ++
                "Writes decoded Y, U, V planes (cropped, tightly packed) like\n" ++
                "`dwebp -yuv` without the appended alpha plane. Pass --nofilter\n" ++
                "to skip the in-loop deblocking filter (matches `dwebp -nofilter`).\n" ++
                "Exits 3 when the file is not a static lossy image.\n",
        );
        std.process.exit(2);
    }

    const input_path = positional[0];
    const output_path = positional[1];

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        input_path,
        gpa,
        .limited64((webp.ResourceLimits{}).input_bytes_max),
    );
    defer gpa.free(bytes);

    var parsed = try webp.parseWebP(gpa, bytes, .{
        .limits = .{
            .output_pixels_max = std.math.maxInt(u32),
            .animation_canvas_pixels_max = std.math.maxInt(u32),
        },
    });
    defer parsed.deinit();

    const skip = parsed.features.is_animation or
        (parsed.features.format orelse .lossless) != .lossy;
    if (skip) {
        try std.Io.File.stderr().writeStreamingAll(io, "not a static lossy image\n");
        std.process.exit(not_lossy_exit_code);
    }
    const image_chunk = parsed.features.image_data orelse {
        try std.Io.File.stderr().writeStreamingAll(io, "missing VP8 chunk\n");
        std.process.exit(not_lossy_exit_code);
    };

    var frame = try webp.vp8_decoder.decodeFrame(gpa, image_chunk.payload(bytes), .{
        .apply_loop_filter = !nofilter,
    });
    defer frame.deinit();

    const chroma_width = frame.chromaWidth();
    const chroma_height = frame.chromaHeight();
    const total = @as(usize, frame.width) * frame.height +
        2 * @as(usize, chroma_width) * chroma_height;
    const output = try gpa.alloc(u8, total);
    defer gpa.free(output);

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

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = output,
    });
}
