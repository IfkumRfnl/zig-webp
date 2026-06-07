//! Animation container types. Pixel compositing is intentionally out of scope here.

const std = @import("std");

const container = @import("container.zig");
const errors = @import("errors.zig");
const image = @import("image.zig");

pub const LoopCount = union(enum) {
    infinite,
    count: u16,
};

pub const BlendMethod = enum(u1) {
    alpha_blend = 0,
    replace = 1,
};

pub const DisposeMethod = enum(u1) {
    none = 0,
    background = 1,
};

pub const Info = struct {
    background_bgra: [4]u8,
    loop_count: LoopCount,
};

pub const FrameRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn dimensions(self: FrameRect) errors.Error!image.Dimensions {
        return image.Dimensions.init(self.width, self.height);
    }

    pub fn validateInside(self: FrameRect, canvas: image.Dimensions) errors.Error!void {
        if (self.width == 0) return error.InvalidFrameChunk;
        if (self.height == 0) return error.InvalidFrameChunk;
        if (self.x > canvas.width) return error.InvalidFrameChunk;
        if (self.y > canvas.height) return error.InvalidFrameChunk;

        const right = @as(u64, self.x) + @as(u64, self.width);
        const bottom = @as(u64, self.y) + @as(u64, self.height);
        if (right > canvas.width) return error.InvalidFrameChunk;
        if (bottom > canvas.height) return error.InvalidFrameChunk;
    }
};

pub const Frame = struct {
    rect: FrameRect,
    duration_ms: u32,
    blend_method: BlendMethod,
    dispose_method: DisposeMethod,
    format: ?@import("features.zig").FormatKind = null,
    has_alpha: bool = false,
    alpha_chunk: ?container.ChunkLocation = null,
    bitstream_chunk: ?container.ChunkLocation = null,
};

test "validates frame rectangle containment" {
    const canvas = try image.Dimensions.init(16, 16);
    const rect = FrameRect{
        .x = 2,
        .y = 4,
        .width = 8,
        .height = 10,
    };

    try rect.validateInside(canvas);

    const overflow = FrameRect{
        .x = 12,
        .y = 0,
        .width = 8,
        .height = 1,
    };
    try std.testing.expectError(error.InvalidFrameChunk, overflow.validateInside(canvas));
}
