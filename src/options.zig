//! Public decoder and encoder option types.

const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");

pub const DecoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    output_format: image.PixelFormat = .rgba,
    /// Not yet honored: metadata chunks are currently always exposed via
    /// demux results. Reserved for the step 6 extended-decode work.
    preserve_metadata: bool = true,
    /// Not yet honored: animated inputs currently fail static decode with
    /// `error.UnsupportedAnimationDecode`. Reserved for step 6.
    decode_animation: bool = true,
};

/// Forward-looking surface for the planned encoders (PLAN.MD steps 7-8).
/// No encode path consumes these options yet; `mux.encodeStatic` takes
/// `mux.Options`.
pub const EncoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    format: features.FormatKind = .lossless,
    quality: u8 = 75,
    preserve_metadata: bool = true,
};
