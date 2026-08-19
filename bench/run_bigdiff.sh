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

# --- infrastructure failures are not model failures --------------------------
# Identical in shape and reasoning to run_eval.sh, which carries the full
# commentary: an ALLOWLIST on review.sh's audit footer decides whether a run was
# a measurement at all, the two refusal signatures are anchored on the
# `local-review: ` prefix its die helper adds, and none of the three is ever
# retyped from memory -- tests/test_bench_runners.sh ties each back to a live
# message in scripts/review.sh.
# TWO server signatures for the same reason as there: probe_server covers only
# llamaserver, so a dead LM Studio is visible ONLY through review.sh's own
# refusal (scripts/review.sh:154).
SIG_AUDIT='^local-review: audit: '
SIG_SERVER='^local-review: no server answering at '
SIG_LMSTUDIO='^local-review: LM Studio server is down on '
SIG_LOCK='^local-review: another local review (pid '
# EX_TEMPFAIL: nothing was measured and nothing recorded, so re-running the
# identical command is the fix. Deliberately not the existing exit 2, which
# means "the fixture is invalid, do not resume".
INFRA_EXIT=75
LLAMA_URL="${LOCAL_REVIEW_LLAMA_URL:-http://localhost:8080/v1/models}"
PROBE_TRIES="${LOCAL_REVIEW_PROBE_TRIES:-5}"
PROBE_SLEEP="${LOCAL_REVIEW_PROBE_SLEEP:-15}"

# classify_run RC ERRLOG -- the row's `status`. THE ORDER IS LOAD-BEARING; see
# run_eval.sh for what each step costs to get wrong.
classify_run() {
  # A timeout is a real observation, and the watchdog kills review.sh before its
  # audit block -- so this MUST precede the footer rule.
  if [ "$1" -eq 124 ]; then return 0; fi
  if grep -q "$SIG_AUDIT" "$2" 2>/dev/null; then return 0; fi
  if grep -q "$SIG_SERVER" "$2" 2>/dev/null; then printf 'SERVER-DOWN'; return 0; fi
  if grep -q "$SIG_LMSTUDIO" "$2" 2>/dev/null; then printf 'SERVER-DOWN'; return 0; fi
  if grep -q "$SIG_LOCK" "$2" 2>/dev/null; then printf 'LOCKED'; return 0; fi
  printf 'SUSPECT'
}

# abort_infra STATUS RC -- one terminal row, then stop the batch. `run` is the
# reserved non-numeric token `abort` so the row can never occupy a dispatchable
# key; the numeric columns are padded because no reader indexes this row, while
# a marked MEASUREMENT row leaves them honestly empty.
abort_infra() {
  echo "run_bigdiff.sh: $1 -- infrastructure failure, nothing recorded for this attempt." >&2
  echo "run_bigdiff.sh: fix the cause, then re-run the identical command (exit $INFRA_EXIT)." >&2
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "abort" "$2" "0" "0" "0" "0" "" \
    "$1" "$(date +%F)" "$REVIEW_SHA" "" "" >> "$RESULTS"
  exit "$INFRA_EXIT"
}

# probe_server -- proves a port answers and nothing more. Retried, never
# single-shot: a loaded machine mid-prefill does not answer promptly, and a
# bigdiff run is the longest thing in the bench to lose to a false negative.
probe_server() {
  if [ "$PROVIDER" != "llamaserver" ]; then return 0; fi
  if ! command -v curl >/dev/null 2>&1; then return 0; fi
  _try=1
  while :; do
    if curl -sf --max-time 10 "$LLAMA_URL" >/dev/null 2>&1; then return 0; fi
    if [ "$_try" -ge "$PROBE_TRIES" ]; then return 1; fi
    _try=$((_try + 1))
    echo "run_bigdiff.sh: nothing answering at $LLAMA_URL, retry $_try/$PROBE_TRIES" >&2
    sleep "$PROBE_SLEEP"
  done
}

