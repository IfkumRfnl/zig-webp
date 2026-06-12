const std = @import("std");
const webp = @import("webp");

const no_alpha_exit_code = 3;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        try std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: zig-webp-alpha INPUT.webp OUTPUT.raw\n" ++
                "Writes the decoded ALPH plane as row-major bytes.\n" ++
                "Exits 3 when the file has no static ALPH chunk.\n",
        );
        std.process.exit(2);
    }

    const input_path = args[1];
    const output_path = args[2];

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        input_path,
        gpa,
        .limited64((webp.ResourceLimits{}).input_bytes_max),
    );
    defer gpa.free(bytes);

    // Match the corpus demux limits so oversized no-alpha files still parse
    // far enough to be reported as skips instead of failures.
    var parsed = try webp.parseWebP(gpa, bytes, .{
        .limits = .{
            .output_pixels_max = std.math.maxInt(u32),
            .animation_canvas_pixels_max = std.math.maxInt(u32),
        },
    });
    defer parsed.deinit();

    const location = parsed.features.alpha orelse {
        try std.Io.File.stderr().writeStreamingAll(io, "no static ALPH chunk\n");
        std.process.exit(no_alpha_exit_code);
    };
    const dimensions = parsed.features.canvas;
    const pixel_count: usize = @intCast(try dimensions.pixelCount());

    const plane = try gpa.alloc(u8, pixel_count);
    defer gpa.free(plane);

    _ = try webp.alpha.decodePlaneAlloc(gpa, location.payload(bytes), dimensions, plane);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = plane,
    });
}
