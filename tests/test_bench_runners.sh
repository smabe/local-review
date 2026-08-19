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
        run_verify.sh)  _fixtures="verify" ;;
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
