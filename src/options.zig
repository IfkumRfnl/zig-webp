//! Public decoder and encoder option types.

const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const metadata = @import("metadata.zig");

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

/// Options bag for the still pixel encoders (`encodeLossless`/`encodeLossy`).
/// The lower-level mux (`mux.encodeStatic`) takes its own `mux.Options`.
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
    /// Alpha-plane compression effort (0..100) for lossy+alpha (`ALPH`) output
    /// (step 8c-2). 0 emits an uncompressed `ALPH` chunk; 1..100 also tries the
    /// lossless VP8L form and keeps whichever is smaller. Alpha is always
    /// lossless — this knob trades encode work for size, never fidelity.
    alpha_quality: u8 = 100,
    /// Use sharp (iterative) RGB→YUV chroma downsampling instead of the box
    /// average. Scaffolded for step 8c-4; not yet honored.
    use_sharp_yuv: bool = false,
    /// Raw metadata payloads (ICCP color profile, EXIF, XMP) to attach to a
    /// still encode (step 9d). Each present payload is written verbatim into its
    /// canonical chunk by the still encoders (`encodeLossless`/`encodeLossy`),
    /// forcing the extended (`VP8X`) container, and round-trips byte-exactly
    /// through `demux`. Default `.{}` (all null) leaves the output identical to
    /// the no-metadata path. The encoders do not parse or validate the payloads;
    /// the caller owns them and they must outlive the encode call.
    metadata: metadata.RawPayloads = .{},
};