mkdir -p "$EVAL_DIR/logs"

# --- one batch at a time per results file -------------------------------------
#
# Identical in shape and reasoning to run_eval.sh, which carries the full
# commentary: resume reads the very file it appends to, so two batches racing on
# one results file both compute the same missing set and both dispatch it. The
# protocol is `mkdir` and nothing else (scripts/review.sh:210), nothing reclaims
# a lock it did not create, and the INT/TERM traps are what make that rule
# affordable. Taken before the snapshot so a blocked batch leaves no copy
# asserting it reached dispatch.
RESULTS_LOCK="$RESULTS.lock"
LOCK_HELD=""
# Every branch a full `if`: bash adopts the trap's LAST command status.
release_lock() {
  if [ -n "$LOCK_HELD" ]; then rm -rf "$LOCK_HELD"; fi
}
trap release_lock EXIT
# Nothing may interrupt between creating the directory and recording that we own
# it: the EXIT trap can only remove a lock it can see.
trap '' INT TERM
if ! mkdir "$RESULTS_LOCK" 2>/dev/null; then
  trap 'exit 130' INT; trap 'exit 143' TERM
  _owner=$(cat "$RESULTS_LOCK/pid" 2>/dev/null || true)
  if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null; then
    echo "run_bigdiff.sh: another batch (pid $_owner) is appending to $RESULTS -- wait for it to finish, then re-run the identical command." >&2
  else
    echo "run_bigdiff.sh: a results lock is present but its owner is gone. If no batch is running: rm -rf \"$RESULTS_LOCK\"" >&2
  fi
  # No terminal row: the process holding the lock is writing that label's rows
  # right now, and a row claiming the arm aborted would be a false statement
  # about a run that is going fine.
  exit "$INFRA_EXIT"
fi
LOCK_HELD="$RESULTS_LOCK"
trap 'exit 130' INT; trap 'exit 143' TERM
printf '%s\n' "$$" > "$RESULTS_LOCK/pid" || echo "run_bigdiff.sh: could not record the lock owner pid" >&2

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
  # Not ours to delete on a later refusal; whoever pinned it owns its lifetime.
  SNAPSHOT_OWNED=""
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
  # Ours, so a refusal below has to take it with it -- a snapshot on disk is
  # what asserts that a batch reached dispatch.
  SNAPSHOT_OWNED="$REVIEW_RUN"
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

# --- resume: RUNS means "ensure N rows exist for this key" --------------------
#
# Identical in shape and reasoning to run_eval.sh, which carries the full
# commentary, over the key (label, run) rather than (label, case, run). The skip
# predicate is key-existence and nothing else -- a row exists iff the run
# reached the model, the terminal abort row reserves a non-numeric `run`, and
# every marker is a terminal observation that is never re-sampled.
NL='
'
KSEP=$(printf '\t')   # a TSV cell cannot contain one, so joined keys cannot collide
RECORDED=""
RECORDED_N=0

# A kill during an append leaves a final line with no newline; appending to it
# would glue the next row onto its tail. The short line itself stays -- it is
# corruption, not a completed key.
if [ -s "$RESULTS" ] && [ -n "$(tail -c 1 "$RESULTS")" ]; then
  echo "run_bigdiff.sh: $RESULTS does not end in a newline (a batch killed mid-append) -- starting the next row on a fresh line" >&2
  printf '\n' >> "$RESULTS"
fi

