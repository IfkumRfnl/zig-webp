#!/usr/bin/env bash
#
# webp-rust-bench.sh — optional local Rust (image-webp) comparison for the
# still `decode-into` rows from `zig build bench`.
#
# This is deliberately NOT a package or CI dependency. It SKIPs when `cargo`
# or `references/image-webp` is missing. The Cargo adapter is materialized
# only under `.zig-cache/` (path dependency onto the local reference clone;
# that clone is never modified). File I/O is excluded from timings on both
# sides; decoded bytes are checked against Zig `decode-into` digests before
# any Rust sample is timed.
#
# The Zig bench is always invoked through
# `zig build -Doptimize=ReleaseFast bench -- ...` so the ReleaseFast artifact
# is selected deterministically (never by scanning `.zig-cache` with find).
#
# Usage:
#   tools/webp-rust-bench.sh [options] [FILE.webp ...]
# Options:
#   -n RUNS / --iters N   timed iterations (default 15)
#   --warmup N            untimed warmups (default 2)
#   --budget-ms N         per-file time budget (default 1500)
#   --filter SUBSTR       keep only file names containing SUBSTR
#   --all                 photos + committed static corpus (testdata/photos and
#                         testdata/libwebp-test-data). Benchmarks exactly the
#                         files for which Zig produced validated decode-into
#                         digests; others are reported as SKIP.
#   -o OUTPUT.tsv         write the unified comparison TSV (default: stdout)
#
# With neither FILE arguments nor --all, a small default smoke set is used:
#   testdata/photos/photo_foliage.webp (VP8L)
#   testdata/libwebp-test-data/vp80-00-comprehensive-001.webp (VP8)
#
set -euo pipefail

iters=15
warmup=2
budget_ms=1500
filter=""
output=""
all_mode=0
files=()

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--iters)
      iters="${2:?}"
      shift 2
      ;;
    --warmup)
      warmup="${2:?}"
      shift 2
      ;;
    --budget-ms)
      budget_ms="${2:?}"
      shift 2
      ;;
    --filter)
      filter="${2:?}"
      shift 2
      ;;
    --all)
      all_mode=1
      shift
      ;;
    -o)
      output="${2:?}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    --)
      shift
      files+=("$@")
      break
      ;;
    -*)
      printf 'webp-rust-bench: unknown option %s\n' "$1" >&2
      exit 2
      ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

if ! has_cmd cargo; then
  printf 'SKIP: cargo not found (optional Rust comparison harness)\n' >&2
  exit 0
fi

ref="$root/references/image-webp"
if [ ! -f "$ref/Cargo.toml" ]; then
  printf 'SKIP: references/image-webp not present (clone it under references/; see references/README.MD)\n' >&2
  exit 0
fi

if ! has_cmd zig; then
  printf 'webp-rust-bench: zig is required to build zig-webp-bench\n' >&2
  exit 1
fi

cache_root="$root/.zig-cache/rust-bench-adapter"
mkdir -p "$cache_root/src"

# Materialize a tiny Cargo adapter that path-depends on the local reference
# clone. Everything here stays under .zig-cache/; the reference is read-only.
cat >"$cache_root/Cargo.toml" <<EOF
[package]
name = "zig_webp_rust_bench_adapter"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
image-webp = { path = "$ref" }
EOF

cat >"$cache_root/src/main.rs" <<'RUST_EOF'
//! Temporary adapter for tools/webp-rust-bench.sh (lives under .zig-cache only).
//! Times image-webp still decode via WebPDecoder::new + read_image into a
//! reused buffer. File reads and digest checks are outside the timed interval.

use image_webp::WebPDecoder;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Cursor, Write};
use std::path::{Path, PathBuf};
use std::process;
use std::time::Instant;

#[derive(Clone)]
struct Expect {
    sha256: String,
    format: String,
    alpha: String,
    width: u32,
    height: u32,
}

