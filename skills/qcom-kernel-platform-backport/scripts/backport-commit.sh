#!/usr/bin/env bash
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#
# Cherry-pick an upstream commit onto the current branch the way the
# qualcomm-linux LTS branches expect: original authorship preserved, the
# subject prefixed with UPSTREAM/BACKPORT/FROMGIT/FROMLIST, a
# "(cherry picked from commit ...)" line, an optional adaptation note, and
# the backporter's Signed-off-by last.
#
# Usage:
#   backport-commit.sh <upstream-sha> [PREFIX] [adaptation note]
#
# PREFIX defaults to UPSTREAM. Pass BACKPORT plus a note whenever the patch
# needed adaptation (partial hunk, renamed file, kept local divergence).
#
# The adaptation note is tagged with your short handle. That defaults to the
# local part of user.email, which is often wrong ("first.last" when the branch
# convention is a login name), so set it once per tree:
#
#   git config backport.tag rsalveti
#
# check-patch-compliance also demands a Link: trailer on every commit. Some
# upstream commits have none; this script says so at pick time rather than
# letting you discover it later from check-series.sh.

set -euo pipefail

if [ $# -lt 1 ]; then
    sed -n '5,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

sha="$1"
prefix="${2:-UPSTREAM}"
note="${3:-}"

case "$prefix" in
    UPSTREAM|BACKPORT|FROMGIT|FROMLIST) ;;
    *) echo "error: prefix must be UPSTREAM, BACKPORT, FROMGIT or FROMLIST" >&2
       exit 1 ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "error: not inside a git repository" >&2; exit 1; }
git rev-parse --verify --quiet "${sha}^{commit}" >/dev/null || {
    echo "error: unknown commit '$sha'" >&2; exit 1; }
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree is dirty; commit or stash first" >&2
    exit 1
fi

name="$(git config user.name || true)"
email="$(git config user.email || true)"
if [ -z "$name" ] || [ -z "$email" ]; then
    echo "error: set user.name and user.email in git config" >&2
    exit 1
fi

full="$(git rev-parse "$sha")"
tag="$(git config backport.tag || true)"
[ -n "$tag" ] || tag="$(echo "$email" | cut -d@ -f1)"

# Report a missing Link: before touching the branch, so the fix can be planned
# together with the pick rather than found later by check-series.sh.
upstream_body="$(git log -1 --format=%B "$full")"
link_hint=""
if ! printf '%s' "$upstream_body" | grep -q '^[[:space:]]*Link:'; then
    msgid="$(printf '%s' "$upstream_body" \
        | sed -n 's/^[[:space:]]*Message-\([Ii][Dd]\):[[:space:]]*<\{0,1\}\([^>]*\)>\{0,1\}[[:space:]]*$/\2/p' \
        | head -1)"
    if [ -n "$msgid" ]; then
        link_hint="https://lore.kernel.org/r/${msgid}"
        echo "note: upstream ${full:0:12} has no Link:, but carries a Message-ID." >&2
        echo "      Add after the cherry-pick trailer:" >&2
        echo "        Link: $link_hint" >&2
    else
        cat >&2 <<'LINKEOF'
note: the upstream commit has no Link: and no Message-ID. check-patch-compliance
      requires one, so recover it before opening the PR. lore.kernel.org is behind
      Anubis bot protection (WebFetch and plain curl both get challenged, including
      the ?x=A atom endpoint), so query patchwork instead:

        curl -sS -G "https://patchwork.kernel.org/api/1.2/patches/" \
          --data-urlencode "q=<exact commit subject>" --data-urlencode "order=-date"

      Confirm the hit before trusting it -- subjects repeat across reposts and
      across unrelated commits. Two checks that work: the posting timestamp should
      equal the commit's author date in UTC (git log -1 --format=%ad --date=iso),
      and patchwork's per-patch endpoint returns a "diff" field you can compare
      against git show -- the same comparison b4 makes. Then use
      Link: https://lore.kernel.org/r/<msgid>
LINKEOF
    fi
fi

# Plain cherry-pick (never -n): this is what preserves the original author.
# -x appends the "(cherry picked from commit ...)" line for us.
if ! git cherry-pick -x "$full"; then
    cat >&2 <<EOF

Cherry-pick stopped with conflicts -- an adaptation is needed, so this is a
BACKPORT. Finish it by hand; do NOT re-run this script afterwards, because
'git cherry-pick --continue' creates the commit itself and a second run would
try to pick $full again.

  1. resolve the conflicts and 'git add' the files
  2. git cherry-pick --continue      # keeps the original author
  3. git commit --amend              # then edit the message to:
       - prefix the subject with "BACKPORT: " -- not "$prefix: ", because
         the patch no longer applies as posted (if your resolution ends up
         byte-identical to upstream, "UPSTREAM: " is still accurate)
       - keep the "(cherry picked from commit $full)" line
       - describe the adaptation in a "[$tag: ...]" note
       - end with "Signed-off-by: $name <$email>"

Note that 'git commit --amend' preserves the existing author, so do not pass
--author unless you are repairing authorship that was already lost.
EOF
    exit 1
fi

msg="$(mktemp)"
trap 'rm -f "$msg"' EXIT
{
    printf '%s: %s\n\n' "$prefix" "$(git log -1 --format=%s HEAD)"
    git log -1 --format=%b HEAD
    if [ -n "$link_hint" ]; then
        printf 'Link: %s\n' "$link_hint"
        printf '[%s: add the Link: trailer, which the upstream commit is missing]\n' \
            "$tag"
    fi
    if [ -n "$note" ]; then
        printf '[%s: %s]\n' "$tag" "$note"
    fi
    printf 'Signed-off-by: %s <%s>\n' "$name" "$email"
} > "$msg"

# --amend keeps the author of the commit being amended, which is the upstream
# author the cherry-pick just installed. Do not add --author here.
git commit --quiet --amend --no-edit --file "$msg"

git log -1 --format='%h | A:%an <%ae> | C:%cn | %s'
