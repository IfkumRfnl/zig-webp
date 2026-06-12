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
  tools/webp-oracle.sh encode INPUT_IMAGE OUTPUT.webp
  tools/webp-oracle.sh roundtrip INPUT_IMAGE OUT_DIR

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

    -h|--help|help)
        usage
        ;;

    *)
        usage >&2
        exit 2
        ;;
esac
