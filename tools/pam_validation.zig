//! Pixel-exact oracle validation for the benchmark's 8-bit RGB/RGBA PAM files.
//! PAM layout: https://netpbm.sourceforge.net/doc/pam.html
const std = @import("std");

const Header = struct {
    width: u32,
    height: u32,
    depth: u32,
    payload: []const u8,
};

fn parseHeader(pam: []const u8) !Header {
    if (!std.mem.startsWith(u8, pam, "P7\n")) return error.InvalidPam;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var depth: ?u32 = null;
    var maxval: ?u32 = null;
    var tuple_type: ?[]const u8 = null;
    var offset: usize = 3;
    while (offset < pam.len) {
        const length = std.mem.indexOfScalar(u8, pam[offset..], '\n') orelse
            return error.InvalidPam;
        const line = std.mem.trim(u8, pam[offset..][0..length], " \t\r\x0b\x0c");
        offset += length + 1;
        if (line.len == 0 or line[0] == '#') continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r\x0b\x0c");
        const key = tokens.next().?;
        if (std.mem.eql(u8, key, "ENDHDR")) {
            if (tokens.next() != null) return error.InvalidPam;
            const w = width orelse return error.InvalidPam;
            const h = height orelse return error.InvalidPam;
            const d = depth orelse return error.InvalidPam;
            if (maxval != 255) return error.InvalidPam;
            // Untyped and other PAM subformats do not establish RGB semantics.
            const tuple = tuple_type orelse return error.InvalidPam;
            const expected_tuple = switch (d) {
                3 => "RGB",
                4 => "RGB_ALPHA",
                else => return error.InvalidPam,
            };
            if (!std.mem.eql(u8, tuple, expected_tuple)) return error.InvalidPam;
            return .{ .width = w, .height = h, .depth = d, .payload = pam[offset..] };
        }
        const value = tokens.next() orelse return error.InvalidPam;
        if (tokens.next() != null) return error.InvalidPam;
        if (std.mem.eql(u8, key, "TUPLTYPE")) {
            // Multiple tuple lines concatenate with spaces, so cannot name
            // either supported single-word tuple type.
            if (tuple_type != null) return error.InvalidPam;
            tuple_type = value;
        } else {
            const field = if (std.mem.eql(u8, key, "WIDTH"))
                &width
            else if (std.mem.eql(u8, key, "HEIGHT"))
                &height
            else if (std.mem.eql(u8, key, "DEPTH"))
                &depth
            else if (std.mem.eql(u8, key, "MAXVAL"))
                &maxval
            else
                return error.InvalidPam;
            if (field.* != null) return error.InvalidPam;
            for (value) |byte| {
                if (!std.ascii.isDigit(byte)) return error.InvalidPam;
            }
            const number = std.fmt.parseInt(u32, value, 10) catch return error.InvalidPam;
            if (number == 0) return error.InvalidPam;
            field.* = number;
        }
    }
    return error.InvalidPam;
}

pub fn validate(pixels: []const u8, width: u32, height: u32, pam: []const u8) !void {
    const header = try parseHeader(pam);
    if (header.width != width or header.height != height) return error.RoundTripMismatch;
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidPam;
    const raw_size = std.math.mul(usize, pixel_count, 4) catch return error.InvalidPam;
    if (pixels.len != raw_size) return error.InvalidRaw;
    const payload_size = std.math.mul(usize, pixel_count, header.depth) catch
        return error.InvalidPam;
    if (header.payload.len != payload_size) return error.InvalidPam;
    if (header.depth == 4) {
        if (!std.mem.eql(u8, header.payload, pixels)) return error.RoundTripMismatch;
    } else {
        for (0..pixel_count) |index| {
            if (!std.mem.eql(u8, header.payload[index * 3 ..][0..3], pixels[index * 4 ..][0..3])) {
                return error.RoundTripMismatch;
            }
            if (pixels[index * 4 + 3] != 255) return error.RoundTripMismatch;
        }
    }
}

const opaque_pixels = "\xff\x00\x00\xff\x00\xff\x00\xff";
const rgb_pixels = "\xff\x00\x00\x00\xff\x00";
const rgb_format = "DEPTH 3\nMAXVAL 255\nTUPLTYPE RGB\nENDHDR\n";
const rgba_format = "DEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n";

