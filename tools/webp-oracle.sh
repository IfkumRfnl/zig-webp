#!/usr/bin/env sh
set -eu

usage() {
    cat <<'USAGE'
Usage:
  tools/webp-oracle.sh check
  tools/webp-oracle.sh decode OUT_DIR FILE.webp [FILE.webp ...]
  tools/webp-oracle.sh compare-vp8l OUT_DIR FILE.webp [FILE.webp ...]
  tools/webp-oracle.sh compare-vp8l-corpus OUT_DIR [CORPUS_DIR]
  tools/webp-oracle.sh compare-alpha OUT_DIR FILE.webp [FILE.webp ...]
  tools/webp-oracle.sh compare-alpha-corpus OUT_DIR [CORPUS_DIR]
  tools/webp-oracle.sh compare-yuv-nofilter OUT_DIR FILE.webp [FILE.webp ...]
  tools/webp-oracle.sh compare-yuv-nofilter-corpus OUT_DIR [CORPUS_DIR]
  tools/webp-oracle.sh compare-yuv OUT_DIR FILE.webp [FILE.webp ...]
  tools/webp-oracle.sh compare-yuv-corpus OUT_DIR [CORPUS_DIR]
  tools/webp-oracle.sh compare-rgb OUT_DIR FILE.webp [FILE.webp ...]
  tools/webp-oracle.sh compare-rgb-corpus OUT_DIR [CORPUS_DIR]
  tools/webp-oracle.sh compare-rgb-nofilter OUT_DIR FILE.webp [FILE.webp ...]
  tools/webp-oracle.sh compare-rgb-nofilter-corpus OUT_DIR [CORPUS_DIR]
  tools/webp-oracle.sh compare-anim OUT_DIR FILE.webp [FILE.webp ...]
  tools/webp-oracle.sh compare-anim-corpus OUT_DIR [CORPUS_DIR]
  tools/webp-oracle.sh encode INPUT_IMAGE OUTPUT.webp
  tools/webp-oracle.sh roundtrip INPUT_IMAGE OUT_DIR
  tools/webp-oracle.sh compare-encode-corpus REPORT.tsv
  tools/webp-oracle.sh compare-encode-lossy [CORPUS_DIR]

Runs optional local libwebp tools when they are installed. Missing tools are
reported as skips so this script can live outside the package dependency graph.
USAGE
}

has_tool() {
    command -v "$1" >/dev/null 2>&1
}

check() {
    for tool in dwebp cwebp webpinfo; do
        if has_tool "$tool"; then
            printf '%s\t%s\n' "$tool" "$(command -v "$tool")"
        else
            printf '%s\t%s\n' "$tool" "SKIP: not installed"
        fi
    done
}

# Compare this library's lossless encoder against `cwebp -lossless` on the
# real-image encode corpus. Reads an encode-report TSV (our sizes; produced by
# `zig build encode-report -- --with-corpus REPORT.tsv`) and, for every photo
# and in-tree-corpus row, re-encodes the same source with cwebp and pairs the
# sizes. Both encoders are lossless so the decoded pixels are bit-identical;
# size is the only metric here (PSNR is reserved for the step-8 lossy oracle).
compare_encode_corpus() {
    report=$1
    if [ ! -f "$report" ]; then
        printf 'error: report TSV not found: %s\n' "$report" >&2
        printf 'generate it with: zig build encode-report -- --with-corpus %s\n' "$report" >&2
        exit 2
    fi
    if ! has_tool cwebp; then
        printf 'cwebp\tSKIP: not installed\n' >&2
        exit 0
    fi

    tmp=$(mktemp -d)
    data="$tmp/data.tsv"
    : >"$data"

    grep -vE '^#|^family' "$report" | while IFS="$(printf '\t')" read -r family name _w _h _fmt _raw our _bpp _psnr _rt; do
        case "$family" in
            photo) dir=testdata/photos ;;
            corpus) dir=testdata/libwebp-test-data ;;
            *) continue ;;
        esac
        src="$dir/$name"
        [ -f "$src" ] || continue
        if cwebp -quiet -lossless "$src" -o "$tmp/cwebp.webp" 2>/dev/null; then
            cwebp_bytes=$(wc -c <"$tmp/cwebp.webp" | tr -d ' ')
            printf '%s\t%s\t%s\t%s\n' "$family" "$name" "$our" "$cwebp_bytes" >>"$data"
        fi
    done

    printf 'family\tname\tour_bytes\tcwebp_bytes\tratio\n'
    awk -F'\t' '
        { printf "%s\t%s\t%s\t%s\t%.4f\n", $1, $2, $3, $4, $3 / $4; r[NR] = $3 / $4; our_total += $3; cwebp_total += $4 }
        END {
            n = NR
            if (n == 0) { print "# no paired files (sources missing or cwebp failed)"; exit }
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (r[j] < r[i]) { t = r[i]; r[i] = r[j]; r[j] = t }
            median = (n % 2) ? r[(n + 1) / 2] : (r[n / 2] + r[n / 2 + 1]) / 2
            printf "# files=%d  median_ratio=%.4f  aggregate_ratio=%.4f  (our/cwebp, <1 = smaller than cwebp)\n", n, median, our_total / cwebp_total
        }' "$data"

    rm -rf "$tmp"
}

