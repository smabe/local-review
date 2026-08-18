#!/usr/bin/env bash
# run_bigdiff.sh PROVIDER MODEL RUNS LABEL — replay the 18KB bigdiff fixture.
#
# The small-case bench (run_eval.sh) measures detection on one-bug diffs. This
# one measures the failure that actually settled the default: a review that
# comes back clean on a diff large enough to matter. Same watchdog discipline,
# same TSV shape, different scoring — bigdiff carries five known bugs, so a run
# is scored by WHICH of them were quoted, plus a count of findings matching
# none of them (fabrication candidates, to be read by hand in logs/).
#
# Appends TSV rows to results-bigdiff.tsv:
#   label run exit secs nfind hits other bugs
#     nfind  the audit's own validated finding count
#     hits   how many of the five known bugs were quoted
#     other  finding blocks matching no known bug (read the log before judging)
#     bugs   comma-separated ids of the ones hit
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
REVIEW="${LOCAL_REVIEW_SH:-$EVAL_DIR/../scripts/review.sh}"
REPO="$EVAL_DIR/bigdiff-repo"
FIXTURE="$EVAL_DIR/bigdiff"
RESULTS="$EVAL_DIR/results-bigdiff.tsv"
# Prior bigdiff runs took 556 s and 881 s at 49152; the small-case default of
# 900 s would score the slow tail as a timeout.
TIMEOUT="${LOCAL_REVIEW_BIGDIFF_TIMEOUT:-2400}"
PROVIDER="$1"; MODEL="$2"; RUNS="${3:-1}"; LABEL="${4:?label required}"

mkdir -p "$EVAL_DIR/logs"

# Bootstrap once, like run_eval.sh: the base commit is the fixture's anchor, and
# rebuilding it per run would mean a fresh commit per run. Hygiene against a
# repo left dirty by an interrupted run comes from the reset before each run
# below, which restores the base commit exactly.
if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$REPO"
  cp "$FIXTURE"/base/*.py "$REPO/"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "base: store, parser, cache, serialize, cli"
fi

[ -f "$RESULTS" ] || printf 'label\trun\texit\tsecs\tnfind\thits\tother\tbugs\n' > "$RESULTS"

for run in $(seq 1 "$RUNS"); do
  # reset --hard, not checkout: the previous run's `git add -N` leaves the two
  # new files as index entries, which `clean` will not remove and `git apply`
  # then refuses to overwrite.
  git -C "$REPO" reset -q --hard
  git -C "$REPO" clean -qfd
  # Fail closed like run_eval.sh's case check: an unapplied patch means the
  # review sees a clean tree and exits 0, recorded as a zero-hit run that no
  # log distinguishes from a real one. This fires when bigdiff/base/ drifts
  # out of step with a bigdiff-repo/ bootstrapped from an older base.
  git -C "$REPO" apply "$FIXTURE/case.patch" \
    || { echo "run_bigdiff.sh: case.patch failed to apply -- bigdiff-repo/ is stale? (rm -rf it to re-bootstrap)" >&2; exit 2; }
  # The two new files are untracked; intent-to-add is what puts them in
  # `git diff HEAD`, which is the diff review.sh reads.
  git -C "$REPO" add -N validators.py journal.py \
    || { echo "run_bigdiff.sh: add -N failed -- the new fixture files are missing from the patch?" >&2; exit 2; }

  log="$EVAL_DIR/logs/$LABEL-bigdiff-r$run.txt"
  # The TSV is append-only but this path is not: a re-run under the same label
  # would truncate the previous run's verdict -- the durable evidence rescore
  # reads. Move it aside instead of clobbering it.
  if [ -s "$log" ]; then mv "$log" "$log.prev.$$"; fi
  if [ -s "$log.err" ]; then mv "$log.err" "$log.err.prev.$$"; fi
  t0=$(date +%s)
  # Word-split on purpose, like run_eval.sh: SINGLE-WORD flags only.
  ( cd "$REPO" && bash "$REVIEW" --provider "$PROVIDER" --model "$MODEL" ${LOCAL_REVIEW_EVAL_ARGS:-} ) \
    > "$log" 2> "$log.err" &
  wpid=$!
  # Watchdog, identical in shape to run_eval.sh: TERM the deepest descendant
  # (pi is a node process, and review.sh defers its own TERM trap while its
  # foreground child runs), give cleanup a grace period, then TERM the wrapper.
  ( sleep "$TIMEOUT"
    # Marker first: rc=124 below keys on the watchdog having actually fired,
    # not on wall clock -- date +%s advances across a lid-close while sleep
    # does not, so elapsed-seconds alone rewrites a genuine verdict into a
    # timeout after any suspend.
    : > "$log.timeout"
    victim="$wpid"
    while :; do
      child=$(pgrep -P "$victim" 2>/dev/null | head -1)
      if [ -z "$child" ]; then break; fi
      victim="$child"
    done
    if [ "$victim" != "$wpid" ]; then kill -TERM "$victim" 2>/dev/null; fi
    sleep 30
    kill -TERM "$wpid" 2>/dev/null
  ) & killer=$!
  wait "$wpid"; rc=$?
  kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  secs=$(( $(date +%s) - t0 ))
  if [ -f "$log.timeout" ]; then rc=124; rm -f "$log.timeout"; fi

  nfind=$(sed -n 's/.*audit: .*ok, \([0-9][0-9]*\) defect(s).*/\1/p' "$log.err" | tail -1)
  [ -n "$nfind" ] || nfind=0

  # A scorer crash must not append a blank-columned row that downstream awk
  # reads as a total miss; mark it so the row is visibly unscored instead.
  score=$(python3 "$EVAL_DIR/score_bigdiff.py" "$log") || score=""
  if [ -n "$score" ]; then
    read -r hits other bugs <<EOF
$score
EOF
  else
    hits=0; other=0; bugs="SCORE-ERROR"
    echo "run_bigdiff.sh: score_bigdiff.py failed for $log -- row marked SCORE-ERROR" >&2
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "$run" "$rc" "$secs" "$nfind" "$hits" "$other" "$bugs" \
    | tee -a "$RESULTS"
done

git -C "$REPO" reset -q --hard
git -C "$REPO" clean -qfd
