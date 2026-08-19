#!/bin/bash
# Tests for the bench runners — bench/run_eval.sh, bench/run_bigdiff.sh and
# bench/run_ctx_tiers.sh — which produce the evidence every model decision in
# this repo rests on.
# Run: bash tests/test_bench_runners.sh   (exit 0 = all pass)
#
# A SIBLING of tests/test_local_review_audit.sh, same shape (pass/fail/skipped
# counters, ok/bad/skip helpers, one footer line), for the same reason: a reader
# moves between them without relearning anything. Unlike that suite this file is
# PUBLIC-REPO ONLY — bench/ has no counterpart in the private skills mirror — so
# it carries none of the byte-identity obligations.
#
# No model is ever loaded here, and nothing writes into the real bench/. Every
# output path in all three runners derives from EVAL_DIR (bench/run_eval.sh:10),
# so a runner COPIED into a temp directory writes its results file, its logs and
# its fixture repo there. That is what lets a whole batch run end to end against
# a shell stub standing in for review.sh.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Explicit template rather than a bare `mktemp -d`: GNU coreutils rejects a
# template with fewer than three X's, and the bare form ignores TMPDIR on macOS.
# Same idiom, for the same portability reason, as scripts/review.sh:400.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bench-runners.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
# Counted, not just printed: a check that never ran must not be indistinguishable
# from a green one in the footer the commit workflow reads.
skip() { skipped=$((skipped+1)); echo "SKIP: $1"; }

# Harmless in a checkout without bench/ (the private mirror carries the skill
# but not the instrument), rather than a wall of failures.
if [ ! -d "$ROOT/bench" ]; then
    skip "no bench/ in $ROOT; runner tests not applicable to this checkout"
    echo "-----"
    echo "pass=$pass fail=$fail skipped=$skipped"
    exit 0
fi

# The relocated runners bootstrap their fixture repo with `git commit`
# (bench/run_eval.sh:91-96). Carry an identity in the environment rather than
# depending on the machine's global git config being set.
export GIT_AUTHOR_NAME="bench tests"    GIT_AUTHOR_EMAIL="bench@example.invalid"
export GIT_COMMITTER_NAME="bench tests" GIT_COMMITTER_EMAIL="bench@example.invalid"
# The small-case default is 900 s of watchdog sleep per run; nothing here needs it.
export LOCAL_REVIEW_EVAL_TIMEOUT=60

# Recorded before anything runs and compared at the end. A DELTA is the harness
# writing into the real bench/; the absolute state is not usable as the check,
# because every phase of this workstream edits these runners in flight.
BENCH_BEFORE="$(git -C "$ROOT" status --porcelain bench/ 2>/dev/null)"
# git status alone is not enough: bench/logs/, bench/eval-repo/ and
# bench/bigdiff-repo/ are gitignored (.gitignore:2-4), and logs/ is precisely
# where the snapshot code writes. A timestamp reference catches those — it asks
# the only question that matters, "was anything under the real bench/ written
# while this suite ran", without depending on git's ignore semantics at all.
touch "$TMP/started"

# --- harness -----------------------------------------------------------------

# relocate <runner> <workspace> — copy one runner into <workspace>/bench/ and
# symlink the fixtures it reads. Later phases reuse this for their own runners,
# which is why the fixture list is keyed by runner name rather than inlined.
relocate() {
    _runner="$1"; _ws="$2"
    mkdir -p "$_ws/bench" "$_ws/scripts"
    cp "$ROOT/bench/$_runner" "$_ws/bench/$_runner"
    case "$_runner" in
        run_eval.sh)    _fixtures="cases base" ;;
        run_bigdiff.sh) _fixtures="bigdiff score_bigdiff.py" ;;
        # run_verify.sh reads verify/items for its probe list, but it also
        # bootstraps the same eval-repo the small-case runner uses and applies
        # cases/<fixture>/case.patch per item (bench/run_verify.sh:28,43).
        run_verify.sh)  _fixtures="verify cases base" ;;
        *)              _fixtures="" ;;
    esac
    for _f in $_fixtures; do
        ln -s "$ROOT/bench/$_f" "$_ws/bench/$_f"
    done
}

