#!/usr/bin/env bash
# run_bigdiff.sh PROVIDER MODEL RUNS LABEL — replay the 18KB bigdiff fixture.
#
# The small-case bench (run_eval.sh) measures detection on one-bug diffs. This
# one measures the failure that actually settled the default: a review that
# comes back clean on a diff large enough to matter. Same watchdog discipline,
# same TSV shape, different scoring — bigdiff carries six known bugs, so a run
# is scored by WHICH of them were quoted, plus a count of findings matching
# none of them (fabrication candidates, to be read by hand in logs/).
#
# Appends TSV rows to results-bigdiff.tsv:
#   label run exit secs nfind hits other bugs status date sha vsurv vtotal
#     nfind  the audit's own validated finding count
#     hits   how many of the six known bugs were quoted
#     other  finding blocks matching no known bug (read the log before judging)
#     bugs   comma-separated ids of the ones hit
#   The five-column tail is shared with run_eval.sh, same names in the same
#   order, and carries the same meaning -- see bench/run_eval.sh's header
#   comment for what each one is and why vsurv/vtotal are empty rather than 0.
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
# The script under test. What actually EXECUTES is REVIEW_RUN, a frozen copy
# taken once below -- grep for that one to learn what a batch ran.
REVIEW_SRC="${LOCAL_REVIEW_SH:-$EVAL_DIR/../scripts/review.sh}"
REPO="$EVAL_DIR/bigdiff-repo"
FIXTURE="$EVAL_DIR/bigdiff"
RESULTS="$EVAL_DIR/results-bigdiff.tsv"
# Prior bigdiff runs took 556 s and 881 s at 49152; the small-case default of
# 900 s would score the slow tail as a timeout.
TIMEOUT="${LOCAL_REVIEW_BIGDIFF_TIMEOUT:-2400}"
PROVIDER="$1"; MODEL="$2"; RUNS="${3:-1}"; LABEL="${4:?label required}"

mkdir -p "$EVAL_DIR/logs"

# Snapshot the reviewed script, identical in shape to run_eval.sh (which carries
# the full reasoning): checksum first so a batch that cannot record its script
# version leaves no copy behind, then one frozen copy per BATCH -- never per run,
# and never the live file, which bash reads lazily and a mid-batch edit splices.
review_sha() {
  # An unreadable path is reported as itself, not folded into the no-tool case.
  if [ ! -r "$1" ]; then
    echo "run_bigdiff.sh: cannot read $1 -- no script to review" >&2
    return 1
  fi
  _sha=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
  if [ -z "$_sha" ]; then _sha=$(sha256sum "$1" 2>/dev/null | awk '{print $1}'); fi
  if [ -z "$_sha" ]; then
    echo "run_bigdiff.sh: no working shasum or sha256sum -- refusing a batch whose script version cannot be recorded" >&2
    return 1
  fi
  printf '%s' "${_sha:0:12}"
}

if [ -n "${LOCAL_REVIEW_SH:-}" ]; then
  # The caller pinned a script (run_ctx_tiers.sh shares one snapshot across both
  # suites). Use it as-is: do not re-snapshot, do not own its lifetime -- and so
  # this batch cannot promise the pinned file is frozen; whoever set it owns that.
  REVIEW_RUN="$REVIEW_SRC"
  REVIEW_SHA=$(review_sha "$REVIEW_RUN") || exit 2
  echo "run_bigdiff.sh: pinned review script $REVIEW_RUN (sha256 $REVIEW_SHA)" >&2
else
  # Trailing X's are mandatory -- BSD mktemp substitutes only a trailing run of
  # them, and a literal-named template makes every later batch die "File exists".
  REVIEW_RUN=$(mktemp "$EVAL_DIR/logs/$LABEL.review.sh.XXXXXX") \
    || { echo "run_bigdiff.sh: could not create a snapshot of $REVIEW_SRC" >&2; exit 2; }
  cp "$REVIEW_SRC" "$REVIEW_RUN" \
    || { echo "run_bigdiff.sh: could not copy $REVIEW_SRC to $REVIEW_RUN" >&2; rm -f "$REVIEW_RUN"; exit 2; }
  # Checksum the COPY, never the source: a save landing between the cp and the
  # hash would stamp this batch with a version the executed bytes do not have.
  REVIEW_SHA=$(review_sha "$REVIEW_RUN") || { rm -f "$REVIEW_RUN"; exit 2; }
  # KEPT: this path is what bash names in a syntax error, so it must outlive the
  # batch for the .err beside it to be readable.
  echo "run_bigdiff.sh: snapshot $REVIEW_RUN (sha256 $REVIEW_SHA) of $REVIEW_SRC" >&2
fi

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

[ -f "$RESULTS" ] || printf 'label\trun\texit\tsecs\tnfind\thits\tother\tbugs\tstatus\tdate\tsha\tvsurv\tvtotal\n' > "$RESULTS"

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
  ( cd "$REPO" && bash "$REVIEW_RUN" --provider "$PROVIDER" --model "$MODEL" ${LOCAL_REVIEW_EVAL_ARGS:-} ) \
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

  # Both counts or neither, scraped with the same leading-.* idiom as nfind
  # above: the line is prefixed by review.sh's `note` helper, so anchoring at
  # ^verify: would match nothing and leave two empty cells that read exactly
  # like a run which never verified.
  vsurv=""; vtotal=""
  vpair=$(sed -n 's|.*verify: \([0-9][0-9]*\)/\([0-9][0-9]*\) finding(s) survived.*|\1 \2|p' "$log.err" | tail -1)
  if [ -n "$vpair" ]; then vsurv="${vpair% *}"; vtotal="${vpair#* }"; fi

  # Empty until the classifier lands (phase infra-status). SCORE-ERROR still
  # rides the bugs column for now; that migration belongs to the same phase.
  status=""
  # Per row, never hoisted out of the loop -- a bigdiff batch runs for hours.
  rowdate=$(date +%F)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "$run" "$rc" "$secs" "$nfind" "$hits" "$other" "$bugs" \
    "$status" "$rowdate" "$REVIEW_SHA" "$vsurv" "$vtotal" \
    | tee -a "$RESULTS"
done

git -C "$REPO" reset -q --hard
git -C "$REPO" clean -qfd
