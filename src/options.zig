//! Public decoder and encoder option types.

const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");

pub const DecoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    output_format: image.PixelFormat = .rgba,
    preserve_metadata: bool = true,
    decode_animation: bool = true,
};

pub const EncoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    format: features.FormatKind = .lossless,
    quality: u8 = 75,
    preserve_metadata: bool = true,
};
