//! Explicit resource limits used by parsing, decoding, and encoding entry points.

const std = @import("std");

const container = @import("container.zig");
const errors = @import("errors.zig");

pub const ResourceLimits = struct {
    /// Largest accepted input buffer in bytes; above it parsing fails with
    /// `error.InputTooLarge`.
    input_bytes_max: u64 = container.file_size_max,
    /// Largest still-image canvas in pixels (width * height); above it
    /// validation fails with `error.CanvasTooLarge`.
    output_pixels_max: u64 = 16_777_216,
    /// Budget for scratch/output heap allocation on the paths that meter it
    /// (see each entry point's doc); exceeding it fails with
    /// `error.AllocationLimitExceeded`.
    allocation_bytes_max: u64 = 256 * 1024 * 1024,
    /// Largest accepted animation frame count; above it
    /// `error.FrameCountTooLarge`.
    frame_count_max: u32 = 4096,
    /// Largest animated canvas in pixels; above it `error.CanvasTooLarge`.
    animation_canvas_pixels_max: u64 = 16_777_216,
    /// Largest accepted container chunk count; above it
    /// `error.TooManyChunks`.
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