fn main() {
    if let Err(err) = run() {
        eprintln!("rust-bench-adapter: {err}");
        process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut iters: u32 = 15;
    let mut warmup: u32 = 2;
    let mut budget_ms: u64 = 1500;
    let mut expect_path: Option<PathBuf> = None;
    let mut output_path: Option<PathBuf> = None;
    let mut identity = String::from("rustc unknown release");
    let mut files: Vec<PathBuf> = Vec::new();

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--iters" => iters = args.next().ok_or("--iters needs a value")?.parse().map_err(|e| format!("{e}"))?,
            "--warmup" => warmup = args.next().ok_or("--warmup needs a value")?.parse().map_err(|e| format!("{e}"))?,
            "--budget-ms" => budget_ms = args.next().ok_or("--budget-ms needs a value")?.parse().map_err(|e| format!("{e}"))?,
            "--expect-digests" => {
                expect_path = Some(PathBuf::from(args.next().ok_or("--expect-digests needs a path")?))
            }
            "--identity" => identity = args.next().ok_or("--identity needs a value")?,
            "-o" | "--output" => {
                output_path = Some(PathBuf::from(args.next().ok_or("--output needs a path")?))
            }
            "-h" | "--help" => {
                eprintln!(
                    "usage: zig_webp_rust_bench_adapter [--iters N] [--warmup N] [--budget-ms N] \\\n\
                     \t[--expect-digests PATH] [--identity TEXT] [-o OUT.tsv] FILE.webp..."
                );
                return Ok(());
            }
            other if other.starts_with('-') => return Err(format!("unknown option {other}")),
            other => files.push(PathBuf::from(other)),
        }
    }
    if files.is_empty() {
        return Err("at least one FILE.webp is required".into());
    }
    let expect_path = expect_path.ok_or("--expect-digests is required (Zig digests for validation)")?;
    let expects = load_expects(&expect_path)?;

    let mut out: Box<dyn Write> = if let Some(path) = output_path {
        Box::new(fs::File::create(path).map_err(|e| e.to_string())?)
    } else {
        Box::new(io::stdout())
    };

    writeln!(
        out,
        "# image-webp still decode-into: median of up to {iters} timed runs ({warmup} warmup, {budget_ms} ms budget)."
    )
    .map_err(|e| e.to_string())?;
    writeln!(
        out,
        "# implementation\tasset_class\tfile\toperation\tformat\talpha\twidth\theight\tpixels\tsamples\tmedian_ms\tmin_ms\tmpps\tidentity"
    )
    .map_err(|e| e.to_string())?;

    let mut timed = 0u32;
    let mut skipped = 0u32;
    for path in files {
        match bench_one(&mut out, &path, &expects, iters, warmup, budget_ms, &identity) {
            Ok(()) => timed += 1,
            Err(msg) => {
                eprintln!("SKIP: {msg}");
                skipped += 1;
            }
        }
    }
    eprintln!("webp-rust-bench-adapter: timed {timed} file(s), skipped {skipped}");
    if timed == 0 {
        return Err("no files timed after validation (all skipped)".into());
    }
    Ok(())
}

fn load_expects(path: &Path) -> Result<HashMap<String, Expect>, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let mut map = HashMap::new();
    for (lineno, line) in text.lines().enumerate() {
        if line.is_empty() || line.starts_with('#') || line.starts_with("file\t") {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() < 6 {
            return Err(format!(
                "{}:{}: expected file sha256 format alpha width height",
                path.display(),
                lineno + 1
            ));
        }
        map.insert(
            cols[0].to_string(),
            Expect {
                sha256: cols[1].to_string(),
                format: cols[2].to_string(),
                alpha: cols[3].to_string(),
                width: cols[4].parse().map_err(|e| format!("{e}"))?,
                height: cols[5].parse().map_err(|e| format!("{e}"))?,
            },
        );
    }
    Ok(map)
}

