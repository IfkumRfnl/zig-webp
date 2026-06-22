//! Public decoder and encoder option types.

const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");

pub const DecoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    output_format: image.PixelFormat = .rgba,
    /// Not yet honored: metadata chunks are always exposed via demux results
    /// (`parseWebP`). Reserved for a future metadata-bearing decode result.
    preserve_metadata: bool = true,
    /// Not yet honored: `decodeStatic` always rejects animated inputs with
    /// `error.UnsupportedAnimationDecode`; decode animations via
    /// `decodeAnimation` / `AnimationDecoder` instead.
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
    /// Effort level (0..6, `cwebp -m` compatible): higher trades encode time for
    /// quality by widening the rate-distortion search. The lossy default 4
    /// matches the step-8b gate's `cwebp -q 75 -m 4`. Scaffolded for step 8c-1;
    /// not yet honored — the encoder uses its fixed RD search regardless.
    method: u8 = 4,
    /// Target output size in bytes. When set, the encoder iterates quality to
    /// land within tolerance of this size. Scaffolded for step 8c-3; not yet
    /// honored — `quality` alone selects the quantizer.
    target_size: ?u32 = null,
    /// Target reconstructed luma PSNR in dB. When set, the encoder iterates
    /// quality to reach it. Mutually exclusive with `target_size`. Scaffolded
    /// for step 8c-3; not yet honored.
    target_psnr: ?f32 = null,
    /// Alpha-plane quality (0..100) for lossy+alpha (`ALPH`) output. Scaffolded
    /// for step 8c-2; not yet honored — lossy encode currently drops alpha.
    alpha_quality: u8 = 100,
    /// Use sharp (iterative) RGB→YUV chroma downsampling instead of the box
    /// average. Scaffolded for step 8c-4; not yet honored.
    use_sharp_yuv: bool = false,
};
