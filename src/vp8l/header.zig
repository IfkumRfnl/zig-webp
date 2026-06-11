//! VP8L lossless bitstream image header parsing.

const std = @import("std");
const assert = std.debug.assert;

const container = @import("../container.zig");
const errors = @import("../errors.zig");
const image = @import("../image.zig");

pub const signature: u8 = 0x2f;
pub const byte_count = 5;
pub const dimension_limit = 16_384;
pub const version_supported = 0;

pub const Header = struct {
    dimensions: image.Dimensions,
    has_alpha: bool,
    version: u3,
};

comptime {
    assert(byte_count == 5);
    assert(dimension_limit == 1 << 14);
    assert(version_supported == 0);
}

pub fn parse(payload: []const u8) errors.Error!Header {
    if (payload.len < byte_count) return error.InvalidVP8LHeader;
    if (payload[0] != signature) return error.InvalidVP8LHeader;

    const bits = container.readLittleU32(payload[1..byte_count]);
    const width = (bits & 0x3fff) + 1;
    const height = ((bits >> 14) & 0x3fff) + 1;
    const has_alpha = ((bits >> 28) & 1) == 1;
    const version: u3 = @intCast((bits >> 29) & 0x7);
    if (version != version_supported) return error.InvalidVP8LHeader;

    return .{
        .dimensions = try image.Dimensions.init(width, height),
        .has_alpha = has_alpha,
        .version = version,
    };
}

test "parses VP8L image header fields" {
    var payload: [byte_count]u8 = .{ signature, 0, 0, 0, 0 };
    const bits = (@as(u32, 2) - 1) |
        ((@as(u32, 5) - 1) << 14) |
        (@as(u32, 1) << 28);
    container.writeLittleU32(payload[1..byte_count], bits);

    const header = try parse(&payload);

    try std.testing.expectEqual(@as(u32, 2), header.dimensions.width);
    try std.testing.expectEqual(@as(u32, 5), header.dimensions.height);
    try std.testing.expect(header.has_alpha);
    try std.testing.expectEqual(@as(u3, version_supported), header.version);
}

test "parses maximum VP8L image dimensions" {
    var payload: [byte_count]u8 = .{ signature, 0, 0, 0, 0 };
    const bits = (@as(u32, dimension_limit) - 1) |
        ((@as(u32, dimension_limit) - 1) << 14);
    container.writeLittleU32(payload[1..byte_count], bits);

    const header = try parse(&payload);

    try std.testing.expectEqual(@as(u32, dimension_limit), header.dimensions.width);
    try std.testing.expectEqual(@as(u32, dimension_limit), header.dimensions.height);
    try std.testing.expect(!header.has_alpha);
}

test "rejects invalid VP8L image headers" {
    try std.testing.expectError(error.InvalidVP8LHeader, parse(&.{}));

    var bad_signature: [byte_count]u8 = .{ 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidVP8LHeader, parse(&bad_signature));

    var unsupported_version: [byte_count]u8 = .{ signature, 0, 0, 0, 0 };
    container.writeLittleU32(
        unsupported_version[1..byte_count],
        @as(u32, 1) << 29,
    );
    try std.testing.expectError(error.InvalidVP8LHeader, parse(&unsupported_version));
}