# The external half of the step 8a validity gate: every image our lossy encoder
# produces must decode without error under libwebp's `dwebp`. For each still
# source (photos + an in-tree corpus) it encodes with `zig-webp-encode`, decodes
# the result with `dwebp` (the validity check), and pairs the encoded size
# against `cwebp -q -noalpha` on the same color pixels (step 8a drops alpha).
# Requires `zig build` to have produced the encoder binary. Exits non-zero if
# any still source fails to encode, if any output fails to decode, or if no
# outputs were validated.
compare_encode_lossy() {
    corpus_dir=${1:-testdata/libwebp-test-data}
    quality=75
    encoder=zig-out/bin/zig-webp-encode

    if [ ! -x "$encoder" ]; then
        printf 'error: %s not found; build it with `zig build` first\n' "$encoder" >&2
        exit 2
    fi
    if ! has_tool dwebp || ! has_tool cwebp || ! has_tool webpinfo; then
        printf 'dwebp/cwebp/webpinfo\tSKIP: not installed\n' >&2
        exit 0
    fi

    tmp=$(mktemp -d)
    data="$tmp/data.tsv"
    : >"$data"
    invalid=0
    encode_failed=0
    reference_failed=0
    paired=0
    skipped=0

    for entry in "testdata/photos:photo" "$corpus_dir:corpus"; do
        dir=${entry%:*}
        family=${entry#*:}
        [ -d "$dir" ] || continue
        for src in "$dir"/*.webp; do
            [ -f "$src" ] || continue
            name=$(basename "$src")
            rm -f "$tmp/our.webp" "$tmp/our.png" "$tmp/src.png" "$tmp/cwebp.webp"

            if ! webpinfo "$src" >"$tmp/source.webpinfo" 2>/dev/null; then
                printf 'FAIL\twebpinfo\t%s\n' "$src" >&2
                reference_failed=$((reference_failed + 1))
                continue
            fi
            if grep -q '^Chunk ANIM ' "$tmp/source.webpinfo"; then
                skipped=$((skipped + 1))
                continue
            fi

            if ! "$encoder" "$src" "$tmp/our.webp" "$quality" 2>/dev/null; then
                printf 'FAIL\tencode\t%s\n' "$src" >&2
                encode_failed=$((encode_failed + 1))
                continue
            fi

            if dwebp -quiet "$tmp/our.webp" -o "$tmp/our.png" 2>/dev/null; then
                valid=ok
            else
                valid=DWEBP-FAIL
                invalid=$((invalid + 1))
            fi

            # Re-encode the same decoded colors with cwebp for a size reference.
            # Step 8a drops alpha, so the reference encode must do the same.
            if ! dwebp -quiet "$src" -o "$tmp/src.png" 2>/dev/null; then
                printf 'FAIL\tdwebp-source\t%s\n' "$src" >&2
                reference_failed=$((reference_failed + 1))
                continue
            fi
            if ! cwebp -quiet -q "$quality" -noalpha "$tmp/src.png" -o "$tmp/cwebp.webp" 2>/dev/null; then
                printf 'FAIL\tcwebp\t%s\n' "$src" >&2
                reference_failed=$((reference_failed + 1))
                continue
            fi
            our_bytes=$(wc -c <"$tmp/our.webp" | tr -d ' ')
            cwebp_bytes=$(wc -c <"$tmp/cwebp.webp" | tr -d ' ')
            printf '%s\t%s\t%s\t%s\t%s\n' "$family" "$name" "$our_bytes" "$cwebp_bytes" "$valid" >>"$data"
            paired=$((paired + 1))
        done
    done

    printf 'family\tname\tour_bytes\tcwebp_bytes\tvalid\tratio\n'
    awk -F'\t' '
        { printf "%s\t%s\t%s\t%s\t%s\t%.4f\n", $1, $2, $3, $4, $5, $3 / $4
          r[NR] = $3 / $4; our_total += $3; cwebp_total += $4; if ($5 != "ok") bad++ }
        END {
            n = NR
            if (n == 0) { print "# no paired files (sources missing or tools failed)"; exit }
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (r[j] < r[i]) { t = r[i]; r[i] = r[j]; r[j] = t }
            median = (n % 2) ? r[(n + 1) / 2] : (r[n / 2] + r[n / 2 + 1]) / 2
            printf "# files=%d  dwebp_invalid=%d  median_ratio=%.4f  aggregate_ratio=%.4f  (our/cwebp -q -noalpha at matched quality)\n", n, bad + 0, median, our_total / cwebp_total
        }' "$data"

    status=0
    if [ "$paired" -eq 0 ]; then
        printf 'compare-encode-lossy: no files were encoded and validated\n' >&2
        status=1
    fi
    if [ "$encode_failed" -ne 0 ]; then
        printf 'compare-encode-lossy: %d still file(s) failed to encode\n' "$encode_failed" >&2
        status=1
    fi
    if [ "$reference_failed" -ne 0 ]; then
        printf 'compare-encode-lossy: %d reference tool failure(s)\n' "$reference_failed" >&2
        status=1
    fi
    if [ "$skipped" -ne 0 ]; then
        printf 'compare-encode-lossy: skipped %d animated file(s)\n' "$skipped" >&2
    fi
    if [ "$invalid" -ne 0 ]; then
        printf 'compare-encode-lossy: %d file(s) failed dwebp validation\n' "$invalid" >&2
        status=1
    fi

    rm -rf "$tmp"
    exit "$status"
}

decode_one() {
    out_dir=$1
    file=$2
    base=$(basename "$file")
    stem=${base%.*}

    if has_tool webpinfo; then
        webpinfo "$file" >"$out_dir/$stem.webpinfo.txt"
    else
        printf 'webpinfo\tSKIP: not installed\n' >&2
    fi

    if has_tool dwebp; then
        dwebp "$file" -pam -o "$out_dir/$stem.pam" >"$out_dir/$stem.dwebp.log" 2>&1
    else
        printf 'dwebp\tSKIP: not installed\n' >&2
    fi
}

is_lossless_webp() {
    file=$1

    webpinfo "$file" 2>/dev/null | grep -q 'Format: Lossless'
}

compare_vp8l_files() {
    out_dir=$1
    shift

    if ! has_tool dwebp; then
        printf 'dwebp\tSKIP: not installed\n' >&2
        return 0
    fi
    if ! has_tool webpinfo; then
        printf 'webpinfo\tSKIP: not installed\n' >&2
        return 0
    fi

    mkdir -p "$out_dir"
    compared=0
    failed=0
    skipped=0
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            printf 'FAIL\tmissing\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi
        if ! is_lossless_webp "$file"; then
            skipped=$((skipped + 1))
            continue
        fi

        base=$(basename "$file")
        stem=${base%.*}
        oracle="$out_dir/$stem.dwebp.pam"
        actual="$out_dir/$stem.zig-webp.pam"

        if ! dwebp "$file" -pam -o "$oracle" >"$out_dir/$stem.dwebp.log" 2>&1; then
            printf 'FAIL\tdwebp\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi
        if ! zig build decode -- "$file" "$actual" >"$out_dir/$stem.zig-webp.log" 2>&1; then
            printf 'FAIL\tzig-webp\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        compared=$((compared + 1))
        if cmp -s "$oracle" "$actual"; then
            printf 'OK\t%s\n' "$file"
        else
            printf 'DIFF\t%s\n' "$file" >&2
            failed=$((failed + 1))
        fi
    done

    printf 'summary\tcompared=%s\tskipped=%s\tfailed=%s\n' "$compared" "$skipped" "$failed"
    if [ "$compared" -eq 0 ]; then
        printf 'FAIL\tno VP8L files compared\n' >&2
        return 1
    fi
    if [ "$failed" -ne 0 ]; then
        return 1
    fi
}

# Compares decoded ALPH planes against the alpha region of dwebp's stacked
# YUV+alpha PGM output. Files without a static ALPH chunk are skipped via the
# tool's dedicated exit code 3.
compare_alpha_files() {
    out_dir=$1
    shift

    if ! has_tool dwebp; then
        printf 'dwebp\tSKIP: not installed\n' >&2
        return 0
    fi

    alpha_tool=zig-out/bin/zig-webp-alpha
    if ! zig build >/dev/null 2>&1 || [ ! -x "$alpha_tool" ]; then
        printf 'FAIL\tzig build did not produce %s\n' "$alpha_tool" >&2
        return 1
    fi

    mkdir -p "$out_dir"
    compared=0
    failed=0
    skipped=0
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            printf 'FAIL\tmissing\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        base=$(basename "$file")
        stem=${base%.*}
        oracle="$out_dir/$stem.dwebp.pgm"
        actual="$out_dir/$stem.zig-webp.raw"

        status=0
        "$alpha_tool" "$file" "$actual" >"$out_dir/$stem.zig-webp.log" 2>&1 || status=$?
        if [ "$status" -eq 3 ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$status" -ne 0 ]; then
            printf 'FAIL\tzig-webp-alpha\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        if ! dwebp -alpha "$file" -pgm -o "$oracle" >"$out_dir/$stem.dwebp.log" 2>&1; then
            printf 'FAIL\tdwebp\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        plane_bytes=$(wc -c <"$actual")
        plane_bytes=$((plane_bytes))
        compared=$((compared + 1))
        if tail -c "$plane_bytes" "$oracle" | cmp -s - "$actual"; then
            printf 'OK\t%s\n' "$file"
        else
            printf 'DIFF\t%s\n' "$file" >&2
            failed=$((failed + 1))
        fi
    done

    printf 'summary\tcompared=%s\tskipped=%s\tfailed=%s\n' "$compared" "$skipped" "$failed"
    if [ "$compared" -eq 0 ]; then
        printf 'FAIL\tno ALPH files compared\n' >&2
        return 1
    fi
    if [ "$failed" -ne 0 ]; then
        return 1
    fi
}

compare_yuv_files() {
    filter_flag=$1
    out_dir=$2
    shift 2

    if ! has_tool dwebp; then
        printf 'dwebp\tSKIP: not installed\n' >&2
        return 0
    fi

    yuv_tool=zig-out/bin/zig-webp-yuv
    if ! zig build >/dev/null 2>&1 || [ ! -x "$yuv_tool" ]; then
        printf 'FAIL\tzig build did not produce %s\n' "$yuv_tool" >&2
        return 1
    fi

    mkdir -p "$out_dir"
    compared=0
    failed=0
    skipped=0
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            printf 'FAIL\tmissing\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        base=$(basename "$file")
        stem=${base%.*}
        oracle="$out_dir/$stem.dwebp.yuv"
        actual="$out_dir/$stem.zig-webp.raw"

        status=0
        "$yuv_tool" $filter_flag "$file" "$actual" >"$out_dir/$stem.zig-webp.log" 2>&1 || status=$?
        if [ "$status" -eq 3 ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$status" -ne 0 ]; then
            printf 'FAIL\tzig-webp-yuv\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        dwebp_filter_flag=${filter_flag#-}
        if ! dwebp $dwebp_filter_flag -yuv "$file" -o "$oracle" >"$out_dir/$stem.dwebp.log" 2>&1; then
            printf 'FAIL\tdwebp\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        # dwebp appends the alpha plane after Y/U/V for alpha-bearing lossy
        # files, so compare only the leading Y+U+V byte range.
        plane_bytes=$(wc -c <"$actual")
        plane_bytes=$((plane_bytes))
        compared=$((compared + 1))
        if head -c "$plane_bytes" "$oracle" | cmp -s - "$actual"; then
            printf 'OK\t%s\n' "$file"
        else
            printf 'DIFF\t%s\n' "$file" >&2
            failed=$((failed + 1))
        fi
    done

    printf 'summary\tcompared=%s\tskipped=%s\tfailed=%s\n' "$compared" "$skipped" "$failed"
    if [ "$compared" -eq 0 ]; then
        printf 'FAIL\tno lossy files compared\n' >&2
        return 1
    fi
    if [ "$failed" -ne 0 ]; then
        return 1
    fi
}

# Compares fancy-upsampled RGBA (with composed ALPH alpha) against `dwebp -pam`.
# Both tools emit the same PAM header, so whole files are compared. Non-lossy
# files are skipped via exit 3.
compare_rgb_files() {
    filter_flag=$1
    out_dir=$2
    shift 2

    if ! has_tool dwebp; then
        printf 'dwebp\tSKIP: not installed\n' >&2
        return 0
    fi

    rgb_tool=zig-out/bin/zig-webp-rgb
    if ! zig build >/dev/null 2>&1 || [ ! -x "$rgb_tool" ]; then
        printf 'FAIL\tzig build did not produce %s\n' "$rgb_tool" >&2
        return 1
    fi

    mkdir -p "$out_dir"
    compared=0
    failed=0
    skipped=0
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            printf 'FAIL\tmissing\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        base=$(basename "$file")
        stem=${base%.*}
        oracle="$out_dir/$stem.dwebp.pam"
        actual="$out_dir/$stem.zig-webp.pam"

        status=0
        "$rgb_tool" $filter_flag "$file" "$actual" >"$out_dir/$stem.zig-webp.log" 2>&1 || status=$?
        if [ "$status" -eq 3 ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$status" -ne 0 ]; then
            printf 'FAIL\tzig-webp-rgb\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        dwebp_filter_flag=${filter_flag#-}
        if ! dwebp $dwebp_filter_flag -pam "$file" -o "$oracle" >"$out_dir/$stem.dwebp.log" 2>&1; then
            printf 'FAIL\tdwebp\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        compared=$((compared + 1))
        if cmp -s "$oracle" "$actual"; then
            printf 'OK\t%s\n' "$file"
        else
            printf 'DIFF\t%s\n' "$file" >&2
            failed=$((failed + 1))
        fi
    done

    printf 'summary\tcompared=%s\tskipped=%s\tfailed=%s\n' "$compared" "$skipped" "$failed"
    if [ "$compared" -eq 0 ]; then
        printf 'FAIL\tno lossy files compared\n' >&2
        return 1
    fi
    if [ "$failed" -ne 0 ]; then
        return 1
    fi
}

# Compares composited animation frames against `anim_dump -pam`, frame by
# frame. Both emit canvas-sized RGBA PAM with identical headers, so whole files
# are compared. Non-animated files are skipped via the tool's exit code 3.
compare_anim_files() {
    out_dir=$1
    shift

    if ! has_tool anim_dump; then
        printf 'anim_dump\tSKIP: not installed\n' >&2
        return 0
    fi

    anim_tool=zig-out/bin/zig-webp-anim
    if ! zig build >/dev/null 2>&1 || [ ! -x "$anim_tool" ]; then
        printf 'FAIL\tzig build did not produce %s\n' "$anim_tool" >&2
        return 1
    fi

    mkdir -p "$out_dir"
    compared=0
    failed=0
    skipped=0
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            printf 'FAIL\tmissing\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        base=$(basename "$file")
        stem=${base%.*}
        oracle_dir="$out_dir/$stem.oracle"
        actual_dir="$out_dir/$stem.actual"
        rm -rf "$oracle_dir" "$actual_dir"
        mkdir -p "$oracle_dir" "$actual_dir"

        status=0
        "$anim_tool" "$file" "$actual_dir" >"$out_dir/$stem.zig-webp.log" 2>&1 || status=$?
        if [ "$status" -eq 3 ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$status" -ne 0 ]; then
            printf 'FAIL\tzig-webp-anim\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        if ! anim_dump -pam -folder "$oracle_dir" -prefix dump_ "$file" \
            >"$out_dir/$stem.anim_dump.log" 2>&1; then
            printf 'FAIL\tanim_dump\t%s\n' "$file" >&2
            failed=$((failed + 1))
            continue
        fi

        file_failed=0
        frame_index=0
        for actual_frame in "$actual_dir"/frame_*.pam; do
            oracle_frame=$(printf '%s/dump_%04d.pam' "$oracle_dir" "$frame_index")
            if [ ! -f "$oracle_frame" ]; then
                printf 'FAIL\tanim_dump missing frame %s\t%s\n' "$frame_index" "$file" >&2
                file_failed=1
                break
            fi
            if ! cmp -s "$oracle_frame" "$actual_frame"; then
                printf 'DIFF\tframe %s\t%s\n' "$frame_index" "$file" >&2
                file_failed=1
                break
            fi
            frame_index=$((frame_index + 1))
        done

        compared=$((compared + 1))
        if [ "$file_failed" -eq 0 ]; then
            printf 'OK\t%s\t(%s frames)\n' "$file" "$frame_index"
        else
            failed=$((failed + 1))
        fi
    done

    printf 'summary\tcompared=%s\tskipped=%s\tfailed=%s\n' "$compared" "$skipped" "$failed"
    if [ "$compared" -eq 0 ]; then
        printf 'FAIL\tno animated files compared\n' >&2
        return 1
    fi
    if [ "$failed" -ne 0 ]; then
        return 1
    fi
}

mode=${1:-check}
case "$mode" in
    check)
        check
        ;;

    decode)
        if [ "$#" -lt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        mkdir -p "$out_dir"
        shift 2
        for file in "$@"; do
            decode_one "$out_dir" "$file"
        done
        ;;

    compare-vp8l)
        if [ "$#" -lt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        shift 2
        compare_vp8l_files "$out_dir" "$@"
        ;;

    compare-vp8l-corpus)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        corpus_dir=${3:-references/libwebp-test-data}
        compare_vp8l_files "$out_dir" "$corpus_dir"/*.webp
        ;;

    compare-alpha)
        if [ "$#" -lt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        shift 2
        compare_alpha_files "$out_dir" "$@"
        ;;

    compare-alpha-corpus)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        corpus_dir=${3:-references/libwebp-test-data}
        compare_alpha_files "$out_dir" "$corpus_dir"/*.webp
        ;;

    compare-yuv-nofilter)
        if [ "$#" -lt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        shift 2
        compare_yuv_files --nofilter "$out_dir" "$@"
        ;;

    compare-yuv-nofilter-corpus)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        corpus_dir=${3:-references/libwebp-test-data}
        compare_yuv_files --nofilter "$out_dir" "$corpus_dir"/*.webp
        ;;

    compare-yuv)
        if [ "$#" -lt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        shift 2
        compare_yuv_files "" "$out_dir" "$@"
        ;;

    compare-yuv-corpus)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        corpus_dir=${3:-references/libwebp-test-data}
        compare_yuv_files "" "$out_dir" "$corpus_dir"/*.webp
        ;;

    compare-rgb)
        if [ "$#" -lt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        shift 2
        compare_rgb_files "" "$out_dir" "$@"
        ;;

    compare-rgb-corpus)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        corpus_dir=${3:-references/libwebp-test-data}
        compare_rgb_files "" "$out_dir" "$corpus_dir"/*.webp
        ;;

    compare-rgb-nofilter)
        if [ "$#" -lt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        shift 2
        compare_rgb_files --nofilter "$out_dir" "$@"
        ;;

    compare-rgb-nofilter-corpus)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        corpus_dir=${3:-references/libwebp-test-data}
        compare_rgb_files --nofilter "$out_dir" "$corpus_dir"/*.webp
        ;;

    compare-anim)
        if [ "$#" -lt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        shift 2
        compare_anim_files "$out_dir" "$@"
        ;;

    compare-anim-corpus)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$2
        corpus_dir=${3:-references/libwebp-test-data}
        compare_anim_files "$out_dir" "$corpus_dir"/*.webp
        ;;

    encode)
        if [ "$#" -ne 3 ]; then
            usage >&2
            exit 2
        fi
        if has_tool cwebp; then
            cwebp "$2" -o "$3"
        else
            printf 'cwebp\tSKIP: not installed\n' >&2
            exit 0
        fi
        if has_tool webpinfo; then
            webpinfo "$3"
        fi
        ;;

    roundtrip)
        if [ "$#" -ne 3 ]; then
            usage >&2
            exit 2
        fi
        out_dir=$3
        mkdir -p "$out_dir"
        encoded="$out_dir/encoded.webp"
        if has_tool cwebp; then
            cwebp "$2" -o "$encoded"
        else
            printf 'cwebp\tSKIP: not installed\n' >&2
            exit 0
        fi
        decode_one "$out_dir" "$encoded"
        ;;

    compare-encode-corpus)
        if [ "$#" -ne 2 ]; then
            usage >&2
            exit 2
        fi
        compare_encode_corpus "$2"
        ;;

    compare-encode-lossy)
        if [ "$#" -gt 2 ]; then
            usage >&2
            exit 2
        fi
        compare_encode_lossy "${2:-}"
        ;;

    -h|--help|help)
        usage
        ;;

    *)
        usage >&2
        exit 2
        ;;
esac
