//! VP8L internal ARGB pixel representation helpers.

const std = @import("std");
const assert = std.debug.assert;

pub const Pixel = u32;

pub fn fromChannels(
    alpha_value: u8,
    red_value: u8,
    green_value: u8,
    blue_value: u8,
) Pixel {
    return (@as(Pixel, alpha_value) << 24) |
        (@as(Pixel, red_value) << 16) |
        (@as(Pixel, green_value) << 8) |
        @as(Pixel, blue_value);
}

pub fn alpha(value: Pixel) u8 {
    return @intCast(value >> 24);
}

pub fn red(value: Pixel) u8 {
    return @intCast((value >> 16) & 0xff);
}

pub fn green(value: Pixel) u8 {
    return @intCast((value >> 8) & 0xff);
}

pub fn blue(value: Pixel) u8 {
    return @intCast(value & 0xff);
}

pub fn expectChannels(
    value: Pixel,
    expected_alpha: u8,
    expected_red: u8,
    expected_green: u8,
    expected_blue: u8,
) !void {
    try std.testing.expectEqual(expected_alpha, alpha(value));
    try std.testing.expectEqual(expected_red, red(value));
    try std.testing.expectEqual(expected_green, green(value));
    try std.testing.expectEqual(expected_blue, blue(value));
}

comptime {
    assert(@bitSizeOf(Pixel) == 32);
}

test "VP8L pixel packs channels in ARGB bit order" {
    const value = fromChannels(0x44, 0x33, 0x22, 0x11);

    try std.testing.expectEqual(@as(Pixel, 0x44332211), value);
    try expectChannels(value, 0x44, 0x33, 0x22, 0x11);
}
