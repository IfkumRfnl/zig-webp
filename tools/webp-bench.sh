#!/usr/bin/env bash
#
# webp-bench.sh — time libwebp's dwebp/cwebp over the same files this library's
# `zig build bench` measures, so a same-machine ratio can be read off by hand.
#
# This is the libwebp *side* of the comparison only. It is deliberately
# decoupled from the Zig harness (which measures this library in memory): run
# both on the same machine in the same session and pair the rows yourself.
# Like tools/webp-oracle.sh it SKIPs gracefully when the libwebp CLI tools are
# absent — it never becomes a build dependency, and it is not wired into CI
# (timing is environment-dependent and would flake).
#
# Caveat for honest comparison: the wall-clock columns (decode_ms, cwebp_*)
# include input read + output formatting/write because dwebp/cwebp touch real
# files; `zig build bench` times decode/encode in memory only, so those ratios
# are indicative. The decode_int_ms column does not carry that caveat — it is
# dwebp's self-reported internal decode time via `-v`, excluding file I/O and
# PAM/PNG formatting.
#
# Usage:
#   tools/webp-bench.sh [-n RUNS] [FILE.webp ...]
# With no FILE arguments a representative default set from testdata/ is used.
# Reports the best (minimum) wall-clock time of RUNS runs per file (RUNS=5).

set -u

runs=5
files=()

while [ $# -gt 0 ]; do
  case "$1" in
    -n) runs="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) files+=("$1"); shift ;;
  esac
done

has_tool() { command -v "$1" >/dev/null 2>&1; }

if ! has_tool dwebp && ! has_tool cwebp; then
  echo "SKIP: neither dwebp nor cwebp installed; cannot run the libwebp comparison." >&2
  exit 0
fi

# Default representative set spanning the asset classes, if present — including
# an animation, which `zig-webp-bench` measures via `decodeAnimation`; here it is
# timed with `anim_dump` (the libwebp animation decoder), not `dwebp`.
if [ "${#files[@]}" -eq 0 ]; then
  for f in \
    testdata/photos/photo_foliage.webp \
    testdata/photos/photo_signage.webp \
    testdata/libwebp-test-data/bryce.webp \
    testdata/libwebp-test-data/lossless_big_random_alpha.webp \
    testdata/libwebp-test-data/lossless_color_transform.webp \
    testdata/libwebp-test-data/lossy_extreme_probabilities.webp \
    testdata/libwebp-test-data/alpha_color_cache.webp \
    testdata/animation/anim_minimized_lossless.webp; do
    [ -f "$f" ] && files+=("$f")
  done
fi

tmp_pam="$(mktemp --suffix=.pam)"
tmp_png="$(mktemp --suffix=.png)"
tmp_dir="$(mktemp -d)"
trap 'rm -f "$tmp_pam" "$tmp_png"; rm -rf "$tmp_dir"' EXIT

# Best-of-`runs` wall time of "$@" in integer milliseconds, via GNU date ns.
# A nonzero exit from the timed command means the libwebp tool could not handle
# this fixture, so report "FAIL" rather than a bogus elapsed time that could be
# copied into a ratio.
min_ms() {
  local best=-1 t0 t1 ms rc
  for _ in $(seq 1 "$runs"); do
    t0=$(date +%s%N)
    "$@" >/dev/null 2>&1
    rc=$?
    t1=$(date +%s%N)
    if [ "$rc" -ne 0 ]; then echo "FAIL"; return 0; fi
    ms=$(( (t1 - t0) / 1000000 ))
    if [ "$best" -lt 0 ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
  done
  echo "$best"
}

# Best-of-`runs` of dwebp's self-reported internal decode time for still "$1",
# in integer milliseconds. Parses the "Time to decode picture: Xs" line from
# `dwebp -v`. Integer conversion truncates toward zero, so any genuine
# sub-millisecond internal time becomes 0 (a 1 ms quantization floor, not a
# missing-line failure). Nonzero dwebp exit or a missing/unparseable timing
# line → "FAIL" (never conflate with quantized 0).
min_internal_decode_ms() {
  local f="$1" best=-1 out secs ms rc
  for _ in $(seq 1 "$runs"); do
    out=$(dwebp -v "$f" -o /dev/null 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then echo "FAIL"; return 0; fi
    secs=$(printf '%s\n' "$out" | sed -n 's/.*[Tt]ime to decode picture: *\([0-9.]*\)s.*/\1/p')
    if ! ms=$(printf '%s\n' "$secs" | awk 'NF { printf "%d", ($1 + 0) * 1000; found = 1; exit } END { if (!found) exit 1 }'); then
      echo "FAIL"; return 0
    fi
    if [ "$best" -lt 0 ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
  done
  echo "$best"
}

# An animation if webpinfo reports an ANMF frame chunk. Without webpinfo we
# cannot tell, so treat it as a still (dwebp will then FAIL it, reported as such).
is_animation() {
  has_tool webpinfo && webpinfo "$1" 2>/dev/null | grep -q "ANMF"
}

printf '# webp-bench: best of %d runs, milliseconds. decode = dwebp (still) / anim_dump (animation); decode_int_ms = dwebp self-reported decode time (excludes file I/O and PAM/PNG formatting); cwebp = re-encode.\n' "$runs"
printf '%-44s %12s %14s %14s %14s\n' "file" "decode_ms" "decode_int_ms" "cwebp_ll_ms" "cwebp_q75_ms"

for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "SKIP missing: $f" >&2; continue; }

  d="-"; di="-"; cl="-"; cq="-"
  if is_animation "$f"; then
    # Animation: time the libwebp animation decoder. Pass -pam so it writes raw
    # PAM frames; without it anim_dump defaults to PNG output, whose compression
    # cost would inflate decode_ms vs the still path's `dwebp -pam` and the Zig
    # benchmark's in-memory decode. Re-encode is not an apples-to-apples
    # single-image comparison, so leave the cwebp columns n/a.
    # decode_int_ms is "-" — anim_dump has no equivalent internal timer.
    if has_tool anim_dump; then
      d=$(min_ms anim_dump -pam -folder "$tmp_dir" "$f")
    fi
  else
    if has_tool dwebp; then
      d=$(min_ms dwebp "$f" -pam -o "$tmp_pam")
      di=$(min_internal_decode_ms "$f")
    fi
    # Re-encode needs pristine source pixels; decode once to PAM, then time cwebp
    # on that. cwebp accepts PAM input.
    if has_tool cwebp && has_tool dwebp && dwebp "$f" -pam -o "$tmp_pam" >/dev/null 2>&1; then
      cl=$(min_ms cwebp -lossless "$tmp_pam" -o "$tmp_png")
      cq=$(min_ms cwebp -q 75 "$tmp_pam" -o "$tmp_png")
    fi
  fi

  printf '%-44s %12s %14s %14s %14s\n' "$(basename "$f")" "$d" "$di" "$cl" "$cq"
done
