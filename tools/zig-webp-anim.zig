const std = @import("std");
const webp = @import("webp");

const skip_exit_code = 3;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3) {
        try std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: zig-webp-anim INPUT.webp OUT_DIR\n" ++
                "Decodes an animated WebP and writes each composited frame as\n" ++
                "OUT_DIR/frame_NNNN.pam (RGBA, zero-based, matching `anim_dump\n" ++
                "-pam`). OUT_DIR must already exist. Exits 3 when the file is\n" ++
                "not an animation.\n",
        );
        std.process.exit(2);
    }

    const input_path = args[1];
    const out_dir = args[2];

    const relaxed = webp.ResourceLimits{
        .output_pixels_max = std.math.maxInt(u32),
        .animation_canvas_pixels_max = std.math.maxInt(u32),
        .allocation_bytes_max = std.math.maxInt(u64),
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        input_path,
        gpa,
        .limited64(relaxed.input_bytes_max),
    );
    defer gpa.free(bytes);

    var animated = webp.decodeAnimation(gpa, bytes, .{
        .limits = relaxed,
        .output_format = .rgba,
    }) catch |err| switch (err) {
        error.NotAnimated => {
            try std.Io.File.stderr().writeStreamingAll(io, "not an animation\n");
            std.process.exit(skip_exit_code);
        },
        else => return err,
    };
    defer animated.deinit();

    const width = animated.info.canvas.width;
    const height = animated.info.canvas.height;
    const header = try std.fmt.allocPrint(
        gpa,
        "P7\nWIDTH {d}\nHEIGHT {d}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n",
        .{ width, height },
    );
    defer gpa.free(header);

    for (animated.frames, 0..) |frame, index| {
        const path = try std.fmt.allocPrint(gpa, "{s}/frame_{d:0>4}.pam", .{ out_dir, index });
        defer gpa.free(path);

        const pam = try gpa.alloc(u8, header.len + frame.buffer.pixels.len);
        defer gpa.free(pam);
        @memcpy(pam[0..header.len], header);
        @memcpy(pam[header.len..], frame.buffer.pixels);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = pam });
    }

    const summary = try std.fmt.allocPrint(
        gpa,
        "frames {d}\n",
        .{animated.frames.len},
    );
    defer gpa.free(summary);
    try std.Io.File.stdout().writeStreamingAll(io, summary);
}
