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
# Caveat for honest comparison: dwebp/cwebp read and write real files, so their
# times include input read + output formatting/write; `zig build bench` times
# decode/encode in memory only. The ratio is indicative of codec speed, not an
# exact apples-to-apples measurement — note that whenever you record it.
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

# Default representative set spanning the asset classes, if present.
if [ "${#files[@]}" -eq 0 ]; then
  for f in \
    testdata/photos/photo_foliage.webp \
    testdata/photos/photo_signage.webp \
    testdata/libwebp-test-data/bryce.webp \
    testdata/libwebp-test-data/lossless_big_random_alpha.webp \
    testdata/libwebp-test-data/lossless_color_transform.webp \
    testdata/libwebp-test-data/lossy_extreme_probabilities.webp \
    testdata/libwebp-test-data/alpha_color_cache.webp; do
    [ -f "$f" ] && files+=("$f")
  done
fi

tmp_pam="$(mktemp --suffix=.pam)"
tmp_png="$(mktemp --suffix=.png)"
trap 'rm -f "$tmp_pam" "$tmp_png"' EXIT

# Best-of-`runs` wall time of "$@" in integer milliseconds, via GNU date ns.
min_ms() {
  local best=-1 t0 t1 ms
  for _ in $(seq 1 "$runs"); do
    t0=$(date +%s%N)
    "$@" >/dev/null 2>&1
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    if [ "$best" -lt 0 ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
  done
  echo "$best"
}

printf '# webp-bench: best of %d runs, milliseconds. dwebp = decode to PAM; cwebp = re-encode.\n' "$runs"
printf '%-44s %12s %14s %14s\n' "file" "dwebp_ms" "cwebp_ll_ms" "cwebp_q75_ms"

for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "SKIP missing: $f" >&2; continue; }

  d="-"; cl="-"; cq="-"
  if has_tool dwebp; then
    d=$(min_ms dwebp "$f" -pam -o "$tmp_pam")
  fi
  # Re-encode needs pristine source pixels; decode once to PAM, then time cwebp
  # on that. cwebp accepts PAM input.
  if has_tool cwebp && has_tool dwebp; then
    dwebp "$f" -pam -o "$tmp_pam" >/dev/null 2>&1
    cl=$(min_ms cwebp -lossless "$tmp_pam" -o "$tmp_png")
    cq=$(min_ms cwebp -q 75 "$tmp_pam" -o "$tmp_png")
  fi

  printf '%-44s %12s %14s %14s\n' "$(basename "$f")" "$d" "$cl" "$cq"
done
