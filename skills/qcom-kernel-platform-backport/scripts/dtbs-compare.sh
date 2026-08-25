#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Answer the question CI's dtb-check asks -- "does this series add any DTB
# schema warning?" -- across every qcom DTB, not just the board being enabled.
# A shared binding can regress another SoC, so validating only the new board
# is not enough.
#
# Unlike CI, build-progress lines are filtered out before the diff, so a
# newly added DTS does not produce a false positive.
#
# Usage:
#   dtbs-compare.sh [--base qcom-6.18.y] [--head HEAD] [--subdir qcom]
#                   [--match REGEX]
#
# Requires: aarch64 cross toolchain and dtschema (dt-validate on PATH).
#
# A full vendor sweep is SLOW: dt-validate is the bottleneck and it is
# effectively serial, so ~300 DTBs takes on the order of an hour per side.
# --match narrows the target list to DTS basenames matching an extended regex,
# which is usually enough:
#
#   dtbs-compare.sh --match '^(monaco|qcs8300)'
#
# That is sound when every binding this series touches is *permissive* --
# widening an enum, relaxing a 'const' into a 'oneOf', extending an allowed
# range. Such a change cannot introduce a warning on a compatible it did not
# already cover, so only boards sharing the SoC dtsi can regress. Check the
# binding diffs before relying on it:
#
#   git diff <base>..<head> -- Documentation/devicetree/bindings/
#
# If any change ADDS a constraint (a new 'required:' entry, a narrowed enum, a
# new 'if/then'), run the full sweep instead -- that is exactly the case where
# an unrelated SoC breaks.

set -euo pipefail

base="qcom-6.18.y"
head_ref="HEAD"
subdir="qcom"
match=""
jobs="$(nproc 2>/dev/null || echo 4)"

while [ $# -gt 0 ]; do
    case "$1" in
        --base) base="$2"; shift 2 ;;
        --head) head_ref="$2"; shift 2 ;;
        --subdir) subdir="$2"; shift 2 ;;
        --match) match="$2"; shift 2 ;;
        -h|--help) sed -n '5,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "error: not inside a git repository" >&2; exit 1; }
if [ ! -f Makefile ] || [ ! -d arch/arm64/boot/dts ]; then
    echo "error: run from the kernel tree root" >&2
    exit 1
fi
command -v dt-validate >/dev/null 2>&1 || {
    echo "error: dt-validate not on PATH (pip install dtschema)" >&2; exit 1; }
for ref in "$base" "$head_ref"; do
    git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
        echo "error: unknown ref '$ref'" >&2; exit 1; }
done

export ARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

