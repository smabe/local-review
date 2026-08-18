#!/usr/bin/env bash
# run_eval.sh PROVIDER MODEL RUNS LABEL — drive review.sh over the seeded cases.
# Appends TSV rows: label case run exit expected secs nfind found found_any
#   exit     review.sh's exit (124 = watchdog timeout)
#   nfind    the audit's own validated defect count, parsed from its footer
#   found    planted line quoted in a QUOTE: line AND the run exited 4
#   found_any  planted line quoted in a QUOTE: line regardless of exit
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
REVIEW="${LOCAL_REVIEW_SH:-$EVAL_DIR/../scripts/review.sh}"
REPO="$EVAL_DIR/eval-repo"
RESULTS="$EVAL_DIR/results.tsv"
TIMEOUT="${LOCAL_REVIEW_EVAL_TIMEOUT:-900}"
PROVIDER="$1"; MODEL="$2"; RUNS="${3:-1}"; LABEL="${4:?label required}"
# Overridable so an arm can run its own case list and flags without editing
# this file (e.g. LOCAL_REVIEW_EVAL_CASES="removedguard"
# LOCAL_REVIEW_EVAL_ARGS="--rounds 5"). ARGS is word-split on purpose, which
# means SINGLE-WORD flags only -- a multi-word --intent sentence cannot
# survive the split; run review.sh by hand for that.
CASES="${LOCAL_REVIEW_EVAL_CASES:-offbyone swallow boolean leak clean}"
EXTRA_ARGS="${LOCAL_REVIEW_EVAL_ARGS:-}"
# Fail closed on a bad case name. Without this, a typo'd case leaves the
# eval repo unpatched and the run reviews a clean tree: exit 0, recorded as
# a miss that no log distinguishes from a real one.
for c in $CASES; do
  [ -f "$EVAL_DIR/cases/$c/meta" ] \
    || { echo "run_eval.sh: unknown case '$c' (no cases/$c/meta)" >&2; exit 2; }
done

mkdir -p "$EVAL_DIR/logs"
if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$REPO"
  cp "$EVAL_DIR"/base/*.py "$REPO/"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "base: store + parser"
fi

[ -f "$RESULTS" ] || printf 'label\tcase\trun\texit\texpected\tsecs\tnfind\tfound\tfound_any\n' > "$RESULTS"

for run in $(seq 1 "$RUNS"); do
  for c in $CASES; do
    expected_exit=""; marker=""
    while IFS='=' read -r k v; do
      case "$k" in
        expected_exit) expected_exit="$v" ;;
        marker)        marker="$v" ;;
      esac
    done < "$EVAL_DIR/cases/$c/meta"

    git -C "$REPO" checkout -q -- .
    git -C "$REPO" apply "$EVAL_DIR/cases/$c/case.patch"

    log="$EVAL_DIR/logs/$LABEL-$c-r$run.txt"
    t0=$(date +%s)
    ( cd "$REPO" && bash "$REVIEW" --provider "$PROVIDER" --model "$MODEL" $EXTRA_ARGS ) \
      > "$log" 2> "$log.err" &
    wpid=$!
    # Watchdog: TERM only this run's pi (review.sh defers its TERM trap while
    # pi runs), give review.sh's cleanup a generous grace, then TERM the run.
    # Never a machine-wide pkill, never a KILL that could orphan the lock.
    ( sleep "$TIMEOUT"
      # Marker first: rc=124 keys on the watchdog firing, not wall clock --
      # date +%s advances across suspend while sleep does not, so elapsed
      # seconds alone would rewrite a genuine verdict into a timeout (and
      # found=1 into found=0) after any lid-close.
      : > "$log.timeout"
      # TERM the deepest descendant first: pi is a node script (process name
      # "node", never "pi"), and review.sh defers its own TERM trap while its
      # foreground child runs -- so the generation process itself must die
      # before signalling the wrapper.
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
    found=0; found_any=0
    if [ -n "$marker" ] && grep '^QUOTE:' "$log" 2>/dev/null | grep -qF -- "$marker"; then
      found_any=1
      if [ "$rc" -eq 4 ]; then found=1; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$LABEL" "$c" "$run" "$rc" "$expected_exit" "$secs" "$nfind" "$found" "$found_any" \
      | tee -a "$RESULTS"
  done
done
git -C "$REPO" checkout -q -- .
