const std = @import("std");
const webp = @import("webp");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        try std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: zig-webp-decode INPUT.webp OUTPUT.pam\n",
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

    var decoded = try webp.decodeStatic(gpa, bytes, .{ .output_format = .rgba });
    defer decoded.deinit();

    const pam = try encodePam(gpa, decoded.buffer);
    defer gpa.free(pam);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = pam,
    });
}

fn encodePam(gpa: std.mem.Allocator, buffer: webp.ImageBuffer) ![]u8 {
    try buffer.validate();
    std.debug.assert(buffer.format == .rgba);

    const header = try std.fmt.allocPrint(
        gpa,
        "P7\nWIDTH {d}\nHEIGHT {d}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n",
        .{
            buffer.dimensions.width,
            buffer.dimensions.height,
        },
    );
    defer gpa.free(header);

    const pam = try gpa.alloc(u8, header.len + buffer.pixels.len);
    @memcpy(pam[0..header.len], header);
    @memcpy(pam[header.len..], buffer.pixels);

    return pam;
}