fn classify(width: u32, height: u32, alpha: bool) -> &'static str {
    if alpha {
        return "alpha";
    }
    let pixels = (width as u64).saturating_mul(height as u64);
    if pixels > (1 << 20) {
        "large"
    } else if pixels <= 64 * 64 {
        "icon"
    } else {
        "photo"
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = sha256(bytes);
    let mut out = String::with_capacity(64);
    for b in digest {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn bench_one(
    out: &mut dyn Write,
    path: &Path,
    expects: &HashMap<String, Expect>,
    iters: u32,
    warmup: u32,
    budget_ms: u64,
    identity: &str,
) -> Result<(), String> {
    let file_name = path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| format!("invalid path {}", path.display()))?
        .to_string();
    let expect = expects.get(&file_name).ok_or_else(|| {
        format!("no Zig digest for {file_name}; refusing to time an unchecked file")
    })?;

    let input = fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;

    let mut probe = WebPDecoder::new(Cursor::new(&input))
        .map_err(|e| format!("{file_name}: unsupported/invalid WebP: {e}"))?;
    if probe.is_animated() {
        return Err(format!("{file_name}: animated WebP is out of scope for decode-into comparison"));
    }
    let (width, height) = probe.dimensions();
    let has_alpha = probe.has_alpha();
    let format = if probe.is_lossy() { "lossy" } else { "lossless" };
    let alpha = if has_alpha { "alpha" } else { "opaque" };
    if width != expect.width || height != expect.height {
        return Err(format!(
            "{file_name}: dimension mismatch vs Zig digest (rust {width}x{height}, zig {}x{})",
            expect.width, expect.height
        ));
    }
    if format != expect.format || alpha != expect.alpha {
        return Err(format!(
            "{file_name}: format/alpha mismatch vs Zig digest (rust {format}/{alpha}, zig {}/{})",
            expect.format, expect.alpha
        ));
    }
    let buf_len = probe
        .output_buffer_size()
        .ok_or_else(|| format!("{file_name}: output buffer too large"))?;
    let mut buf = vec![0u8; buf_len];
    probe
        .read_image(&mut buf)
        .map_err(|e| format!("{file_name}: decode failed: {e}"))?;
    let got = sha256_hex(&buf);
    if got != expect.sha256 {
        return Err(format!(
            "{file_name}: decoded bytes mismatch Zig decode-into digest\n  rust={got}\n  zig ={}",
            expect.sha256
        ));
    }

    for _ in 0..warmup {
        let mut dec = WebPDecoder::new(Cursor::new(&input)).map_err(|e| e.to_string())?;
        dec.read_image(&mut buf).map_err(|e| e.to_string())?;
        std::hint::black_box(&buf);
    }

    let budget = std::time::Duration::from_millis(budget_ms);
    let want = iters.min(64);
    let mut samples: Vec<f64> = Vec::with_capacity(want as usize);
    let mut total = std::time::Duration::ZERO;
    while (samples.len() as u32) < want {
        // Time construction + decode into the reused buffer (matches the
        // assignment's WebPDecoder::new + read_image pairing).
        let start = Instant::now();
        let mut dec = WebPDecoder::new(Cursor::new(&input)).map_err(|e| e.to_string())?;
        dec.read_image(&mut buf).map_err(|e| e.to_string())?;
        let elapsed = start.elapsed();
        std::hint::black_box(&buf);
        samples.push(elapsed.as_secs_f64() * 1_000.0);
        total += elapsed;
        if total >= budget {
            break;
        }
    }
    if samples.is_empty() {
        return Err(format!("{file_name}: no timed samples"));
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median_ms = samples[samples.len() / 2];
    let min_ms = samples[0];
    let pixels = (width as u64) * (height as u64);
    let mpps = if median_ms > 0.0 {
        (pixels as f64) / (median_ms / 1_000.0) / 1_000_000.0
    } else {
        0.0
    };
    let asset_class = classify(width, height, has_alpha);

    writeln!(
        out,
        "image-webp\t{asset_class}\t{file_name}\tdecode-into\t{format}\t{alpha}\t{width}\t{height}\t{pixels}\t{}\t{median_ms:.4}\t{min_ms:.4}\t{mpps:.2}\t{identity}",
        samples.len()
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

fn sha256(message: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let k: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];

    let bit_len = (message.len() as u64) * 8;
    let mut data = message.to_vec();
    data.push(0x80);
    while (data.len() % 64) != 56 {
        data.push(0);
    }
    data.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in data.chunks_exact(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(chunk[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut a = h[0];
        let mut b = h[1];
        let mut c = h[2];
        let mut d = h[3];
        let mut e = h[4];
        let mut f = h[5];
        let mut g = h[6];
        let mut hh = h[7];
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(k[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for (i, val) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&val.to_be_bytes());
    }
    out
}

RUST_EOF

collect_all_candidates() {
  local d f
  for d in testdata/photos testdata/libwebp-test-data; do
    [ -d "$d" ] || continue
    # Deterministic lexicographic order (basename).
    while IFS= read -r f; do
      files+=("$f")
    done < <(find "$d" -maxdepth 1 -type f -name '*.webp' | LC_ALL=C sort)
  done
}

# Candidate stills: --all corpus, explicit paths, or the two-file smoke set.
if [ "$all_mode" -eq 1 ]; then
  if [ "${#files[@]}" -gt 0 ]; then
    printf 'webp-rust-bench: --all cannot be combined with explicit FILE arguments\n' >&2
    exit 2
  fi
  collect_all_candidates
elif [ "${#files[@]}" -eq 0 ]; then
  for candidate in \
    testdata/photos/photo_foliage.webp \
    testdata/libwebp-test-data/vp80-00-comprehensive-001.webp
  do
    if [ -f "$candidate" ]; then
      files+=("$candidate")
    fi
  done
fi

if [ "${#files[@]}" -eq 0 ]; then
  printf 'webp-rust-bench: no input files found\n' >&2
  exit 1
fi

# Optional name filter (applies to basename).
if [ -n "$filter" ]; then
  filtered=()
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    case "$base" in
      *"$filter"*) filtered+=("$f") ;;
    esac
  done
  files=("${filtered[@]}")
  if [ "${#files[@]}" -eq 0 ]; then
    printf 'webp-rust-bench: --filter %s matched no files\n' "$filter" >&2
    exit 1
  fi
fi

for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    printf 'webp-rust-bench: missing file %s\n' "$f" >&2
    exit 1
  fi
done

zig_identity="zig $(zig version) ReleaseFast"
rustc_version="$(rustc -V 2>/dev/null | awk '{print $2}')"
rust_identity="rustc ${rustc_version:-unknown} release"

printf 'webp-rust-bench: building image-webp adapter under .zig-cache\n' >&2
( cd "$cache_root" && cargo build --release -q )

rust_bin="$cache_root/target/release/zig_webp_rust_bench_adapter"
if [ ! -x "$rust_bin" ]; then
  printf 'webp-rust-bench: rust adapter binary missing at %s\n' "$rust_bin" >&2
  exit 1
fi

work="$cache_root/run-$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

digests="$work/zig.digests"
zig_raw="$work/zig.tsv"
rust_raw="$work/rust.tsv"
unified="$work/unified.tsv"
candidates_list="$work/candidates.txt"

: >"$candidates_list"
for f in "${files[@]}"; do
  printf '%s\t%s\n' "$(basename "$f")" "$f" >>"$candidates_list"
done

run_zig_bench() {
  # Always go through the build step so ReleaseFast is selected deterministically.
  zig build -Doptimize=ReleaseFast bench -- "$@"
}

printf 'webp-rust-bench: running zig-webp-bench via zig build -Doptimize=ReleaseFast bench\n' >&2
: >"$zig_raw"
: >"$digests"
printf '# zig-webp decode-into digests (SHA-256 of packed rgb/rgba pixels)\n' >>"$digests"
printf 'file\tsha256\tformat\talpha\twidth\theight\n' >>"$digests"

if [ "$all_mode" -eq 1 ]; then
  # One ReleaseFast decode-only pass over the committed still dirs (+ animation
  # decode rows, which produce no digests). Digests gate the Rust side.
  part_tsv="$work/zig-all.tsv"
  part_dig="$work/dig-all.tsv"
  run_zig_bench \
    --iters "$iters" \
    --warmup "$warmup" \
    --budget-ms "$budget_ms" \
    --decode-only \
    --write-digests "$part_dig" \
    "$part_tsv"
  cat "$part_tsv" >"$zig_raw"
  awk 'BEGIN{p=0} /^file\t/{p=1; next} p && $0 !~ /^#/ {print}' "$part_dig" >>"$digests"
else
  # Smoke / explicit files: one deterministic zig build invocation per basename
  # filter (build graph is cached after the first compile).
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    part_tsv="$work/zig-$base.tsv"
    part_dig="$work/dig-$base.tsv"
    run_zig_bench \
      --iters "$iters" \
      --warmup "$warmup" \
      --budget-ms "$budget_ms" \
      --decode-only \
      --filter "$base" \
      --write-digests "$part_dig" \
      "$part_tsv"
    if [ ! -s "$zig_raw" ]; then
      cat "$part_tsv" >"$zig_raw"
    else
      awk 'BEGIN{p=0} /^asset_class\t/{p=1; next} p && $0 !~ /^#/ {print}' "$part_tsv" >>"$zig_raw"
    fi
    awk 'BEGIN{p=0} /^file\t/{p=1; next} p && $0 !~ /^#/ {print}' "$part_dig" >>"$digests"
  done
fi

# Keep only candidates for which Zig produced a validated decode-into digest.
validated=()
skip_count=0
while IFS=$'\t' read -r base path; do
  if awk -F '\t' -v b="$base" '$0 !~ /^#/ && $1 != "file" && $1 == b { found=1; exit } END { exit !found }' "$digests"; then
    validated+=("$path")
  else
    printf 'SKIP: %s (no Zig decode-into digest; unsupported, invalid, animated, or decode-into failed)\n' "$base" >&2
    skip_count=$((skip_count + 1))
  fi
done <"$candidates_list"

if [ "${#validated[@]}" -eq 0 ]; then
  printf 'webp-rust-bench: no validated stills to compare (%d skipped)\n' "$skip_count" >&2
  exit 1
fi

printf 'webp-rust-bench: comparing %d validated still(s) (%d skipped)\n' "${#validated[@]}" "$skip_count" >&2

"$rust_bin" \
  --iters "$iters" \
  --warmup "$warmup" \
  --budget-ms "$budget_ms" \
  --expect-digests "$digests" \
  --identity "$rust_identity" \
  -o "$rust_raw" \
  "${validated[@]}"

# Basename allow-list for joining (only validated candidates).
allow="$work/allow.txt"
: >"$allow"
for f in "${validated[@]}"; do
  basename "$f" >>"$allow"
done

# Normalize Zig decode-into rows into the joinable unified schema and append Rust.
{
  printf '# zig-webp vs image-webp still decode-into comparison (file I/O excluded from timings).\n'
  printf '# Ratios are zig_median_ms / rust_median_ms (<1 means zig-webp faster).\n'
  printf 'implementation\tasset_class\tfile\toperation\tformat\talpha\twidth\theight\tpixels\tsamples\tmedian_ms\tmin_ms\tmpps\tidentity\n'
  awk -v ident="$zig_identity" '
    BEGIN { FS=OFS="\t" }
    FNR==NR { allow[$1]=1; next }
    /^#/ || /^asset_class\t/ { next }
    $3 == "decode-into" && ($2 in allow) {
      print "zig-webp", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, ident
    }
  ' "$allow" "$zig_raw"
  awk '
    BEGIN { FS=OFS="\t" }
    /^#/ || /^implementation\t/ { next }
    NF { print }
  ' "$rust_raw"
} >"$unified"

# Per-file ratios + bucket geometric means.
{
  cat "$unified"
  printf '\n# per-file ratios (zig_median_ms / rust_median_ms)\n'
  printf 'file\tasset_class\tformat\talpha\tzig_median_ms\trust_median_ms\tratio\n'
  awk '
    BEGIN { FS=OFS="\t" }
    /^#/ || /^implementation\t/ || NF < 14 { next }
    $4 != "decode-into" { next }
    {
      key = $3
      asset[key] = $2
      format[key] = $5
      alpha[key] = $6
      if ($1 == "zig-webp") { zig[key] = $11 + 0 }
      if ($1 == "image-webp") { rust[key] = $11 + 0 }
    }
    END {
      nkeys = 0
      for (k in zig) {
        keys[++nkeys] = k
      }
      for (i = 1; i <= nkeys; i++) {
        for (j = i + 1; j <= nkeys; j++) {
          if (keys[j] < keys[i]) { tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp }
        }
      }
      for (i = 1; i <= nkeys; i++) {
        k = keys[i]
        if (!(k in rust) || rust[k] <= 0) continue
        ratio = zig[k] / rust[k]
        printf "%s\t%s\t%s\t%s\t%.4f\t%.4f\t%.4f\n", k, asset[k], format[k], alpha[k], zig[k], rust[k], ratio
        bucket_sum_log[asset[k]] += log(ratio)
        bucket_n[asset[k]]++
        codec = format[k] "/" alpha[k]
        codec_sum_log[codec] += log(ratio)
        codec_n[codec]++
        all_sum_log += log(ratio)
        all_n++
      }
      print ""
      print "# asset-class geometric-mean ratios"
      print "bucket\tgeomean_ratio\tn"
      nb = 0
      for (b in bucket_n) { bucks[++nb] = b }
      for (i = 1; i <= nb; i++) {
        for (j = i + 1; j <= nb; j++) {
          if (bucks[j] < bucks[i]) { tmp = bucks[i]; bucks[i] = bucks[j]; bucks[j] = tmp }
        }
      }
      for (i = 1; i <= nb; i++) {
        b = bucks[i]
        printf "%s\t%.4f\t%d\n", b, exp(bucket_sum_log[b] / bucket_n[b]), bucket_n[b]
      }
      if (all_n > 0) {
        printf "ALL\t%.4f\t%d\n", exp(all_sum_log / all_n), all_n
      }
      print ""
      print "# codec/alpha geometric-mean ratios"
      print "bucket\tgeomean_ratio\tn"
      nc = 0
      for (c in codec_n) { codecs[++nc] = c }
      for (i = 1; i <= nc; i++) {
        for (j = i + 1; j <= nc; j++) {
          if (codecs[j] < codecs[i]) { tmp = codecs[i]; codecs[i] = codecs[j]; codecs[j] = tmp }
        }
      }
      for (i = 1; i <= nc; i++) {
        c = codecs[i]
        printf "%s\t%.4f\t%d\n", c, exp(codec_sum_log[c] / codec_n[c]), codec_n[c]
      }
      if (all_n > 0) {
        printf "ALL\t%.4f\t%d\n", exp(all_sum_log / all_n), all_n
      }
    }
  ' "$unified"
} >"$work/final.tsv"

if [ -n "$output" ]; then
  case "$output" in
    /*) dest="$output" ;;
    *) dest="$root/$output" ;;
  esac
  case "$dest" in
    "$root/.zig-cache"/*|"$root"/*) ;;
    *)
      printf 'webp-rust-bench: refusing to write outside the worktree: %s\n' "$dest" >&2
      exit 1
      ;;
  esac
  cp "$work/final.tsv" "$dest"
  printf 'webp-rust-bench: wrote %s\n' "$dest" >&2
else
  cat "$work/final.tsv"
fi