# scan_recorded COLUMN... -- fill RECORDED / RECORDED_N from $RESULTS. Columns
# are addressed BY NAME so a later widening cannot silently re-key this; a row
# wider than the header or cut short of the key columns is dropped loudly, while
# one merely narrower than the header is a pre-provenance row and is silent.
scan_recorded() {
  RECORDED=$(awk -F'\t' -v label="$LABEL" -v cols="$*" -v sep="$KSEP" \
                 -v runner="run_bigdiff.sh" -v f="$RESULTS" '
    NR == 1 {
      hn = NF
      for (i = 1; i <= NF; i++) idx[$i] = i
      nw = split(cols, want, " ")
      for (i = 1; i <= nw; i++) {
        if (!(want[i] in idx)) {
          print runner ": " f " has no `" want[i] "` column -- refusing to resume" > "/dev/stderr"
          bad = 1
          exit
        }
        if (idx[want[i]] > keymax) keymax = idx[want[i]]
      }
      next
    }
    NF > hn {
      print runner ": " f " line " NR " has " NF " fields against a " hn "-column header -- ignored" > "/dev/stderr"
      next
    }
    NF < keymax {
      print runner ": " f " line " NR " is truncated (" NF " field(s)) -- ignored, and its key will be re-run" > "/dev/stderr"
      next
    }
    $(idx["label"]) != label { next }
    $(idx["run"]) !~ /^[0-9]+$/ { next }
    {
      key = $(idx[want[1]])
      for (i = 2; i <= nw; i++) key = key sep $(idx[want[i]])
      print key
    }
    END { if (bad) exit 2 }
  ' "$RESULTS") || exit 2
  if [ -n "$RECORDED" ]; then
    RECORDED_N=$(printf '%s\n' "$RECORDED" | wc -l | tr -d ' ')
  else
    RECORDED_N=0
  fi
}

# recorded KEYPART... -- is this key already on disk?
recorded() {
  _k="$1"; shift
  while [ "$#" -gt 0 ]; do _k="$_k$KSEP$1"; shift; done
  case "$NL$RECORDED$NL" in
    *"$NL$_k$NL"*) return 0 ;;
  esac
  return 1
}

# provenance_guard -- refuse to extend an arm measured with a different script
# than this batch runs. A MISSING sha is never a signal: every row written
# before the column existed has none.
provenance_guard() {
  awk -F'\t' -v label="$LABEL" -v sha="$REVIEW_SHA" \
             -v runner="run_bigdiff.sh" -v f="$RESULTS" '
    NR == 1 {
      hn = NF
      for (i = 1; i <= NF; i++) idx[$i] = i
      if (!("label" in idx) || !("run" in idx) || !("sha" in idx)) {
        print runner ": " f " has no label/run/sha column -- refusing to resume" > "/dev/stderr"
        bad = 1
        exit
      }
      next
    }
    NF > hn || NF < idx["sha"] { next }
    $(idx["label"]) != label { next }
    # The terminal abort row is not a measurement, so its sha is not evidence
    # that this label was measured by another script.
    $(idx["run"]) !~ /^[0-9]+$/ { next }
    $(idx["sha"]) == "" || $(idx["sha"]) == sha { next }
    { seen[$(idx["sha"])] = 1 }
    END {
      if (bad) exit 2
      n = 0
      for (s in seen) { n++; list = list (n > 1 ? ", " : "") s }
      if (n) {
        print runner ": " label " already carries rows from a different script (" list "); this batch runs " sha "." > "/dev/stderr"
        print runner ": resuming would mix two script versions under one label -- use a new label, or move the old rows aside." > "/dev/stderr"
        exit 2
      }
    }
  ' "$RESULTS"
}

if ! provenance_guard; then
  if [ -n "$SNAPSHOT_OWNED" ]; then rm -f "$SNAPSHOT_OWNED"; fi
  exit 2
fi

scan_recorded label run
_want=0; _have=0
for run in $(seq 1 "$RUNS"); do
  _want=$((_want + 1))
  if recorded "$LABEL" "$run"; then _have=$((_have + 1)); fi
done
echo "run_bigdiff.sh: $LABEL: $_have of $_want already recorded, dispatching $((_want - _have))" >&2
if [ "$RECORDED_N" -gt "$_want" ]; then
  echo "run_bigdiff.sh: $LABEL: $RECORDED_N row(s) already recorded, more than the $_want requested -- RUNS never deletes rows." >&2
