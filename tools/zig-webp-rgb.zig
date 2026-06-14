const std = @import("std");
const webp = @import("webp");

const skip_exit_code = 3;

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
            "usage: zig-webp-rgb [--nofilter] INPUT.webp OUTPUT.pam\n" ++
                "Decodes a static lossy WebP to RGBA via fancy chroma upsampling\n" ++
                "and writes a PAM file, matching `dwebp -pam`. Pass --nofilter to\n" ++
                "skip the in-loop deblocking filter (matches `dwebp -nofilter`).\n" ++
                "Exits 3 when the file is not a static lossy image, or carries\n" ++
                "alpha (alpha composition is a separate stage).\n",
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

    // Alpha-bearing lossy files would need the (not-yet-implemented) alpha
    // composition pass to match `dwebp -pam`'s composited output, so skip them
    // here just like non-lossy inputs.
    const skip = parsed.features.is_animation or
        (parsed.features.format orelse .lossless) != .lossy or
        parsed.features.has_alpha;
    if (skip) {
        try std.Io.File.stderr().writeStreamingAll(io, "not a static lossy image without alpha\n");
        std.process.exit(skip_exit_code);
    }
    const image_chunk = parsed.features.image_data orelse {
        try std.Io.File.stderr().writeStreamingAll(io, "missing VP8 chunk\n");
        std.process.exit(skip_exit_code);
    };

    var frame = try webp.vp8_decoder.decodeFrame(gpa, image_chunk.payload(bytes), .{
        .apply_loop_filter = !nofilter,
    });
    defer frame.deinit();

    const channels = 4;
    const row_bytes = @as(usize, frame.width) * channels;
    const rgba = try gpa.alloc(u8, row_bytes * @as(usize, frame.height));
    defer gpa.free(rgba);

    webp.color.upsampleFancy(.rgba, .{
        .luma = frame.luma,
        .chroma_u = frame.chroma_u,
        .chroma_v = frame.chroma_v,
        .luma_stride = frame.luma_stride,
        .chroma_stride = frame.chroma_stride,
        .width = frame.width,
        .height = frame.height,
    }, rgba, row_bytes);

    const header = try std.fmt.allocPrint(
        gpa,
        "P7\nWIDTH {d}\nHEIGHT {d}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n",
        .{ frame.width, frame.height },
    );
    defer gpa.free(header);

    const pam = try gpa.alloc(u8, header.len + rgba.len);
    defer gpa.free(pam);
    @memcpy(pam[0..header.len], header);
    @memcpy(pam[header.len..], rgba);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = pam,
    });
}
