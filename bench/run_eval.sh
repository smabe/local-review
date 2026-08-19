#!/usr/bin/env bash
# run_eval.sh PROVIDER MODEL RUNS LABEL — drive review.sh over the seeded cases.
# Appends TSV rows:
#   label case run exit expected secs nfind found found_any status date sha vsurv vtotal
#   exit     review.sh's exit (124 = watchdog timeout)
#   nfind    the audit's own validated defect count, parsed from its footer
#   found    planted line quoted in a QUOTE: line AND the run exited 4
#   found_any  planted line quoted in a QUOTE: line regardless of exit
#   status   empty on a normal run; non-empty means the row is not a clean
#            measurement and no other field in it can be read at face value
#   date     date +%F, stamped PER ROW -- a batch straddling midnight must not
#            report every run under the day it started
#   sha      first 12 hex of the sha256 of the script this batch actually ran
#   vsurv    findings surviving --verify's adversarial pass, and vtotal the
#   vtotal   findings it checked. EMPTY, never 0, when verification did not run:
#            an all-refuted run is exit=0 with vtotal=N, a genuinely clean run
#            is exit=0 with vtotal empty, and zero would collapse the two.
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
# The script under test. What actually EXECUTES is REVIEW_RUN, a frozen copy
# taken once below -- grep for that one to learn what a batch ran.
REVIEW_SRC="${LOCAL_REVIEW_SH:-$EVAL_DIR/../scripts/review.sh}"
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

# Checksum the script this batch will execute. shasum is perl (present on macOS,
# not guaranteed on a minimal Linux); sha256sum is coreutils (the reverse), and
# the repo has no existing checksum idiom to copy -- so try both and take the
# first that yields a hash. Empty output covers "not installed" and "installed
# but broken" alike.
review_sha() {
  # Report an unreadable path as itself. Folding it into the no-tool message
  # below would send the operator after a missing coreutils that is right there.
  if [ ! -r "$1" ]; then
    echo "run_eval.sh: cannot read $1 -- no script to review" >&2
    return 1
  fi
  _sha=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
  if [ -z "$_sha" ]; then _sha=$(sha256sum "$1" 2>/dev/null | awk '{print $1}'); fi
  if [ -z "$_sha" ]; then
    echo "run_eval.sh: no working shasum or sha256sum -- refusing a batch whose script version cannot be recorded" >&2
    return 1
  fi
  printf '%s' "${_sha:0:12}"
}

# Measure a FROZEN COPY, never the live file. Bash reads a script lazily from a
# byte offset, so editing scripts/review.sh mid-batch splices a running run (one
# exit-127 death already paid for) and, worse, silently lets two runs under one
# label measure two different scripts. ONE copy per BATCH, never per run: an
# experiment measures one script version.
#
# Placed after the unknown-case check above, and every failure below removes the
# copy it made: a snapshot on disk asserts that a batch reached dispatch.
if [ -n "${LOCAL_REVIEW_SH:-}" ]; then
  # The caller already pinned a script (run_ctx_tiers.sh does exactly this to
  # share one snapshot across both its suites). Use it as-is: do not re-snapshot,
  # and do not own its lifetime -- which also means this batch cannot promise the
  # pinned file is frozen. Whoever set the variable owns that.
  REVIEW_RUN="$REVIEW_SRC"
  REVIEW_SHA=$(review_sha "$REVIEW_RUN") || exit 2
  echo "run_eval.sh: pinned review script $REVIEW_RUN (sha256 $REVIEW_SHA)" >&2
else
  # The X's must be TRAILING: BSD mktemp substitutes only a trailing run of
  # them, so a "$LABEL-XXXXXX.review.sh" template creates a file named literally
  # that and every later batch dies "File exists" -- reusing one snapshot across
  # batches, the precise thing this block exists to prevent. Never keyed on the
  # label alone, for the same reason.
  REVIEW_RUN=$(mktemp "$EVAL_DIR/logs/$LABEL.review.sh.XXXXXX") \
    || { echo "run_eval.sh: could not create a snapshot of $REVIEW_SRC" >&2; exit 2; }
  cp "$REVIEW_SRC" "$REVIEW_RUN" \
    || { echo "run_eval.sh: could not copy $REVIEW_SRC to $REVIEW_RUN" >&2; rm -f "$REVIEW_RUN"; exit 2; }
  # Checksum the COPY, never the source: a save landing between the cp and the
  # hash would stamp this batch with a version the executed bytes do not have --
  # the same misattribution the snapshot exists to prevent, one step earlier.
  REVIEW_SHA=$(review_sha "$REVIEW_RUN") || { rm -f "$REVIEW_RUN"; exit 2; }
  # KEPT, not cleaned up: `bash "$REVIEW_RUN"` makes this path the one bash names
  # in a syntax error, so it has to still exist when someone reads the .err.
  echo "run_eval.sh: snapshot $REVIEW_RUN (sha256 $REVIEW_SHA) of $REVIEW_SRC" >&2
fi

if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$REPO"
  cp "$EVAL_DIR"/base/*.py "$REPO/"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "base: store + parser"
fi

[ -f "$RESULTS" ] || printf 'label\tcase\trun\texit\texpected\tsecs\tnfind\tfound\tfound_any\tstatus\tdate\tsha\tvsurv\tvtotal\n' > "$RESULTS"

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
    # Fail closed on a drifted marker, same reasoning as the case-name check:
    # a marker no longer present in the patched repo (e.g. the base file's
    # docstring was reworded) records found=0 on every run, and no log
    # distinguishes that from a genuine model miss.
    if [ -n "$marker" ] && ! grep -rqF --exclude-dir=.git -- "$marker" "$REPO"; then
      echo "run_eval.sh: case '$c' marker not found in patched repo -- fixture drifted" >&2
      exit 2
    fi

    log="$EVAL_DIR/logs/$LABEL-$c-r$run.txt"
    t0=$(date +%s)
    ( cd "$REPO" && bash "$REVIEW_RUN" --provider "$PROVIDER" --model "$MODEL" $EXTRA_ARGS ) \
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

    # Both counts, or neither. review.sh emits this line only when --verify is
    # on AND the audit found something, so its absence is the "did not verify"
    # signal and both cells stay empty.
    #
    # The leading .* is not decoration: the line arrives through review.sh's
    # `note` helper, which prefixes `local-review: ` (scripts/review.sh:45,679),
    # so a pattern anchored at ^verify: matches on no run ever made -- and the
    # symptom is two empty cells, identical to a run that never verified. Same
    # idiom as the nfind scrape above, for the same reason.
    vsurv=""; vtotal=""
    vpair=$(sed -n 's|.*verify: \([0-9][0-9]*\)/\([0-9][0-9]*\) finding(s) survived.*|\1 \2|p' "$log.err" | tail -1)
    if [ -n "$vpair" ]; then vsurv="${vpair% *}"; vtotal="${vpair#* }"; fi

    # Empty until the classifier lands (phase infra-status): a run that reached
    # the model and produced a verdict is a clean measurement by definition.
    status=""
    # Per row, never hoisted: a batch that starts at 23:50 and runs four hours
    # would otherwise stamp every row with the day it began.
    rowdate=$(date +%F)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$LABEL" "$c" "$run" "$rc" "$expected_exit" "$secs" "$nfind" "$found" "$found_any" \
      "$status" "$rowdate" "$REVIEW_SHA" "$vsurv" "$vtotal" \
      | tee -a "$RESULTS"
  done
done
git -C "$REPO" checkout -q -- .