# snapshots <logs-dir> — leaves the count in SNAP_N and the last match in
# SNAP_PATH. An unmatched glob stays literal in bash, which the -f test filters.
snapshots() {
    SNAP_N=0; SNAP_PATH=""
    for _s in "$1"/*.review.sh.*; do
        if [ -f "$_s" ]; then SNAP_N=$((SNAP_N+1)); SNAP_PATH="$_s"; fi
    done
}

# The stub review script. It records which version of itself ran and, exactly
# once, replaces its own SOURCE file with a v2 body — which is what editing
# scripts/review.sh mid-batch does. The replacement is a `mv`, not an in-place
# rewrite: mv swaps the inode, so a bash already reading the old file is
# untouched and the outcome is fully deterministic. Which version runs is then
# decided by one thing only — WHICH FILE the runner chose to execute.
cat > "$TMP/stub-v1.sh" <<'STUB'
#!/usr/bin/env bash
echo V1 >> "$STUB_MARKER"
if [ ! -e "$STUB_SRC.mutated" ]; then
  : > "$STUB_SRC.mutated"
  {
    echo '#!/usr/bin/env bash'
    echo 'echo V2 >> "$STUB_MARKER"'
    echo 'exit 0'
  } > "$STUB_SRC.next"
  mv "$STUB_SRC.next" "$STUB_SRC"
fi
exit 0
STUB

# PATH shims. The fallback branch is unreachable on a stock macOS (both
# /usr/bin/shasum and /sbin/sha256sum exist), so the only honest way to exercise
# it is to make the tools genuinely unusable for the batch. These stand in front
# of the real ones on PATH and behave like an absent command.
mkdir -p "$TMP/no-shasum" "$TMP/no-checksum"
for _stub in "$TMP/no-shasum/shasum" \
             "$TMP/no-checksum/shasum" "$TMP/no-checksum/sha256sum"; do
    printf '#!/bin/sh\nexit 127\n' > "$_stub"
    chmod +x "$_stub"
done

# --- one batch measures one script version -----------------------------------

WS="$TMP/mutate"
relocate run_eval.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/scripts/review.sh"
cp "$TMP/stub-v1.sh" "$WS/stub-at-batch-start.sh"
(
    export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/scripts/review.sh"
    export LOCAL_REVIEW_EVAL_CASES="offbyone"
    bash "$WS/bench/run_eval.sh" stub-provider stub-model 3 mutate-label
) > "$WS/driver.log" 2>&1
rc=$?

if [ "$rc" -eq 0 ]; then ok; else bad "relocated run_eval.sh batch exited $rc (see $WS/driver.log)"; fi

v1=$(grep -c '^V1$' "$WS/marker.txt" 2>/dev/null || true)
v2=$(grep -c '^V2$' "$WS/marker.txt" 2>/dev/null || true)
# A per-run copy — or no copy at all — yields V1 V2 V2 here, which is what the
# code produced before the snapshot landed.
if [ "$v1" = "3" ]; then ok; else bad "expected 3 runs of stub v1, got $v1"; fi
if [ "$v2" = "0" ]; then ok; else bad "the mid-batch edit reached the batch: $v2 runs measured stub v2"; fi

# --- the snapshot is one per batch, and it survives it -----------------------

snapshots "$WS/bench/logs"
if [ "$SNAP_N" = "1" ]; then ok; else bad "expected exactly 1 snapshot under $WS/bench/logs, found $SNAP_N"; fi
if [ -n "$SNAP_PATH" ] && cmp -s "$SNAP_PATH" "$WS/stub-at-batch-start.sh"; then
    ok
else
    bad "snapshot is not byte-identical to the reviewed script as it was at batch start"
fi

# The path named in a run's .err is the snapshot, so the snapshot has to still
# be there when someone reads that .err. Nothing may delete it on the way out.
if [ -n "$SNAP_PATH" ] && [ -f "$SNAP_PATH" ]; then ok; else bad "snapshot did not survive the batch"; fi

# --- the checksum reaches the driver log -------------------------------------

if grep -q 'sha256 [0-9a-f][0-9a-f]*' "$WS/driver.log"; then
    ok
else
    bad "batch start did not report a sha256 of the reviewed script"
fi

# --- a caller-pinned script is used as-is, never re-snapshotted --------------

WS="$TMP/pinned"
relocate run_eval.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/pinned-review.sh"
(
    export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/pinned-review.sh"
    export LOCAL_REVIEW_EVAL_CASES="offbyone"
    export LOCAL_REVIEW_SH="$WS/pinned-review.sh"
    bash "$WS/bench/run_eval.sh" stub-provider stub-model 1 pinned-label
) > "$WS/driver.log" 2>&1
rc=$?

if [ "$rc" -eq 0 ]; then ok; else bad "pinned-script batch exited $rc (see $WS/driver.log)"; fi
if [ -s "$WS/marker.txt" ]; then ok; else bad "the pinned script was never executed"; fi
snapshots "$WS/bench/logs"
if [ "$SNAP_N" = "0" ]; then ok; else bad "LOCAL_REVIEW_SH was re-snapshotted ($SNAP_N copies made)"; fi
if grep -q 'sha256 [0-9a-f][0-9a-f]*' "$WS/driver.log"; then
    ok
else
    bad "a pinned script was not checksummed at batch start"
fi

# --- checksum fallback -------------------------------------------------------

# Only sha256sum reachable: the batch must still run and still report a hash.
WS="$TMP/sha256only"
relocate run_eval.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/scripts/review.sh"
(
    export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/scripts/review.sh"
    export LOCAL_REVIEW_EVAL_CASES="offbyone"
    export PATH="$TMP/no-shasum:$PATH"
    bash "$WS/bench/run_eval.sh" stub-provider stub-model 1 fallback-label
) > "$WS/driver.log" 2>&1
rc=$?

if [ "$rc" -eq 0 ]; then ok; else bad "batch with only sha256sum exited $rc (see $WS/driver.log)"; fi
if grep -q 'sha256 [0-9a-f][0-9a-f]*' "$WS/driver.log"; then
    ok
else
    bad "the sha256sum fallback produced no checksum"
fi

# Neither reachable: fail loudly rather than record a silently empty version.
WS="$TMP/nochecksum"
relocate run_eval.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/scripts/review.sh"
(
    export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/scripts/review.sh"
    export LOCAL_REVIEW_EVAL_CASES="offbyone"
    export PATH="$TMP/no-checksum:$PATH"
    bash "$WS/bench/run_eval.sh" stub-provider stub-model 1 nosum-label
) > "$WS/driver.log" 2>&1
rc=$?

if [ "$rc" -ne 0 ]; then ok; else bad "batch with no checksum tool exited 0 instead of refusing"; fi
if grep -qi 'shasum' "$WS/driver.log"; then ok; else bad "the refusal did not name the missing tool"; fi
if [ ! -s "$WS/marker.txt" ]; then ok; else bad "a refused batch still dispatched a run"; fi
# A snapshot on disk asserts that a measurement was attempted, so a batch
# refused for any reason must leave no copy behind.
snapshots "$WS/bench/logs"
if [ "$SNAP_N" = "0" ]; then ok; else bad "a refused batch left $SNAP_N snapshot(s) behind"; fi

# --- a fixture refusal also leaves no snapshot -------------------------------

WS="$TMP/badcase"
relocate run_eval.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/scripts/review.sh"
(
    export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/scripts/review.sh"
    export LOCAL_REVIEW_EVAL_CASES="nosuchcase"
    bash "$WS/bench/run_eval.sh" stub-provider stub-model 1 badcase-label
) > "$WS/driver.log" 2>&1
rc=$?

# The pre-existing fail-closed path at run_eval.sh:28-30 must survive the change.
if [ "$rc" -eq 2 ]; then ok; else bad "unknown-case batch exited $rc, expected the fail-closed 2"; fi
snapshots "$WS/bench/logs"
if [ "$SNAP_N" = "0" ]; then ok; else bad "a batch refused for a bad case name left a snapshot behind"; fi

# --- snapshot names are never reused -----------------------------------------

# Keying the name on the label alone would silently re-measure the previous
# batch's script while the row is stamped with today's checksum.
WS="$TMP/repeat"
relocate run_eval.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/scripts/review.sh"
for _batch in 1 2; do
    (
        export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/scripts/review-unused.sh"
        export LOCAL_REVIEW_EVAL_CASES="offbyone"
        bash "$WS/bench/run_eval.sh" stub-provider stub-model 1 same-label
    ) >> "$WS/driver.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then ok; else bad "batch $_batch under one label exited $rc (see $WS/driver.log)"; fi
done

snapshots "$WS/bench/logs"
if [ "$SNAP_N" = "2" ]; then ok; else bad "two batches under one label produced $SNAP_N snapshots, expected 2"; fi

# --- run_bigdiff.sh takes the same snapshot ----------------------------------

WS="$TMP/bigdiff"
relocate run_bigdiff.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/scripts/review.sh"
cp "$TMP/stub-v1.sh" "$WS/stub-at-batch-start.sh"
(
    export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/scripts/review.sh"
    bash "$WS/bench/run_bigdiff.sh" stub-provider stub-model 2 bigdiff-label
) > "$WS/driver.log" 2>&1
rc=$?

if [ "$rc" -eq 0 ]; then ok; else bad "relocated run_bigdiff.sh batch exited $rc (see $WS/driver.log)"; fi
v1=$(grep -c '^V1$' "$WS/marker.txt" 2>/dev/null || true)
v2=$(grep -c '^V2$' "$WS/marker.txt" 2>/dev/null || true)
if [ "$v1" = "2" ]; then ok; else bad "expected 2 bigdiff runs of stub v1, got $v1"; fi
if [ "$v2" = "0" ]; then ok; else bad "a mid-batch edit reached the bigdiff batch: $v2 runs measured stub v2"; fi
snapshots "$WS/bench/logs"
if [ "$SNAP_N" = "1" ]; then ok; else bad "expected exactly 1 bigdiff snapshot, found $SNAP_N"; fi
if [ -n "$SNAP_PATH" ] && cmp -s "$SNAP_PATH" "$WS/stub-at-batch-start.sh"; then
    ok
else
    bad "bigdiff snapshot is not byte-identical to the reviewed script at batch start"
fi
if grep -q 'sha256 [0-9a-f][0-9a-f]*' "$WS/driver.log"; then
    ok
else
    bad "run_bigdiff.sh did not report a sha256 of the reviewed script"
fi

# --- run_ctx_tiers.sh pins ONE snapshot across both suites -------------------

# The arm cannot be run here (it serves a real model), so assert the shape that
# makes one snapshot reach both dispatches: it is taken once, exported, and
# never deleted on the way out. Two separately-taken snapshots inside one arm
# would reproduce the cross-session misattribution inside a single label.
CTX="$ROOT/bench/run_ctx_tiers.sh"
if grep -q 'export LOCAL_REVIEW_SH' "$CTX"; then
    ok
else
    bad "run_ctx_tiers.sh does not export a pinned snapshot for its two suites"
fi
if [ "$(grep -c 'cp "\$REPO_ROOT/scripts/review.sh"' "$CTX")" = "1" ]; then
    ok
else
    bad "run_ctx_tiers.sh must copy review.sh exactly once, shared by both suites"
fi
# LOCAL_REVIEW_ARM_SUITES finishes a half-done arm in a SECOND invocation. A
# fresh snapshot there would let one label's eval rows and bigdiff rows measure
# two different scripts — this change's own failure mode, in the one workflow
# built for resuming.
if grep -q 'if \[ -f "\$SNAPSHOT" \]' "$CTX"; then
    ok
else
    bad "a resumed arm re-snapshots instead of reusing the copy it started with"
fi
# Every gate — models.json, server liveness, reachability, served context — must
# precede the copy, or an arm that refuses to run leaves an orphan asserting a
# measurement that never happened.
gate_ln=$(grep -n 'refusing to run arm' "$CTX" | head -1 | cut -d: -f1)
copy_ln=$(grep -n 'cp "\$REPO_ROOT/scripts/review.sh"' "$CTX" | head -1 | cut -d: -f1)
if [ -n "$gate_ln" ] && [ -n "$copy_ln" ] && [ "$gate_ln" -lt "$copy_ln" ]; then
    ok
else
    bad "run_ctx_tiers.sh snapshots (line ${copy_ln:-none}) before its served-context gate (line ${gate_ln:-none})"
fi
# The unset at :25-26 is how an arm guarantees it measured the default
# configuration; the export has to come after it, not replace it.
unset_ln=$(grep -n 'unset LOCAL_REVIEW_EVAL_CASES' "$CTX" | head -1 | cut -d: -f1)
export_ln=$(grep -n 'export LOCAL_REVIEW_SH' "$CTX" | head -1 | cut -d: -f1)
if [ -n "$unset_ln" ] && [ -n "$export_ln" ] && [ "$unset_ln" -lt "$export_ln" ]; then
    ok
else
    bad "run_ctx_tiers.sh must unset LOCAL_REVIEW_SH (line ${unset_ln:-none}) before exporting its snapshot (line ${export_ln:-none})"
fi
# Deleting the snapshot from the EXIT trap would orphan every .err naming it.
# Scoped to cleanup()'s body: the copy-failure path legitimately removes the
# half-written copy it just made, and that is not this hazard.
# The empty-extraction guard is not optional: a renamed cleanup() would make the
# grep below match nothing and the check pass vacuously, which is the one
# failure a test like this must not have (same reason as the audit suite's
# `[ -s "$TMP/audit.py" ]`).
ctx_cleanup=$(awk '/^cleanup\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$CTX")
if [ -z "$ctx_cleanup" ]; then
    bad "could not extract cleanup() from run_ctx_tiers.sh; the snapshot-retention check would pass vacuously"
elif printf '%s\n' "$ctx_cleanup" | grep -q 'SNAPSHOT'; then
    bad "run_ctx_tiers.sh's cleanup() touches the snapshot; the transcripts naming it outlive the arm"
else
    ok
fi

# --- the five-column shared tail ---------------------------------------------

# Every row a runner writes from this commit forward carries provenance:
# `status date sha` in all three files, plus `vsurv vtotal` in the two that
# drive review.sh. The header and the row have to widen in the SAME commit —
# the reverse direction (narrow header, wide rows) drops the new fields on read
# with no error at all, which is worse than a raise.

# field <file> <line-no> <col-no> — one tab-separated cell, empty cells intact.
field() {
    awk -F'\t' -v ln="$2" -v c="$3" 'NR==ln{print $c; exit}' "$1"
}
# nfields <file> <line-no>
nfields() {
    awk -F'\t' -v ln="$2" 'NR==ln{print NF; exit}' "$1"
}
# tail_names <file> <n> — the last n header names, space-separated.
tail_names() {
    awk -F'\t' -v n="$2" 'NR==1{
        s=""; for (i=NF-n+1; i<=NF; i++) s = s (i>NF-n+1 ? " " : "") $i
        print s; exit
    }' "$1"
}

# A date shim so the per-row stamp can be observed without sleeping through a
# midnight. It varies +%F on every call and passes everything else — notably
# +%s, which both runners use for their own elapsed-seconds arithmetic — to the
# real binary, resolved now rather than through the shimmed PATH.
REAL_DATE="$(command -v date)"
mkdir -p "$TMP/datedir"
cat > "$TMP/datedir/date" <<DATESTUB
#!/bin/sh
if [ "\$1" = "+%F" ]; then
  n=\$(cat "\$DATE_COUNTER" 2>/dev/null || echo 0)
  echo \$((n + 1)) > "\$DATE_COUNTER"
  printf '2026-01-%02d\n' \$((n + 1))
  exit 0
fi
exec "$REAL_DATE" "\$@"
DATESTUB
chmod +x "$TMP/datedir/date"

WS="$TMP/schema-eval"
relocate run_eval.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/scripts/review.sh"
(
    export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/scripts/review-unused.sh"
    export LOCAL_REVIEW_EVAL_CASES="offbyone"
    export DATE_COUNTER="$WS/date.count"
    export PATH="$TMP/datedir:$PATH"
    bash "$WS/bench/run_eval.sh" stub-provider stub-model 2 schema-label
) > "$WS/driver.log" 2>&1
rc=$?
EVAL_TSV="$WS/bench/results.tsv"

if [ "$rc" -eq 0 ]; then ok; else bad "schema run_eval.sh batch exited $rc (see $WS/driver.log)"; fi
if [ "$(tail_names "$EVAL_TSV" 5)" = "status date sha vsurv vtotal" ]; then
    ok
else
    bad "results.tsv header does not end with the shared tail: got '$(tail_names "$EVAL_TSV" 5)'"
fi
if [ "$(nfields "$EVAL_TSV" 1)" = "14" ]; then ok; else bad "results.tsv header has $(nfields "$EVAL_TSV" 1) columns, expected 14"; fi
if [ "$(nfields "$EVAL_TSV" 2)" = "$(nfields "$EVAL_TSV" 1)" ]; then
    ok
else
    bad "run_eval.sh row has $(nfields "$EVAL_TSV" 2) fields against a $(nfields "$EVAL_TSV" 1)-column header"
fi

# Empty, not zero. A run that never verified must be distinguishable from one
# whose findings were all refuted -- that distinction is the whole point of the
# two columns, and defaulting them to 0 destroys it.
if [ -z "$(field "$EVAL_TSV" 2 13)" ] && [ -z "$(field "$EVAL_TSV" 2 14)" ]; then
    ok
else
    bad "a non-verify run recorded vsurv='$(field "$EVAL_TSV" 2 13)' vtotal='$(field "$EVAL_TSV" 2 14)', expected both empty"
fi

# The sha is the batch's, so both rows carry it and it is a real hash.
case "$(field "$EVAL_TSV" 2 12)" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok ;;
    *) bad "row sha is not a 12-char hash: '$(field "$EVAL_TSV" 2 12)'" ;;
esac
if [ "$(field "$EVAL_TSV" 2 12)" = "$(field "$EVAL_TSV" 3 12)" ]; then
    ok
else
    bad "two rows of one batch carry different sha values"
fi

# The date is read PER ROW, not hoisted out of the loop. A batch that starts at
# 23:50 and runs four hours would otherwise stamp every row with the day it
# began -- the misattribution this column exists to fix.
if [ "$(field "$EVAL_TSV" 2 11)" != "$(field "$EVAL_TSV" 3 11)" ]; then
    ok
else
    bad "both rows carry date '$(field "$EVAL_TSV" 2 11)'; the stamp was hoisted out of the run loop"
fi

WS="$TMP/schema-bigdiff"
relocate run_bigdiff.sh "$WS"
cp "$TMP/stub-v1.sh" "$WS/scripts/review.sh"
(
    export STUB_MARKER="$WS/marker.txt" STUB_SRC="$WS/scripts/review-unused.sh"
    bash "$WS/bench/run_bigdiff.sh" stub-provider stub-model 1 schema-big
) > "$WS/driver.log" 2>&1
rc=$?
BIG_TSV="$WS/bench/results-bigdiff.tsv"

if [ "$rc" -eq 0 ]; then ok; else bad "schema run_bigdiff.sh batch exited $rc (see $WS/driver.log)"; fi
if [ "$(tail_names "$BIG_TSV" 5)" = "status date sha vsurv vtotal" ]; then
    ok
else
    bad "results-bigdiff.tsv header does not end with the shared tail: got '$(tail_names "$BIG_TSV" 5)'"
fi
if [ "$(nfields "$BIG_TSV" 1)" = "13" ]; then ok; else bad "results-bigdiff.tsv header has $(nfields "$BIG_TSV" 1) columns, expected 13"; fi
if [ "$(nfields "$BIG_TSV" 2)" = "$(nfields "$BIG_TSV" 1)" ]; then
    ok
else
    bad "run_bigdiff.sh row has $(nfields "$BIG_TSV" 2) fields against a $(nfields "$BIG_TSV" 1)-column header"
fi

# run_verify.sh never invokes review.sh, so it gets `status date sha` only: its
# `verdict` column already carries the survivor signal vsurv/vtotal add
# elsewhere, and a permanently-empty column trains readers to skim past
# emptiness. Its sha is its own checksum.
mkdir -p "$TMP/vpi"
cat > "$TMP/vpi/pi" <<'VPI'
#!/usr/bin/env bash
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"VERDICT: real\nREASON: stub"}]}}'
VPI
chmod +x "$TMP/vpi/pi"

WS="$TMP/schema-verify"
relocate run_verify.sh "$WS"
(
    export PATH="$TMP/vpi:$PATH"
    bash "$WS/bench/run_verify.sh" stub-provider stub-model 1 schema-vfy
) > "$WS/driver.log" 2>&1
rc=$?
VFY_TSV="$WS/bench/results-verify.tsv"

if [ "$rc" -eq 0 ]; then ok; else bad "schema run_verify.sh batch exited $rc (see $WS/driver.log)"; fi
if [ "$(tail_names "$VFY_TSV" 3)" = "status date sha" ]; then
    ok
else
    bad "results-verify.tsv header does not end with 'status date sha': got '$(tail_names "$VFY_TSV" 3)'"
fi
if [ "$(nfields "$VFY_TSV" 1)" = "11" ]; then ok; else bad "results-verify.tsv header has $(nfields "$VFY_TSV" 1) columns, expected 11"; fi
if [ "$(nfields "$VFY_TSV" 2)" = "$(nfields "$VFY_TSV" 1)" ]; then
    ok
else
    bad "run_verify.sh row has $(nfields "$VFY_TSV" 2) fields against a $(nfields "$VFY_TSV" 1)-column header"
fi
case "$(field "$VFY_TSV" 2 11)" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok ;;
    *) bad "run_verify.sh row sha is not a 12-char hash: '$(field "$VFY_TSV" 2 11)'" ;;
esac

# --- cross-file tail parity --------------------------------------------------

# Read out of the headers the runners actually WROTE, never retyped here: three
# files drifting apart one column at a time is the failure this whole migration
# exists to make impossible, and a hand-copied expectation drifts with them.
# Same reasoning as the verifier-prompt parity check at
# tests/test_local_review_audit.sh:305-318.
if [ "$(tail_names "$EVAL_TSV" 5)" = "$(tail_names "$BIG_TSV" 5)" ]; then
    ok
else
    bad "results.tsv and results-bigdiff.tsv disagree on the shared tail:
  eval:    $(tail_names "$EVAL_TSV" 5)
  bigdiff: $(tail_names "$BIG_TSV" 5)"
fi
# The verify file's three names must be the shared tail's first three, in order.
if [ "$(tail_names "$VFY_TSV" 3)" = "$(tail_names "$EVAL_TSV" 5 | cut -d' ' -f1-3)" ]; then
    ok
else
    bad "results-verify.tsv's tail is not the leading three of the shared tail:
  verify: $(tail_names "$VFY_TSV" 3)
  shared: $(tail_names "$EVAL_TSV" 5)"
fi

# The three committed files carry the same headers the runners write. A runner
# widened without its results file (or the reverse) puts two schemas in one repo.
if [ "$(head -1 "$ROOT/bench/results.tsv")" = "$(head -1 "$EVAL_TSV")" ]; then
    ok
else
    bad "bench/results.tsv's header is not what run_eval.sh writes today"
fi
if [ "$(head -1 "$ROOT/bench/results-bigdiff.tsv")" = "$(head -1 "$BIG_TSV")" ]; then
    ok
else
    bad "bench/results-bigdiff.tsv's header is not what run_bigdiff.sh writes today"
fi
if [ "$(head -1 "$ROOT/bench/results-verify.tsv")" = "$(head -1 "$VFY_TSV")" ]; then
    ok
else
    bad "bench/results-verify.tsv's header is not what run_verify.sh writes today"
fi

# No committed data row may be WIDER than its header -- the direction that
# silently drops fields. Narrower is expected and correct: those rows predate
# the columns, and a blank would assert "no data" where the data still exists
# in bench/logs/*.err.
for _f in results.tsv results-bigdiff.tsv results-verify.tsv; do
    _over=$(awk -F'\t' 'NR==1{h=NF; next} NF>h{print NR}' "$ROOT/bench/$_f")
    if [ -z "$_over" ]; then
        ok
    else
        bad "bench/$_f has data rows wider than its header (lines: $_over)"
    fi
done

# --- verify columns, end to end through the real review.sh -------------------

# The line these columns are scraped from is emitted through review.sh's `note`
# helper, which prefixes `local-review: ` (scripts/review.sh:45,679) -- so a sed
# anchored ^verify: matches nothing on every run, and the symptom is empty
# columns, indistinguishable from a run that never verified. Only driving the
# REAL script catches it; a hand-typed fixture would encode the bug.
VSTUBS="$TMP/schema-vstubs"; mkdir -p "$VSTUBS"
cat > "$VSTUBS/lms" <<'LMSSTUB'
#!/usr/bin/env bash
case "$1" in
  server) printf 'The server is running on port 1234.\n' ;;
  ps)     printf 'IDENTIFIER MODEL\nqwen/qwen3-coder-30b IDLE\n' ;;
  *)      printf 'stub\n' ;;
esac
LMSSTUB
chmod +x "$VSTUBS/lms"

# $1 = the verifier's verdict for every finding. Call 1 is the reviewer and
# emits one complete finding block; every later call is the verifier.
make_vpi() {
    cat > "$VSTUBS/pi" <<VPISTUB
#!/usr/bin/env bash
count_file="$VSTUBS/count"
n=\$( (cat "\$count_file" 2>/dev/null || echo 0) )
echo \$((n + 1)) > "\$count_file"
printf '%s\n' '{"type":"tool_execution_start"}'
printf '%s\n' '{"type":"tool_execution_end","isError":false}'
if [ "\$n" -eq 0 ]; then
  printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"totalTokens":9},"content":[{"type":"text","text":"FILE: store.py:1 | confidence: high\\nQUOTE: import json\\nDEFECT: the import is wrong\\nFAILURE: callers see nothing"}]}}'
else
  printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"totalTokens":9},"content":[{"type":"text","text":"VERDICT: $1\\nREASON: stubbed"}]}}'
fi
VPISTUB
    chmod +x "$VSTUBS/pi"
    rm -f "$VSTUBS/count"
}

# run_a_verify_batch <workspace> <label> — one relocated run_eval.sh batch that
# drives the real review.sh under --verify with the stubs above.
run_a_verify_batch() {
    relocate run_eval.sh "$1"
    (
        export PATH="$VSTUBS:$PATH"
        export HOME="$1/home"
        export LOCAL_REVIEW_SH="$ROOT/scripts/review.sh"
        export LOCAL_REVIEW_EVAL_CASES="offbyone"
        export LOCAL_REVIEW_EVAL_ARGS="--verify"
        bash "$1/bench/run_eval.sh" lmstudio qwen/qwen3-coder-30b 1 "$2"
    ) > "$1/driver.log" 2>&1
}

# All refuted: review.sh exits 0 (docs/verify-flag.md) and reports 0/1. The row
# must show vsurv=0 vtotal=1 -- NOT two empty cells, which is what a clean run
# looks like and what the anchoring bug produces.
WS="$TMP/schema-refuted"
make_vpi refuted
run_a_verify_batch "$WS" refuted-label
VR_TSV="$WS/bench/results.tsv"
if [ -f "$VR_TSV" ] && [ "$(nfields "$VR_TSV" 2)" -ge 14 ] 2>/dev/null; then ok; else bad "all-refuted verify batch wrote no usable row (see $WS/driver.log)"; fi
if [ "$(field "$VR_TSV" 2 4)" = "0" ]; then ok; else bad "all-refuted run should exit 0, row says exit=$(field "$VR_TSV" 2 4)"; fi
if [ "$(field "$VR_TSV" 2 13)" = "0" ] && [ "$(field "$VR_TSV" 2 14)" = "1" ]; then
    ok
else
    bad "all-refuted run recorded vsurv='$(field "$VR_TSV" 2 13)' vtotal='$(field "$VR_TSV" 2 14)', expected 0 and 1"
fi

# And the reverse: a surviving finding keeps exit 4 and records 1/1.
WS="$TMP/schema-real"
make_vpi real
run_a_verify_batch "$WS" real-label
VS_TSV="$WS/bench/results.tsv"
if [ "$(field "$VS_TSV" 2 4)" = "4" ]; then ok; else bad "a surviving finding should keep exit 4, row says exit=$(field "$VS_TSV" 2 4)"; fi
if [ "$(field "$VS_TSV" 2 13)" = "1" ] && [ "$(field "$VS_TSV" 2 14)" = "1" ]; then
    ok
else
    bad "surviving-finding run recorded vsurv='$(field "$VS_TSV" 2 13)' vtotal='$(field "$VS_TSV" 2 14)', expected 1 and 1"
fi

# --- mixed width survives every reader ---------------------------------------

# The file is legitimately mixed-width from the migration commit forward: the
# header carries the new names, the 385 historical rows do not. Every reader
# has to return the old fields correctly from a narrow row and the new names
# EMPTY -- never a shifted value, and never a raise.
FX="$TMP/mixed"; mkdir -p "$FX"
# Copied, not imported from bench/ in place: importing writes a __pycache__ into
# the real bench/, which the write-check below reports as the harness dirtying
# the instrument.
cp "$ROOT/bench/summarize_ctx_tiers.py" "$ROOT/bench/watch_ctx_tiers.py" "$FX/"
{
    printf 'label\tcase\trun\texit\texpected\tsecs\tnfind\tfound\tfound_any\tstatus\tdate\tsha\tvsurv\tvtotal\n'
    printf 'legacy-arm\toffbyone\t1\t4\t4\t100\t2\t1\t1\n'
    printf 'new-arm\toffbyone\t1\t4\t4\t120\t3\t1\t1\t\t2026-08-19\tabc123def456\t1\t3\n'
} > "$FX/results.tsv"

cat > "$FX/read_mixed.py" <<'PY'
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
import summarize_ctx_tiers as summarize
import watch_ctx_tiers as watch

fixture = pathlib.Path(sys.argv[2])
NEW = ("status", "date", "sha", "vsurv", "vtotal")
for mod in (summarize, watch):
    name = mod.__name__
    rows = mod.read_tsv(fixture)
    assert len(rows) == 2, f"{name}: read {len(rows)} rows, expected 2"
    legacy, new = rows
    # The pre-existing fields still resolve, unshifted, from a narrow row.
    for key, want in (("label", "legacy-arm"), ("exit", "4"),
                      ("found", "1"), ("nfind", "2"), ("secs", "100")):
        got = legacy[key]
        assert got == want, f"{name}: legacy {key} is {got!r}, expected {want!r}"
    # And the new names come back empty rather than raising or shifting.
    for key in NEW:
        got = legacy.get(key, "<MISSING>")
        assert got == "", f"{name}: legacy {key} is {got!r}, expected the empty string"
    for key, want in (("vsurv", "1"), ("vtotal", "3"), ("sha", "abc123def456")):
        got = new[key]
        assert got == want, f"{name}: new-row {key} is {got!r}, expected {want!r}"
print("ok")
PY

if python3 "$FX/read_mixed.py" "$FX" "$FX/results.tsv" > "$FX/out.txt" 2>&1; then
    ok
else
    bad "a mixed-width results.tsv broke a reader:
$(cat "$FX/out.txt")"
fi

# --- rescore_bigdiff.py: mixed width, atomic write, index stability ----------

RS="$TMP/rescore"; mkdir -p "$RS/logs"
cp "$ROOT/bench/rescore_bigdiff.py" "$ROOT/bench/score_bigdiff.py" "$RS/"
{
    printf 'label\trun\texit\tsecs\tnfind\thits\tother\tbugs\tstatus\tdate\tsha\tvsurv\tvtotal\n'
    printf 'legacy-arm\t1\t4\t500\t3\t2\t1\tcache_evict,export_exit0\n'
    printf 'new-arm\t1\t4\t520\t3\t2\t1\tcache_evict,export_exit0\t\t2026-08-19\tabc123def456\t\t\n'
} > "$RS/results-bigdiff.tsv"
cp "$RS/results-bigdiff.tsv" "$RS/expected.tsv"

# No transcripts on disk, so both rows are left exactly as they are -- which is
# what makes this a byte-comparison of the round trip, trailing columns and all.
if python3 "$RS/rescore_bigdiff.py" > "$RS/out.txt" 2>&1; then ok; else bad "rescore on a mixed-width file failed:
$(cat "$RS/out.txt")"; fi
if cmp -s "$RS/results-bigdiff.tsv" "$RS/expected.tsv"; then
    ok
else
    bad "rescore rewrote a mixed-width file it should have left alone:
$(diff "$RS/expected.tsv" "$RS/results-bigdiff.tsv" || true)"
fi

# The rewrite goes through a temp file and a rename, so a crash mid-write leaves
# the previous evidence intact rather than a half-written file. Assert both the
# write path and that it leaves no residue behind.
if grep -q 'os.replace' "$RS/rescore_bigdiff.py"; then
    ok
else
    bad "rescore_bigdiff.py does not rename into place; a crash mid-write truncates the evidence"
fi
if grep -q 'RESULTS.write_text' "$RS/rescore_bigdiff.py"; then
    bad "rescore_bigdiff.py still writes the results file directly"
else
    ok
fi
_stray=$(find "$RS" -maxdepth 1 -name 'results-bigdiff.tsv*' ! -name 'results-bigdiff.tsv')
if [ -z "$_stray" ]; then ok; else bad "rescore left a temp file behind: $_stray"; fi

# The rename must not carry the temp file's mode onto the destination. mkstemp
# creates owner-only, so a bare os.replace silently takes committed evidence
# from 0644 to 0600 on every rescore -- and git tracks only the exec bit, so
# nothing in a diff would ever show it.
chmod 644 "$RS/results-bigdiff.tsv"
python3 "$RS/rescore_bigdiff.py" > "$RS/out2.txt" 2>&1
_mode=$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[-3:])' "$RS/results-bigdiff.tsv")
if [ "$_mode" = "644" ]; then ok; else bad "rescore changed the results file mode to $_mode, expected 644"; fi

# A truncated row still yields a label and a run, so it reaches the scorer and
# then the positional write-back. One corrupt line must not abort the pass and
# leave the file half-rescored under two rule sets.
RSCUT="$TMP/rescore-truncated"; mkdir -p "$RSCUT/logs"
cp "$ROOT/bench/rescore_bigdiff.py" "$ROOT/bench/score_bigdiff.py" "$RSCUT/"
{
    printf 'label\trun\texit\tsecs\tnfind\thits\tother\tbugs\tstatus\tdate\tsha\tvsurv\tvtotal\n'
    printf 'good-arm\t1\t4\t500\t3\t2\t1\tcache_evict\n'
    printf 'cut-arm\t1\t4\t520\t3\n'
} > "$RSCUT/results-bigdiff.tsv"
cp "$RSCUT/results-bigdiff.tsv" "$RSCUT/expected.tsv"

if python3 "$RSCUT/rescore_bigdiff.py" > "$RSCUT/out.txt" 2>&1; then
    ok
else
    bad "one truncated row aborted the whole rescore pass:
$(cat "$RSCUT/out.txt")"
fi
if grep -q 'truncated' "$RSCUT/out.txt"; then ok; else bad "the truncated row was skipped silently:
$(cat "$RSCUT/out.txt")"; fi
if cmp -s "$RSCUT/results-bigdiff.tsv" "$RSCUT/expected.tsv"; then
    ok
else
    bad "rescore altered a file whose only change should have been none:
$(diff "$RSCUT/expected.tsv" "$RSCUT/results-bigdiff.tsv" || true)"
fi

# New columns append at the END only. An INSERT shifts every stored score
# silently, because the header-name-to-position map is what the rewrite trusts.
# Catch it at the boundary rather than after a rescore has corrupted the file.
RSBAD="$TMP/rescore-bad"; mkdir -p "$RSBAD/logs"
cp "$ROOT/bench/rescore_bigdiff.py" "$ROOT/bench/score_bigdiff.py" "$RSBAD/"
{
    printf 'label\trun\texit\tsecs\tnfind\tother\thits\tbugs\tstatus\tdate\tsha\tvsurv\tvtotal\n'
    printf 'legacy-arm\t1\t4\t500\t3\t1\t2\tcache_evict\n'
} > "$RSBAD/results-bigdiff.tsv"
cp "$RSBAD/results-bigdiff.tsv" "$RSBAD/expected.tsv"

python3 "$RSBAD/rescore_bigdiff.py" > "$RSBAD/out.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok; else bad "rescore accepted a header with hits/other swapped instead of refusing"; fi
if grep -q 'hits' "$RSBAD/out.txt"; then ok; else bad "the refusal did not name the column that moved:
$(cat "$RSBAD/out.txt")"; fi
if cmp -s "$RSBAD/results-bigdiff.tsv" "$RSBAD/expected.tsv"; then
    ok
else
    bad "rescore rewrote the file despite refusing on a moved column"
fi

# --- the harness never writes into the real bench/ ---------------------------

# If a symlink ever points the wrong way, a test run appends junk rows to
# committed evidence (results.tsv is tracked). Assert it here rather than
# trusting a reviewer to notice.
BENCH_AFTER="$(git -C "$ROOT" status --porcelain bench/ 2>/dev/null)"
if [ "$BENCH_BEFORE" = "$BENCH_AFTER" ]; then
    ok
else
    bad "the relocated runners modified tracked files in the real bench/:
$BENCH_AFTER"
fi

# The gitignored half — logs/, eval-repo/, bigdiff-repo/ — which git status
# cannot report and which is where a stray snapshot would land.
#
# Positive control first: an empty result is the PASSING answer below, so a
# find that silently reports nothing (bad path, unsupported -newer) would turn
# this check green precisely when it stopped working. $TMP is full of files
# written after the reference, so it must come back non-empty.
if [ -n "$(find "$TMP" -newer "$TMP/started" -type f)" ]; then
    ok
else
    bad "find -newer reports nothing under $TMP; the real-bench write check below cannot fail"
fi
touched="$(find "$ROOT/bench" -newer "$TMP/started" -type f)"
if [ -z "$touched" ]; then
    ok
else
    bad "the relocated runners wrote into the real bench/ (including gitignored paths):
$touched"
fi

echo "-----"
echo "pass=$pass fail=$fail skipped=$skipped"
[ "$fail" -eq 0 ]
