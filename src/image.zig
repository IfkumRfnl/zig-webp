//! Pixel-buffer and dimension types shared by decoder and encoder APIs.

const std = @import("std");

const errors = @import("errors.zig");
const limits = @import("limits.zig");

pub const Dimensions = struct {
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) errors.Error!Dimensions {
        _ = try limits.pixelCount(width, height);

        return .{
            .width = width,
            .height = height,
        };
    }

    pub fn pixelCount(self: Dimensions) errors.Error!u64 {
        return limits.pixelCount(self.width, self.height);
    }
};

pub const PixelFormat = enum {
    rgb,
    rgba,
    bgra,
    argb,

    pub fn channelCount(self: PixelFormat) u32 {
        return switch (self) {
            .rgb => 3,
            .rgba,
            .bgra,
            .argb,
            => 4,
        };
    }
};

pub const Buffer = struct {
    pixels: []u8,
    dimensions: Dimensions,
    stride: u32,
    format: PixelFormat,

    pub fn rowBytes(self: Buffer) errors.Error!u64 {
        const row_bytes = @as(u64, self.dimensions.width) *
            @as(u64, self.format.channelCount());
        if (row_bytes > std.math.maxInt(u32)) return error.OutputTooLarge;

        return row_bytes;
    }

    pub fn validate(self: Buffer) errors.Error!void {
        _ = try self.dimensions.pixelCount();

        const row_bytes = try self.rowBytes();
        if (@as(u64, self.stride) < row_bytes) return error.OutputTooLarge;

        const height = self.dimensions.height;
        const required = if (height == 0)
            0
        else
            (@as(u64, self.stride) * (@as(u64, height) - 1)) + row_bytes;
        if (required > self.pixels.len) return error.OutputTooLarge;
    }
};

pub const OwnedBuffer = struct {
    gpa: std.mem.Allocator,
    buffer: Buffer,

    pub fn deinit(self: OwnedBuffer) void {
        self.gpa.free(self.buffer.pixels);
    }
};

test "validates packed RGBA buffers" {
    var pixels: [4 * 4 * 4]u8 = undefined;
    const dimensions = try Dimensions.init(4, 4);
    const buffer = Buffer{
        .pixels = &pixels,
        .dimensions = dimensions,
        .stride = 16,
        .format = .rgba,
    };

    try std.testing.expectEqual(@as(u64, 16), try buffer.rowBytes());
    try buffer.validate();
}

test "rejects buffers with invalid dimensions" {
    var pixels: [1]u8 = undefined;
    const buffer = Buffer{
        .pixels = &pixels,
        .dimensions = .{
            .width = 0,
            .height = 1,
        },
        .stride = 0,
        .format = .rgba,
    };

    try std.testing.expectError(error.InvalidCanvasSize, buffer.validate());
}
