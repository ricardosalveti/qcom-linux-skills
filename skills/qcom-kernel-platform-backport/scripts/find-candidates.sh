#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Sweep upstream ranges for commits mentioning a platform's keywords and
# annotate each with where it has got to (released tag, queued in a qcom
# maintainer topic branch, or only in linux-next) and whether the target
# branch already has an equivalent (matched by commit subject).
#
# --upstream takes a comma-separated list, so the qcom SoC tree can be swept
# alongside linux-next; that tree carries platform patches before they reach
# linux-next, and its topic branches name the release they are queued for.
#
# Usage:
#   find-candidates.sh --keywords "agatti,qcm2290,imola" \
#                      [--base qcom-6.18.y] \
#                      [--upstream linux-next/master,qcom/for-next] \
#                      [--since v6.18] [--paths "arch/arm64/boot/dts/qcom"]

set -euo pipefail

base="qcom-6.18.y"
upstream="linux-next/master,qcom/for-next"
since="v6.18"
keywords=""
paths=""

usage() {
    sed -n '5,15p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base) base="$2"; shift 2 ;;
        --upstream) upstream="$2"; shift 2 ;;
        --since) since="$2"; shift 2 ;;
        --keywords) keywords="$2"; shift 2 ;;
        --paths) paths="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

if [ -z "$keywords" ] && [ -z "$paths" ]; then
    echo "error: pass --keywords and/or --paths" >&2
    usage 1
fi

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "error: not inside a git repository" >&2; exit 1; }

IFS=',' read -r -a upstreams <<< "$upstream"
present_upstreams=()
for ref in "${upstreams[@]}"; do
    [ -n "$ref" ] || continue
    if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
        present_upstreams+=("$ref")
    else
        echo "note: skipping unknown ref '$ref'" >&2
        if [ "$ref" = "qcom/for-next" ]; then
            echo "      add the qcom SoC tree to see patches before linux-next:" >&2
            echo "      git remote add qcom https://git.kernel.org/pub/scm/linux/kernel/git/qcom/linux.git" >&2
            echo "      git fetch qcom" >&2
        fi
    fi
done
if [ ${#present_upstreams[@]} -eq 0 ]; then
    echo "error: none of the --upstream refs exist" >&2
    exit 1
fi
for ref in "$base" "$since"; do
    git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
        echo "error: unknown ref '$ref'" >&2; exit 1; }
done

# Subjects already on the target branch, used for the IN-BASE column. Matching
# by subject is deliberate: a backport keeps the subject but changes the SHA.
#
# Branch subjects are not verbatim copies though: a backport carries a
# "UPSTREAM: "/"BACKPORT: " prefix and a squash-merge appends " (#123)", so
# store a normalised copy of each alongside the raw one. Only the known
# backport prefixes are stripped -- a blanket "^WORD: " would also eat
# legitimate subsystem prefixes such as "ASoC: ".
subjects="$(mktemp)"
trap 'rm -f "$subjects"' EXIT
git log --format="%s" "${since}..${base}" \
    | sed -E -e 'p' \
             -e 's/^(UPSTREAM|BACKPORT|FROMGIT|FROMLIST|PENDING|QCLINUX): //' \
             -e 's/ \(#[0-9]+\)$//' \
    > "$subjects"

# Build the commit list: keyword sweep over messages, plus any listed paths.
candidates="$(mktemp)"
trap 'rm -f "$subjects" "$candidates"' EXIT
: > "$candidates"

grep_args=()
if [ -n "$keywords" ]; then
    IFS=',' read -r -a words <<< "$keywords"
    for word in "${words[@]}"; do
        if [ -n "$word" ]; then
            grep_args+=(--grep="$word")
        fi
    done
fi
path_list=()
if [ -n "$paths" ]; then
    IFS=',' read -r -a path_list <<< "$paths"
fi

for ref in "${present_upstreams[@]}"; do
    if [ ${#grep_args[@]} -gt 0 ]; then
        git log --no-merges --format="%H" --regexp-ignore-case \
            "${grep_args[@]}" "${since}..${ref}" >> "$candidates"
    fi
    if [ ${#path_list[@]} -gt 0 ]; then
        git log --no-merges --format="%H" "${since}..${ref}" \
            -- "${path_list[@]}" >> "$candidates"
    fi
done

# Deduplicate while preserving git's newest-first order. Sorting the SHAs
# would order the report by hex digits, which is meaningless, and would then
# need 'tac' (GNU-only) to undo.
awk '!seen[$0]++' "$candidates" > "${candidates}.uniq"
mv "${candidates}.uniq" "$candidates"

total=0
todo=0
printf '%-14s %-18s %-8s %s\n' "COMMIT" "WHERE" "IN-BASE" "SUBJECT"
while read -r sha; do
    [ -n "$sha" ] || continue
    subject="$(git log -1 --format=%s "$sha")"
    # Where has this commit got to? A released tag is the strongest answer;
    # failing that, the qcom topic branch holding it names the release it is
    # queued for (e.g. arm64-for-7.3), which is what decides UPSTREAM vs
    # FROMGIT. 'git describe --contains' exits non-zero for an untagged
    # commit, which under 'set -o pipefail' would abort the sweep, so
    # tolerate it and strip the ~N/^N suffix by parameter expansion.
    release="$(git describe --contains --match 'v[0-9]*' "$sha" 2>/dev/null || true)"
    release="${release%%~*}"
    release="${release%%^*}"
    if [ -z "$release" ]; then
        # The qcom maintainer tags every pull request he sends
        # (qcom-arm64-for-7.3, qcom-clk-for-7.3, ...), so the nearest such
        # tag names both the subsystem and the release the commit is queued
        # for. Do not add --all here: it makes git ignore --match and return
        # the nearest ref of any kind, e.g. a linux-next snapshot tag.
        topic="$(git describe --contains --match 'qcom-*-for-*' \
                     "$sha" 2>/dev/null || true)"
        topic="${topic%%~*}"
        topic="${topic%%^*}"
        if [ -n "$topic" ]; then
            release="${topic#qcom-}"
        else
            # Fall back to whichever of the caller's own --upstream refs
            # contains it, rather than assuming a remote called linux-next.
            release="unmerged"
            for uref in "${present_upstreams[@]}"; do
                if git merge-base --is-ancestor "$sha" "$uref" 2>/dev/null; then
                    case "$uref" in
                        *next*) release="in-next" ;;
                        *) release="in-${uref##*/}" ;;
                    esac
                    break
                fi
            done
        fi
    fi
    if grep -qxF "$subject" "$subjects"; then
        present="yes"
    else
        present="-"
        todo=$((todo + 1))
    fi
    total=$((total + 1))
    printf '%-14s %-18s %-8s %s\n' \
        "$(git rev-parse --short=12 "$sha")" "$release" "$present" "$subject"
done < "$candidates"

echo
echo "$total candidate(s); $todo not present on $base by subject."
echo "Triage each one: needed by the board, a dependency of one you take," \
     "or out of scope (renames, tree-wide sweeps, unrelated features)."
