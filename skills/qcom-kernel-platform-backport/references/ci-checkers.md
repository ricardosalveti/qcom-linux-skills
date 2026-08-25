# The qualcomm-linux Kernel Checkers, from a backporter's point of view

The `Kernel Checkers` workflow lives in
[qualcomm-linux/kernel-config](https://github.com/qualcomm-linux/kernel-config)
and runs the scripts from
[qualcomm-linux/kernel-checkers](https://github.com/qualcomm-linux/kernel-checkers)
over the `base..head` range of a pull request. Read the scripts — they are
short, and knowing exactly what they assert saves a lot of guessing:

```bash
gh repo clone qualcomm-linux/kernel-checkers -- --depth 1
gh run view <run-id> --repo qualcomm-linux/kernel-config
gh run view --repo qualcomm-linux/kernel-config --job <job-id> --log
```

Logs are only downloadable once the whole run finishes.

A board-enablement series will usually not go fully green. Triage each failure
into *real* (fix it) or *structural* (justify it) — and never assume which,
because both kinds show up in the same run.

## dtb-check

Builds every impacted DTB at base and at head, then diffs the two logs:

```bash
run_in_kmake_image make -j"$(nproc)" O="$temp_out" CHECK_DTBS=y "$target" >> "$log_file" 2>&1
...
log_summary=$(grep -vFf "$base_log_file" "$head_log_file")
```

**Real failures** look like schema messages naming a DTB and a binding. Take
them seriously even when the DTB is not yours: a binding you backported may be
shared with another SoC. Adding a property to a schema's global `required:`
list regresses every other compatible that matches the same schema.

**Structural failure**: because the logs capture *all* make output, a newly
added DTS contributes a line the base pass cannot produce —

```
Log Summary: Test failed
  DTC [C] arch/arm64/boot/dts/qcom/<board>.dtb
```

That is build progress, not a warning; it survives `grep -vFf` because there is
no counterpart at base. Every pre-existing board emits the line in both passes
and is filtered correctly. So the job fails for any series that adds a board
DTS, however clean the schema validation is.

Prove the distinction with `scripts/dtbs-compare.sh`, which filters progress
lines before diffing, and quote its numbers in the PR. The upstream fix worth
suggesting is to filter in the checker itself:

```bash
run_in_kmake_image make -j"$(nproc)" O="$temp_out" CHECK_DTBS=y "$target" 2>&1 \
  | grep -vE '^\s*(DTC|DTCO|LINT|CHECK|SCHEMA|UPD|GEN|CALL|SYNC)\b' >> "$log_file"
```

### Warnings you cannot reproduce locally

CI runs inside `kmake-image` with its own `dtschema`, and it does not log the
version. A different `dtschema` sees different things, so "clean here, warnings
there" is a real outcome and not proof you missed something.

Seen in practice: CI reported `iommu-map:2: [0, 1] is too short` on every board
of an SoC family, while local runs with `dtschema` 2026.6 produced **zero**
`iommu-map` warnings at either base or head. The DT was correct — the SMMU had
`#iommu-cells = <2>`, so the five-cell entries the series backported are the
required form, and `qcom/for-next` carried byte-identical DT across a dozen
platforms.

Before treating such a warning as yours to fix:

1. check whether upstream carries the same DT (`git show <upstream-ref>:<file>`)
   — if the warning is inherent to an upstream change, every platform in that
   series has it and the fix belongs upstream, not in your backport;
2. record your local `dtschema` version (`pip show dtschema`) and say in the PR
   that you could not reproduce it, rather than asserting a mechanism you have
   not observed;
3. ask whoever owns the CI image which `dtschema` it ships. That single fact
   usually settles it, and it is not recoverable from the job log.

## checkpatch

```bash
scripts/checkpatch.pl --strict --summary-file --ignore FILE_PATH_CHANGES --git $base..$head
```

The job fails if **any** commit reports a non-zero error, warning or check
count. For a series of verbatim cherry-picks that is effectively unreachable,
because upstream commits carry their own style noise. Recurring cases:

| Warning | Why a backport hits it |
|---|---|
| `Unknown commit id 'abc123'` | An upstream `Fixes:` tag. The referenced commit may well be *in your series*, but under a backport SHA, so checkpatch cannot resolve the mainline id. Rewriting the tag to the local SHA silences it and destroys upstream traceability — don't. |
| `line length of N exceeds 100 columns` | Verbatim upstream content. Re-indenting changes the diff, which then fails `check-patch-compliance`. |
| `Invalid email format for stable` | Verbatim upstream `Cc: stable <stable@kernel.org>` trailer. |
| `Reported-by: should be immediately followed by Closes:` | Verbatim upstream message. |
| `Prefer a maximum 75 chars per line` | Verbatim upstream message. |

**Genuinely worth fixing**: `DT compatible string vendor "<x>" appears
un-documented`. That means a real missing dependency — the vendor prefix patch
in `Documentation/devicetree/bindings/vendor-prefixes.yaml`. Backport it.

Note that running checkpatch locally under-reports compared with CI. A working
clone has mainline and linux-next as remotes, so checkpatch resolves the
mainline SHAs in `Fixes:` tags and stays quiet; CI's tree does not have those
objects and reports `Unknown commit id` for each. Measured on one series: 27
findings locally, 29 in CI, the difference being exactly two `Unknown commit
id` lines. Do not read a cleaner local run as a cleaner CI run.

One of those two referenced a commit *in the same series* — a later fix carried
`Fixes:` pointing at the mainline SHA of a board commit the series itself
backports. It is unresolvable in CI by construction, and rewriting it to the
local SHA would break the trace to upstream. Leave it.

In the PR, map each remaining warning to the commit and state that it is
inherited verbatim, so a reviewer can confirm without re-deriving it.

## check-patch-compliance

Per commit, this one asserts:

1. the subject starts with `FROMLIST`, `FROMGIT`, `UPSTREAM` or `BACKPORT`;
2. a `Link:` trailer exists;
3. `b4 am` can fetch that link, and its diff matches the commit's diff;
4. the mbox `From:` matches the commit author.

Consequences for a backport series:

- **`QCLINUX:` is rejected**, even though the LTS branches carry many such
  commits (downstream-only config and DT changes). A locally authored patch
  also has no `Link:` to give. Either post it upstream and use `FROMLIST:`,
  carry it in the BSP layer instead, or justify the failure.
- **Check 3 compares content, not context.** A `BACKPORT:` whose conflict was
  context-only — the surrounding lines moved, but the added and removed lines
  are the ones upstream posted — passes. What fails is a real content
  divergence: a partial hunk out of a tree-wide commit, a dropped hunk that was
  already present, a diff git's rename detection moved to another file, or a
  kept local divergence.

  So the failure count tracks how much you actually changed, not how many
  commits carry the prefix. Two measured series on the same branch:

  | Series | `BACKPORT:` commits | Failed check 3 |
  |---|---|---|
  | ventuno-q (mostly context-only conflicts) | 10 | 1 |
  | uno-q (partial hunks, path changes) | 7 | 7 |

  Expect one failure per *genuinely* divergent commit and explain each in the
  PR. Worth proposing upstream that `BACKPORT:` relax the comparison for the
  cases that remain.
- **Check 4 is a useful signal**: an author mismatch means the cherry-pick lost
  authorship. Fix that; never justify it.

Note that check 3 passing is strong evidence a `Link:` is correct — `b4`
fetched it and the diffs matched. Use it to confirm a link you could not verify
by hand.

## The rest

`dt-binding-check`, `sparse-check` and `check-uapi-headers` should pass. If
`dt-binding-check` fails, a binding you touched has an invalid schema or a
broken example — reproduce locally with:

```bash
make ARCH=arm64 DT_SCHEMA_FILES=<file>.yaml dt_binding_check
```

## Writing the justification

Give reviewers, per failing checker: what the failure is, whether it is real,
the evidence, and what would fix it. Concretely — quote the actual
`log_summary`, include local reproduction numbers (`base N / head M / new
none`), map each checkpatch warning to its commit with a one-line reason, and
list adapted backports with the deviation each one documents in its
`[you: ...]` note. Separate "this is a checker limitation, here is the one-line
fix" from "this is inherent to backporting" from "this is my choice, happy to
change it".