test "RGB and RGBA validation preserves image geometry" {
    try validate(opaque_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n" ++ rgb_format ++ rgb_pixels);
    try validate(opaque_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n" ++ rgba_format ++ opaque_pixels);
    try validate(opaque_pixels, 1, 2, "P7\nWIDTH 1\nHEIGHT 2\n" ++ rgb_format ++ rgb_pixels);
    try validate(opaque_pixels, 1, 2, "P7\nWIDTH 1\nHEIGHT 2\n" ++ rgba_format ++ opaque_pixels);
    try std.testing.expectError(error.RoundTripMismatch, validate(
        opaque_pixels,
        2,
        1,
        "P7\nWIDTH 1\nHEIGHT 2\n" ++ rgb_format ++ rgb_pixels,
    ));
    try std.testing.expectError(error.RoundTripMismatch, validate(
        opaque_pixels,
        2,
        1,
        "P7\nWIDTH 1\nHEIGHT 2\n" ++ rgba_format ++ opaque_pixels,
    ));
}

test "PAM fields support reordering whitespace and comments" {
    try validate(opaque_pixels, 2, 1, "P7\n# ENDHDR and DEPTH 4 are only a comment\n\n" ++
        " TUPLTYPE\tRGB \nMAXVAL 255\n HEIGHT\t1\nDEPTH 3\nWIDTH 02\nENDHDR\n" ++ rgb_pixels);
}

test "PAM oracle requires explicit matching 8-bit RGB tuple semantics" {
    const formats = [_][]const u8{
        "DEPTH 3\nMAXVAL 65535\nTUPLTYPE RGB\n",
        "DEPTH 3\nMAXVAL 1\nTUPLTYPE RGB\n",
        "DEPTH 3\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\n",
        "DEPTH 4\nMAXVAL 255\nTUPLTYPE RGB\n",
        "DEPTH 3\nMAXVAL 255\nTUPLTYPE XYZ\n",
        "DEPTH 3\nMAXVAL 255\n",
        "DEPTH 3\nMAXVAL 255\nTUPLTYPE RGB\nTUPLTYPE RGB\n",
    };
    for (formats) |format| {
        const pam = try std.fmt.allocPrint(std.testing.allocator, "P7\nWIDTH 2\nHEIGHT 1\n{s}ENDHDR\n{s}", .{ format, rgb_pixels });
        defer std.testing.allocator.free(pam);
        try std.testing.expectError(error.InvalidPam, validate(opaque_pixels, 2, 1, pam));
    }
}

test "PAM header requires actual unique complete fields" {
    const headers = [_][]const u8{
        "P6\nWIDTH 2\nHEIGHT 1\n",
        "P7\n# WIDTH 2\nHEIGHT 1\n",
        "P7\nWIDTH 2\n# HEIGHT 1\n",
        "P7\nWIDTH 2\nWIDTH 2\nHEIGHT 1\n",
        "P7\nWIDTH 2extra\nHEIGHT 1\n",
        "P7\nWIDTH 2 3\nHEIGHT 1\n",
        "P7\nWIDTH 0\nHEIGHT 1\n",
    };
    for (headers) |header| {
        const pam = try std.mem.concat(std.testing.allocator, u8, &.{ header, rgb_format, rgb_pixels });
        defer std.testing.allocator.free(pam);
        try std.testing.expectError(error.InvalidPam, validate(opaque_pixels, 2, 1, pam));
    }
    try std.testing.expectError(error.InvalidPam, validate(opaque_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n"));
}

test "PAM validation compares every channel including alpha and exact raster size" {
    const transparent_pixels = "\xff\x00\x00\x80\x00\xff\x00\x00";
    try validate(transparent_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n" ++ rgba_format ++ transparent_pixels);
    try std.testing.expectError(error.RoundTripMismatch, validate(transparent_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n" ++ rgb_format ++ rgb_pixels));
    try std.testing.expectError(error.RoundTripMismatch, validate(transparent_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n" ++ rgba_format ++ opaque_pixels));
    try std.testing.expectError(error.RoundTripMismatch, validate(opaque_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n" ++ rgb_format ++ "\x00\xff\x00\xff\x00\x00"));
    try std.testing.expectError(error.InvalidPam, validate(opaque_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n" ++ rgb_format ++ rgb_pixels ++ "\x00"));
    try std.testing.expectError(error.InvalidPam, validate(opaque_pixels, 2, 1, "P7\nWIDTH 2\nHEIGHT 1\n" ++ rgba_format ++ rgb_pixels));
}