fi

for run in $(seq 1 "$RUNS"); do
  # FIRST in the body, and the position is the whole point: below the log
  # rotation this would move the transcript aside for every row it then skips,
  # and rescore_bigdiff.py would report "no usable log" for the entire resumed
  # arm -- destroying the durable evidence while adding a feature meant to
  # protect it.
  if recorded "$LABEL" "$run"; then continue; fi

  # Before the fixture is reset, before a log exists, before anything is
  # dispatched: a refused attempt leaves no artifact and no per-run row.
  probe_server || abort_infra SERVER-DOWN ""

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

  # Classified before anything is scraped or scored, so a refusal aborts before
  # the columns below can dress it up as a measurement.
  status=$(classify_run "$rc" "$log.err")
  case "$status" in
    SERVER-DOWN|LOCKED) abort_infra "$status" "$rc" ;;
  esac

  nfind=$(sed -n 's/.*audit: .*ok, \([0-9][0-9]*\) defect(s).*/\1/p' "$log.err" | tail -1)
  [ -n "$nfind" ] || nfind=0

  # The scorer's markers describe the SCORING; the classifier above described
  # the RUN. So they only fill a status it left empty -- and never on a timeout,
  # whose partial transcript is already fully explained by exit=124. Overwriting
  # that would move every timeout out of the detection denominator, which is the
  # opposite of what a timeout means.
  #
  # hits/other/bugs stay EMPTY on a marked row rather than the old
  # `0 0 SCORE-ERROR` padding: a zero in `hits` is indistinguishable from a
  # review that genuinely matched none of the six known bugs, and `bugs` is
  # parsed as a list of bug ids. watch_ctx_tiers.py renders the exit-127
  # bash-splice row as "0 known bugs" to this day for exactly that reason.
  hits=""; other=""; bugs=""
  score=$(python3 "$EVAL_DIR/score_bigdiff.py" "$log"); srr=$?
  if [ "$srr" -eq 0 ] && [ -n "$score" ]; then
    read -r hits other bugs <<EOF
$score
EOF
  elif [ "$srr" -eq 3 ]; then
    # score_bigdiff.py's EMPTY_LOG_EXIT: a transcript with nothing in it. Its own
    # exit code rather than a token in stdout, so the marker cannot land in a
    # measurement column on the way past.
    if [ -z "$status" ] && [ "$rc" -ne 124 ]; then status="EMPTY-LOG"; fi
    echo "run_bigdiff.sh: empty transcript for $log -- row marked EMPTY-LOG" >&2
  else
    if [ -z "$status" ] && [ "$rc" -ne 124 ]; then status="SCORE-ERROR"; fi
    echo "run_bigdiff.sh: score_bigdiff.py failed for $log (rc $srr) -- row marked SCORE-ERROR" >&2
  fi

  # Both counts or neither, scraped with the same leading-.* idiom as nfind
  # above: the line is prefixed by review.sh's `note` helper, so anchoring at
  # ^verify: would match nothing and leave two empty cells that read exactly
  # like a run which never verified.
  vsurv=""; vtotal=""
  vpair=$(sed -n 's|.*verify: \([0-9][0-9]*\)/\([0-9][0-9]*\) finding(s) survived.*|\1 \2|p' "$log.err" | tail -1)
  if [ -n "$vpair" ]; then vsurv="${vpair% *}"; vtotal="${vpair#* }"; fi

  # Per row, never hoisted out of the loop -- a bigdiff batch runs for hours.
  rowdate=$(date +%F)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "$run" "$rc" "$secs" "$nfind" "$hits" "$other" "$bugs" \
    "$status" "$rowdate" "$REVIEW_SHA" "$vsurv" "$vtotal" \
    | tee -a "$RESULTS"
done

git -C "$REPO" reset -q --hard
git -C "$REPO" clean -qfd
