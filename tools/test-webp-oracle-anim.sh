#!/usr/bin/env sh
# Offline regression tests for the shell comparator, using decoder test doubles.
# Run with `sh tools/test-webp-oracle-anim.sh`; ORACLE_SHELL selects the shell
# used to execute webp-oracle.sh (for example, bash or dash).
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
oracle_script=${ORACLE_SCRIPT:-$script_dir/webp-oracle.sh}
oracle_shell=${ORACLE_SHELL:-sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
work="$tmp/work with spaces"
mkdir -p "$work/bin" "$work/zig-out/bin"

cat >"$work/bin/zig" <<'TOOL'
#!/usr/bin/env sh
[ "$#" -eq 1 ] && [ "$1" = build ]
TOOL
cat >"$work/bin/anim_dump" <<'TOOL'
#!/usr/bin/env sh
set -eu
[ "$1" = -pam ] && [ "$2" = -folder ] && [ "$4" = -prefix ]
# Intentional word splitting: the test supplies a space-separated index list.
for index in $ORACLE_FRAMES; do
    cp "$TEST_PAM" "$3/$5$index.pam"
done
TOOL
cat >"$work/zig-out/bin/zig-webp-anim" <<'TOOL'
#!/usr/bin/env sh
set -eu
# Intentional word splitting: the test supplies a space-separated index list.
for index in $ACTUAL_FRAMES; do
    cp "$TEST_PAM" "$2/frame_$index.pam"
done
if [ "$DIFFERENT_PIXELS" -eq 1 ]; then
    cp "$TEST_OTHER_PAM" "$2/frame_0001.pam"
fi
TOOL
chmod +x "$work/bin/zig" "$work/bin/anim_dump" "$work/zig-out/bin/zig-webp-anim"

# Valid 1x1 RGBA PAMs. The input WebP is only an opaque argument to the doubles.
printf 'P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n\377\000\000\377' >"$work/red.pam"
printf 'P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n\000\377\000\377' >"$work/green.pam"
touch "$work/input.webp"
PATH="$work/bin:$PATH"
TEST_PAM="$work/red.pam"
TEST_OTHER_PAM="$work/green.pam"
export PATH TEST_PAM TEST_OTHER_PAM

passed=0
failed=0
run_case() {
    name=$1
    ACTUAL_FRAMES=$2
    ORACLE_FRAMES=$3
    expected=$4
    DIFFERENT_PIXELS=${5:-0}
    export ACTUAL_FRAMES ORACLE_FRAMES DIFFERENT_PIXELS
    status=0
    (cd "$work" && "$oracle_shell" "$oracle_script" compare-anim out input.webp) \
        >"$work/result.log" 2>&1 || status=$?
    if [ "$expected" -eq 0 ]; then
        summary='summary	compared=1	skipped=0	failed=0'
    else
        summary='summary	compared=1	skipped=0	failed=1'
    fi
    if [ "$status" -eq "$expected" ] && grep -Fqx "$summary" "$work/result.log"; then
        printf 'PASS\t%s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'FAIL\t%s\texit=%s expected=%s\n' "$name" "$status" "$expected" >&2
        cat "$work/result.log" >&2
        failed=$((failed + 1))
    fi
}

run_case 'matching single frame' '0000' '0000' 0
run_case 'matching two frames' '0000 0001' '0000 0001' 0
run_case 'missing trailing actual frame' '0000' '0000 0001' 1
run_case 'extra trailing actual frame' '0000 0001 0002' '0000 0001' 1
run_case 'gap in actual indices' '0000 0002' '0000 0001' 1
run_case 'gap in oracle indices' '0000 0001' '0000 0002' 1
run_case 'matching gaps in both sequences' '0000 0002' '0000 0002' 1
run_case 'actual starts at one' '0001 0002' '0000 0001' 1
run_case 'oracle starts at one' '0000 0001' '0001 0002' 1
run_case 'noncanonical actual index' '0 0001' '0000 0001' 1
run_case 'noncanonical oracle index' '0000 0001' '0 0001' 1
run_case 'extra nonindexed actual frame' '0000 0001 extra' '0000 0001' 1
run_case 'extra nonindexed oracle frame' '0000 0001' '0000 0001 extra' 1
run_case 'empty actual sequence' '' '0000' 1
run_case 'empty oracle sequence' '0000' '' 1
run_case 'both sequences empty' '' '' 1
run_case 'different pixels' '0000 0001' '0000 0001' 1 1

printf '%s passed; %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
