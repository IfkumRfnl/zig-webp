//! Explicit resource limits used by parsing, decoding, and encoding entry points.

const std = @import("std");

const container = @import("container.zig");
const errors = @import("errors.zig");

pub const ResourceLimits = struct {
    input_bytes_max: u64 = container.file_size_max,
    output_pixels_max: u64 = 16_777_216,
    allocation_bytes_max: u64 = 256 * 1024 * 1024,
    frame_count_max: u32 = 4096,
    animation_canvas_pixels_max: u64 = 16_777_216,
    chunk_count_max: u32 = 65_536,

    pub fn validateInputBytes(self: ResourceLimits, len: u64) errors.Error!void {
        if (len > self.input_bytes_max) return error.InputTooLarge;
    }

    pub fn validateAllocationBytes(self: ResourceLimits, len: u64) errors.Error!void {
        if (len > self.allocation_bytes_max) return error.AllocationLimitExceeded;
    }

    pub fn validateChunkCount(self: ResourceLimits, count: u64) errors.Error!void {
        if (count > self.chunk_count_max) return error.TooManyChunks;
    }

    pub fn validateFrameCount(self: ResourceLimits, count: u64) errors.Error!void {
        if (count > self.frame_count_max) return error.FrameCountTooLarge;
    }

    pub fn validateCanvas(
        self: ResourceLimits,
        width: u32,
        height: u32,
        animated: bool,
    ) errors.Error!void {
        if (width == 0) return error.InvalidCanvasSize;
        if (height == 0) return error.InvalidCanvasSize;

        const pixels = try pixelCount(width, height);
        const pixels_max = if (animated)
            self.animation_canvas_pixels_max
        else
            self.output_pixels_max;
        if (pixels > pixels_max) return error.CanvasTooLarge;
    }
};

pub fn pixelCount(width: u32, height: u32) errors.Error!u64 {
    if (width == 0) return error.InvalidCanvasSize;
    if (height == 0) return error.InvalidCanvasSize;

    const pixels = @as(u64, width) * @as(u64, height);
    if (pixels > std.math.maxInt(u32)) return error.DimensionsOverflow;

    return pixels;
}

test "enforces resource limit categories" {
    const limit = ResourceLimits{
        .input_bytes_max = 4,
        .output_pixels_max = 16,
        .allocation_bytes_max = 8,
        .frame_count_max = 2,
        .animation_canvas_pixels_max = 32,
        .chunk_count_max = 1,
    };

    try std.testing.expectError(error.InputTooLarge, limit.validateInputBytes(5));
    try std.testing.expectError(error.AllocationLimitExceeded, limit.validateAllocationBytes(9));
    try std.testing.expectError(error.TooManyChunks, limit.validateChunkCount(2));
    try std.testing.expectError(error.FrameCountTooLarge, limit.validateFrameCount(3));
    try std.testing.expectError(error.CanvasTooLarge, limit.validateCanvas(5, 5, false));
    try limit.validateCanvas(5, 5, true);
}