workdir="$(mktemp -d)"
base_tree="$workdir/base-tree"
head_tree="$workdir/head-tree"
cleanup() {
    git worktree remove --force "$base_tree" >/dev/null 2>&1 || true
    git worktree remove --force "$head_tree" >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT

# Target list comes from the head tree, so newly added boards are included.
targets=()
skipped=0
while IFS= read -r dts; do
    name="$(basename "${dts%.dts}")"
    if [ -n "$match" ] && ! printf '%s' "$name" | grep -qE "$match"; then
        skipped=$((skipped + 1))
        continue
    fi
    targets+=("${subdir}/${name}.dtb")
done < <(git ls-tree --name-only -r "$head_ref" \
             "arch/arm64/boot/dts/${subdir}/" | grep '\.dts$' | sort)

if [ ${#targets[@]} -eq 0 ]; then
    if [ -n "$match" ]; then
        echo "error: no .dts under arch/arm64/boot/dts/${subdir} matches '$match'" >&2
    else
        echo "error: no .dts found under arch/arm64/boot/dts/${subdir}" >&2
    fi
    exit 1
fi
echo "validating ${#targets[@]} DTB(s) under ${subdir}/ at base and head"
# Never let a narrowed run read as full coverage.
if [ "$skipped" -gt 0 ]; then
    echo "NOTE: --match '$match' skipped $skipped DTB(s); this is NOT full" \
         "coverage. Only valid if every binding change is permissive -- see --help."
fi

# Per-target make invocations: a target missing at base must not abort the run.
# $4 ("strict") makes a failing build fatal. At base a target may legitimately
# not exist yet -- that is the whole point of the series -- but at head every
# DTB must build, or a syntax error would silently yield "no new warnings".
collect() {
    local srcdir="$1" outdir="$2" logfile="$3" strict="$4"
    local raw="${logfile}.raw"
    rm -rf "$outdir"; mkdir -p "$outdir"
    make -C "$srcdir" O="$outdir" defconfig >/dev/null 2>&1
    : > "$logfile"
    local target rc failed=0
    for target in "${targets[@]}"; do
        set +e
        make -C "$srcdir" O="$outdir" -j"$jobs" CHECK_DTBS=y "$target" \
            > "$raw" 2>&1
        rc=$?
        set -e
        grep -E '^/|^[[:space:]]+from schema' "$raw" >> "$logfile" || true
        if [ "$rc" -ne 0 ] && [ "$strict" = "strict" ]; then
            echo "error: building $target failed at head:" >&2
            tail -n 20 "$raw" >&2
            failed=1
        fi
    done
    rm -f "$raw"
    if [ "$failed" -ne 0 ]; then
        return 1
    fi
    # Normalise the differing output directories so the logs are comparable.
    # Use awk with a literal prefix: a mktemp path contains '.', which would
    # be a regex metacharacter in sed.
    awk -v pfx="$outdir/" '{ if (index($0, pfx) == 1) $0 = "OUT/" substr($0, length(pfx) + 1); print }' \
        "$logfile" | sort -u
}

# Both sides are built from detached worktrees of the named refs, so --head
# validates the reference asked for rather than whatever happens to be checked
# out (and any uncommitted edits in the working tree are excluded on purpose).
git worktree add -q --detach "$base_tree" "$base"
git worktree add -q --detach "$head_tree" "$head_ref"

echo "== base ($base)"
collect "$base_tree" "$workdir/out-base" "$workdir/raw-base" lenient \
    > "$workdir/base.norm"
echo "== head ($head_ref)"
if ! collect "$head_tree" "$workdir/out-head" "$workdir/raw-head" strict \
        > "$workdir/head.norm"; then
    echo
    echo "dtbs-compare: FAIL (a DTB failed to build at head)"
    exit 1
fi

all_new="$(comm -13 "$workdir/base.norm" "$workdir/head.norm" || true)"
gone="$(comm -23 "$workdir/base.norm" "$workdir/head.norm" || true)"

# A board this series ADDS has no counterpart at base, so every warning it
# emits looks new even when it is only inheriting a pre-existing SoC dtsi
# warning that its siblings already produce. That is the same structural false
# positive CI's dtb-check hits, and left alone it fails every enablement
# series. Split those out: a regression is a *new* warning on a board that
# already existed at base.
git ls-tree --name-only -r "$base" "arch/arm64/boot/dts/${subdir}/" \
    | sed -n 's|.*/\([^/]*\)\.dts$|\1|p' | sort -u > "$workdir/boards.base"

new=""; added_board=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    dtb="$(printf '%s' "$line" | sed -n 's|^OUT/[^:]*/\([^/:]*\)\.dtb:.*|\1|p')"
    if [ -n "$dtb" ] && ! grep -qxF "$dtb" "$workdir/boards.base"; then
        added_board="${added_board}${line}"$'\n'
    else
        new="${new}${line}"$'\n'
    fi
done <<< "$all_new"
new="$(printf '%s' "$new" | sed '/^$/d')"
added_board="$(printf '%s' "$added_board" | sed '/^$/d')"

echo
echo "base warnings: $(wc -l < "$workdir/base.norm")" \
     "head warnings: $(wc -l < "$workdir/head.norm")"

if [ -n "$gone" ]; then
    echo
    echo "== warnings FIXED by this series"
    printf '%s\n' "$gone" | { grep -v '^[[:space:]]*from schema' || true; } \
        | sed 's/^/  /'
fi

if [ -n "$added_board" ]; then
    echo
    echo "== warnings on boards ADDED by this series (not regressions)"
    printf '%s\n' "$added_board" | sed 's/^/  /'
    echo "  Check each against a sibling board on the same SoC: if the same"
    echo "  warning already exists there at base, it is inherited from the SoC"
    echo "  dtsi and pre-existing. If it is unique to the new board, fix it."
fi

if [ -n "$new" ]; then
    echo
    echo "== NEW warnings on pre-existing boards -- these would fail CI"
    printf '%s\n' "$new" | sed 's/^/  /'
    echo
    echo "dtbs-compare: FAIL"
    exit 1
fi

echo
if [ -n "$added_board" ]; then
    echo "dtbs-compare: PASS (no regression on pre-existing boards)"
else
    echo "dtbs-compare: PASS (no new schema warnings)"
fi
