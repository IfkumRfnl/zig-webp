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

/// Byte order of one pixel in a `Buffer`, named most-significant channel
/// first: `rgba` stores bytes `R,G,B,A`, `bgra` stores `B,G,R,A`, and `argb`
/// stores `A,R,G,B`. `rgb` is 3 bytes per pixel (`R,G,B`) and carries no
/// alpha: decoders drop alpha into it, encoders treat it as fully opaque.
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

/// A pixel plane read and written row-major: row `y` starts at byte
/// `y * stride` of `pixels`. The buffer does not own `pixels` (see
/// `OwnedBuffer` for the owning variant); `validate` is the entry-point
/// precondition.
pub const Buffer = struct {
    pixels: []u8,
    dimensions: Dimensions,
    /// Distance in bytes between the starts of consecutive rows; must be at
    /// least `width * format.channelCount()` (checked by `validate`).
    stride: u32,
    format: PixelFormat,

    pub fn rowBytes(self: Buffer) errors.Error!u64 {
        const row_bytes = @as(u64, self.dimensions.width) *
            @as(u64, self.format.channelCount());
        if (row_bytes > std.math.maxInt(u32)) return error.OutputTooLarge;

        return row_bytes;
    }

    /// Checks the buffer invariants: valid dimensions
    /// (`error.InvalidCanvasSize`/`error.DimensionsOverflow`), a stride of at
    /// least one row of pixels, and a `pixels` slice long enough for
    /// `height` rows at that stride (`error.OutputTooLarge` otherwise).
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

/// A `Buffer` plus the allocator that owns its pixels. Returned by
/// `decodeStatic`; the buffer is tightly packed (stride == row bytes). Free
/// with `deinit`.
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
