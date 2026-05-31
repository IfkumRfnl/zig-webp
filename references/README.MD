# Reference Cache

This directory is for local reference implementations, codec tools, and corpus
data used while building `zig-webp`.

The clone directories are intentionally ignored by git. They are research and
test fixtures, not source code for this package and not build dependencies.

Populate the local cache from the repository root with:

```sh
mkdir -p references
git clone --depth 1 https://github.com/webmproject/libwebp.git references/libwebp
git clone --depth 1 https://chromium.googlesource.com/webm/libwebp-test-data references/libwebp-test-data
git clone --depth 1 https://github.com/MikuAuahDark/simplewebp.git references/simplewebp
git clone --depth 1 https://github.com/image-rs/image-webp.git references/image-webp
git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git references/ffmpeg
git clone --depth 1 https://github.com/deepteams/webp.git references/deepteams-webp
git clone --depth 1 https://github.com/skrashevich/go-webp.git references/skrashevich-go-webp
```

Expected local paths:

- `references/libwebp`
- `references/libwebp-test-data`
- `references/simplewebp`
- `references/image-webp`
- `references/ffmpeg`
- `references/deepteams-webp`
- `references/skrashevich-go-webp`

Use these references for behavior study, corpus tests, and differential
validation. Reimplement from the WebP specs and project tests rather than
copying reference implementation code.
