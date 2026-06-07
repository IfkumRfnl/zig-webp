#!/usr/bin/env sh
set -eu

usage() {
    cat <<'USAGE'
Usage:
  tools/webp-oracle.sh check
  tools/webp-oracle.sh decode OUT_DIR FILE.webp [FILE.webp ...]
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
