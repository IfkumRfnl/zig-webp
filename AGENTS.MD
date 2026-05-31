# AGENTS.MD

- Target Zig 0.16.0. Run `zig version` before broad API changes.
- Preserve the zero-dependency policy. Do not add C, system libraries, vendored
  codecs, or package dependencies.
- Keep public API declarations in `src/root.zig`; place implementation modules
  under `src/`.
- Prefer explicit parsing, bounded loops, and checked integer conversions.
- Run `zig fmt .` and `zig build test` before handing work back.
- Do not commit generated build output such as `.zig-cache/` or `zig-out/`.
