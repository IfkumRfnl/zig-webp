# AGENTS.MD

- Target Zig 0.16.0. Run `zig version` before broad API changes.
- Preserve the zero-dependency policy. Do not add C, system libraries, vendored
  codecs, or package dependencies.
- External codec tools and cloned reference repositories may be used for local
  research, tests, and differential validation. Keep them under `references/`
  and out of the package build. They must not become build dependencies.
- Keep public API declarations in `src/root.zig`; place implementation modules
  under `src/`.
- Keep codec subsystems modular. RIFF mux/demux, VP8, VP8L, alpha, animation,
  metadata, pixel buffers, color conversion, bit readers, and bit writers should
  be separate modules with narrow interfaces.
- Do not add monolithic codec files. If a file starts mixing container parsing,
  entropy coding, transforms, and public API policy, split it before continuing.
- Container code must not depend on VP8 or VP8L internals. VP8/VP8L code must
  not know about RIFF chunk ordering. Animation code should compose frames using
  decoder interfaces rather than reaching into codec internals.
- Prefer explicit parsing, bounded loops, and checked integer conversions.
- Make scalar correctness authoritative before adding SIMD, threading, or
  speed-focused variants.
- Performance ambition is targeted `libwebp` outperformance, not premature
  global superiority. First reach correctness parity, then compete on clear
  dimensions: Zig-native API quality, auditability, deterministic allocation,
  smaller modular code, feature probing speed, mux/demux ergonomics, selected
  scalar decode paths, fast basic lossless encoding, and specific asset classes
  such as UI images or alpha-heavy images.
- Benchmark honestly against `references/libwebp` tools. Record whether a win
  is about decode speed, encode speed, file size, visual quality, memory use,
  binary size, API ergonomics, or safety. Do not claim a general win from a
  narrow benchmark.
- Treat lossy encoder quality and equal-quality speed as long-term research
  goals. They are the hardest areas to beat because `libwebp` has mature
  heuristics and architecture-specific optimization.
- Use the specs as the primary source of truth:
  - WebP container: https://developers.google.com/speed/webp/docs/riff_container
  - WebP image format RFC: https://www.rfc-editor.org/rfc/rfc9649
  - VP8 bitstream: https://www.rfc-editor.org/rfc/rfc6386
  - VP8L bitstream: https://developers.google.com/speed/webp/docs/webp_lossless_bitstream_specification
- Use references by role, not by copy-paste:
  - `references/libwebp`: conformance oracle and quality baseline.
  - `references/libwebp-test-data`: official corpus.
  - `references/simplewebp`: compact C decoder reference.
  - `references/image-webp`: independent pure-Rust decoder and module reference.
  - `references/ffmpeg/libavcodec/webp.c`: mature low-level C decoder reference.
  - `references/deepteams-webp` and `references/skrashevich-go-webp`: pure-Go
    encoder/test ideas.
- Do not copy reference implementation code. Reimplement from the specs and
  validate behavior with tests.
- Run `zig fmt .` and `zig build test` before handing work back.
- Do not commit generated build output such as `.zig-cache/` or `zig-out/`.
