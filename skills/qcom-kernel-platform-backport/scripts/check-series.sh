#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Pre-flight a backport series against the mechanical rules the qualcomm-linux
# Kernel Checkers enforce, so surprises land here and not on the pull request:
#
#   - subject prefix is one of FROMLIST|FROMGIT|UPSTREAM|BACKPORT
#     (check-patch-compliance rejects anything else, QCLINUX included)
#   - a Link: trailer is present (the checker fetches it with b4)
#   - the original author survived the cherry-pick
#   - the prefix matches what the diff actually did: a commit claiming
#     UPSTREAM/FROMGIT whose content differs from the upstream commit is
#     mislabelled and should say BACKPORT
#   - checkpatch --strict, run the way CI runs it
#
# Usage: check-series.sh [--base qcom-6.18.y] [--head HEAD] [--no-checkpatch]

set -euo pipefail

base="qcom-6.18.y"
head_ref="HEAD"
run_checkpatch=1

while [ $# -gt 0 ]; do
    case "$1" in
        --base) base="$2"; shift 2 ;;
        --head) head_ref="$2"; shift 2 ;;
        --no-checkpatch) run_checkpatch=0; shift ;;
        -h|--help) sed -n '5,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "error: not inside a git repository" >&2; exit 1; }
for ref in "$base" "$head_ref"; do
    git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
        echo "error: unknown ref '$ref'" >&2; exit 1; }
done

status=0
count=0
me="$(git config user.email || true)"
if [ -z "$me" ]; then
    echo "error: git user.email is not set, so the Signed-off-by and" >&2
    echo "       authorship checks cannot run. Configure it with:" >&2
    echo "       git config user.email 'you@example.com'" >&2
    exit 1
fi

echo "== commit hygiene (${base}..${head_ref})"
while read -r sha; do
    [ -n "$sha" ] || continue
    count=$((count + 1))
    subject="$(git log -1 --format=%s "$sha")"
    body="$(git log -1 --format=%B "$sha")"
    short="$(git rev-parse --short=12 "$sha")"

    if ! printf '%s' "$subject" \
            | grep -qE '^(FROMLIST|FROMGIT|UPSTREAM|BACKPORT): '; then
        echo "  [prefix] $short: '$subject'"
        echo "           not FROMLIST/FROMGIT/UPSTREAM/BACKPORT --" \
             "check-patch-compliance will reject it"
        status=1
    fi

    if ! printf '%s' "$body" | grep -q '^Link:'; then
        echo "  [link]   $short: no Link: trailer"
        status=1
    fi

    # Authorship must survive the cherry-pick. Compare against the upstream
    # commit named in the trailer when that object is available locally --
    # that is exact, and unlike "author == me" it neither flags a legitimate
    # backport of your own patch nor misses one another backporter mangled.
    upstream_sha="$(printf '%s' "$body" \
        | sed -n 's/^(cherry picked from commit \([0-9a-f]\{7,40\}\)).*/\1/p' \
        | head -1)"
    if [ -n "$upstream_sha" ]; then
        if git rev-parse --verify --quiet "${upstream_sha}^{commit}" >/dev/null; then
            want="$(git log -1 --format='%an <%ae>' "$upstream_sha")"
            got="$(git log -1 --format='%an <%ae>' "$sha")"
            if [ "$want" != "$got" ]; then
                echo "  [author] $short: author is '$got' but upstream" \
                     "${upstream_sha:0:12} is '$want'"
                status=1
            fi
        else
            echo "  [author] $short: cannot verify authorship," \
                 "upstream ${upstream_sha:0:12} not in this repository" >&2
        fi
    fi

    # Does the prefix match what the commit actually did? A cherry-pick can
    # quietly diverge from the posted patch without ever conflicting: git's
    # rename detection lands it on a differently-named file, or the 3-way merge
    # drops a hunk that is already present. Both leave a commit labelled
    # UPSTREAM whose diff no longer matches upstream -- which is what
    # check-patch-compliance compares, so it fails there instead of here.
    #
    # Compare added/removed lines only. File paths, index lines and hunk
    # offsets legitimately differ on a backport and are not interesting.
    # Only UPSTREAM/FROMGIT are checked: a BACKPORT whose added lines match
    # upstream exactly is still correctly labelled, because the divergence that
    # made it conflict is usually in the surrounding context, which this
    # comparison deliberately ignores.
    case "$subject" in
    UPSTREAM:*|FROMGIT:*)
        if [ -n "$upstream_sha" ] \
           && git rev-parse --verify --quiet "${upstream_sha}^{commit}" >/dev/null
        then
            want_diff="$(git show --format= "$upstream_sha" \
                | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)"
            got_diff="$(git show --format= "$sha" \
                | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)"
            if [ "$want_diff" != "$got_diff" ]; then
                echo "  [prefix] $short: content differs from upstream" \
                     "${upstream_sha:0:12} -- label it BACKPORT and note why"
                status=1
            fi
        fi ;;
    esac

    # Match the Signed-off-by trailers literally with grep -F: an email may
    # contain '.' or '+', which would be regex metacharacters if it were
    # interpolated into a pattern.
    if ! git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$sha" \
            | grep -qF "<${me}>"; then
        echo "  [sob]    $short: missing your Signed-off-by"
        status=1
    fi
done < <(git rev-list --no-merges "${base}..${head_ref}")

echo "  $count commit(s) checked"

echo "== prefix breakdown"
git log --format='%s' --no-merges "${base}..${head_ref}" \
    | sed -n 's/^\([A-Z]\{1,\}\):.*/\1/p' | sort | uniq -c | sed 's/^/  /'

if [ "$run_checkpatch" -eq 1 ] && [ -x scripts/checkpatch.pl ]; then
    echo "== checkpatch --strict (as CI runs it)"
    # CI fails on any error/warning/check; report the totals and the findings.
    cp_log="$(mktemp -t checkpatch-series.XXXXXX)"
    cp_failed=0
    ./scripts/checkpatch.pl --strict --summary-file \
        --ignore FILE_PATH_CHANGES --git "${base}..${head_ref}" \
        > "$cp_log" 2>&1 || cp_failed=1
    if [ "$cp_failed" -ne 0 ]; then
        status=1
        grep -E '^(WARNING|ERROR|CHECK):' "$cp_log" \
            | sort | uniq -c | sort -rn | sed 's/^/  /' || true
        # Kept deliberately: the summary above is truncated by design and the
        # full log is what you read next. Removed below when there is nothing
        # to look at, so a clean run leaves no file behind.
        echo "  full log kept at: $cp_log"
        echo "  note: warnings inherited verbatim from an upstream commit cannot"
        echo "        be fixed without changing the diff, which then fails"
        echo "        check-patch-compliance. Justify those in the PR instead."
        echo "  note: expect CI to report MORE than this. 'Unknown commit id'"
        echo "        warnings for Fixes: tags do not appear here, because this"
        echo "        clone has the upstream objects that CI's tree does not."
    else
        echo "  clean"
        rm -f "$cp_log"
    fi
elif [ "$run_checkpatch" -eq 1 ]; then
    echo "== checkpatch skipped (run from the kernel tree root)"
fi

if [ "$status" -ne 0 ]; then
    echo
    echo "check-series: FAIL -- issues above will surface in CI"
else
    echo
    echo "check-series: PASS"
fi
exit "$status"
