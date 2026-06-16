//! VP8 lossy bitstream image header probing.

const std = @import("std");
const assert = std.debug.assert;

const container = @import("../container.zig");
const errors = @import("../errors.zig");
const image = @import("../image.zig");
const frame_header = @import("frame_header.zig");

pub const byte_count = frame_header.header_byte_count;
pub const start_code = frame_header.start_code;
pub const dimension_limit = frame_header.dimension_limit;
pub const version_max = frame_header.version_max;

pub const Header = struct {
    dimensions: image.Dimensions,
    version: u3,
};

comptime {
    assert(byte_count == 10);
    assert(dimension_limit == (1 << 14) - 1);
    assert(version_max == 3);
}

pub fn parse(payload: []const u8) errors.Error!Header {
    if (payload.len < byte_count) return error.InvalidVP8Header;

    const frame_tag = container.readLittleU24(payload[0..3]);
    const key_frame = (frame_tag & 1) == 0;
    const version: u3 = @intCast((frame_tag >> 1) & 7);
    const show_frame = ((frame_tag >> 4) & 1) == 1;
    const first_partition_length: usize = @intCast(frame_tag >> 5);
    if (!key_frame) return error.InvalidVP8Header;
    if (version > version_max) return error.InvalidVP8Header;
    if (!show_frame) return error.InvalidVP8Header;
    if (first_partition_length >= payload.len) return error.InvalidVP8Header;
    if (!std.mem.eql(u8, payload[3..6], &start_code)) {
        return error.InvalidVP8Header;
    }

    const width = @as(u32, container.readLittleU16(payload[6..8]) & dimension_limit);
    const height = @as(u32, container.readLittleU16(payload[8..10]) & dimension_limit);

    return .{
        .dimensions = try image.Dimensions.init(width, height),
        .version = version,
    };
}

test "parses VP8 image header fields" {
    var payload = [_]u8{ 0x10, 0, 0, 0x9d, 0x01, 0x2a, 0, 0, 0, 0 };
    container.writeLittleU16(payload[6..8], 4);
    container.writeLittleU16(payload[8..10], 3);

    const header = try parse(&payload);

    try std.testing.expectEqual(@as(u32, 4), header.dimensions.width);
    try std.testing.expectEqual(@as(u32, 3), header.dimensions.height);
    try std.testing.expectEqual(@as(u3, 0), header.version);
}

test "rejects malformed VP8 image headers" {
    try std.testing.expectError(error.InvalidVP8Header, parse(&.{}));

    var unsupported_profile = [_]u8{ 0x10, 0, 0, 0x9d, 0x01, 0x2a, 1, 0, 1, 0 };
    container.writeLittleU24(unsupported_profile[0..3], 0x10 | (@as(u32, 4) << 1));
    try std.testing.expectError(error.InvalidVP8Header, parse(&unsupported_profile));

    var oversized_partition = [_]u8{ 0x10, 0, 0, 0x9d, 0x01, 0x2a, 1, 0, 1, 0 };
    const first_partition_length: u32 = @intCast(oversized_partition.len);
    container.writeLittleU24(oversized_partition[0..3], 0x10 | (first_partition_length << 5));
    try std.testing.expectError(error.InvalidVP8Header, parse(&oversized_partition));

    var bad_start_code = [_]u8{ 0x10, 0, 0, 0, 0, 0, 1, 0, 1, 0 };
    try std.testing.expectError(error.InvalidVP8Header, parse(&bad_start_code));
}
