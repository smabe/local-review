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

# --- infrastructure failures are not model failures --------------------------
#
# The patterns the classifier below greps for, each ANCHORED on the
# `local-review: ` prefix review.sh's die/note helpers add (scripts/review.sh:44-45).
# The anchor is not decoration: verdict reasons reach stderr under --json, which
# is a single-word flag EXTRA_ARGS accepts, and a reviewed diff can contain any
# of these phrases literally.
#
# SIG_AUDIT is an ALLOWLIST, not a blocklist. review.sh emits its audit footer
# before all five of its audit exit paths (scripts/review.sh:556-557), so
# footer present <=> a measurement happened, whatever the exit code was. A
# blocklist of known failure signatures is strictly weaker: the two below were
# collected on one night that ALSO produced an exit-127 bash splice, which
# matches neither.
#
# Never retype these from memory -- tests/test_bench_runners.sh asserts each is
# still a live prefix of a real review.sh message, so a reword fails there
# instead of silently matching nothing forever after.
SIG_AUDIT='^local-review: audit: '
SIG_SERVER='^local-review: no server answering at '
SIG_LOCK='^local-review: another local review (pid '
# The batch refused for an infrastructure reason: nothing was measured and
# nothing was recorded, so re-running the identical command is the fix. 75 is
# EX_TEMPFAIL from sysexits.h, and it is deliberately NOT the existing exit 2,
# which means the opposite -- "the fixture is invalid, do not resume".
INFRA_EXIT=75
# Same default and same override as scripts/review.sh:38, because it is the
# same probe against the same endpoint.
LLAMA_URL="${LOCAL_REVIEW_LLAMA_URL:-http://localhost:8080/v1/models}"
PROBE_TRIES="${LOCAL_REVIEW_PROBE_TRIES:-5}"
PROBE_SLEEP="${LOCAL_REVIEW_PROBE_SLEEP:-15}"

# classify_run RC ERRLOG -- print the row's `status`. THE ORDER IS LOAD-BEARING.
classify_run() {
  # 1. A timeout is a real observation and the exit column already records it.
  #    FIRST, because the watchdog kills review.sh BEFORE its audit block runs:
  #    a timed-out run has no footer, so a naive footer-absent rule files every
  #    slow run as infrastructure -- which under phase `resume` would make
  #    timeouts retryable and silently delete the slow tail of every arm.
  if [ "$1" -eq 124 ]; then return 0; fi
  # 2. Footer present, so a measurement happened. Exit code irrelevant.
  if grep -q "$SIG_AUDIT" "$2" 2>/dev/null; then return 0; fi
  # 3. review.sh refused before it ever reached the model. Terminal (below).
  if grep -q "$SIG_SERVER" "$2" 2>/dev/null; then printf 'SERVER-DOWN'; return 0; fi
  if grep -q "$SIG_LOCK" "$2" 2>/dev/null; then printf 'LOCKED'; return 0; fi
  # 4. The open bucket, and it is not optional: OOM, a pi crash, a model-unload
  #    race and a full disk all arrive here indistinguishable from each other.
  #    A blank status a reader TRUSTS is worse than an explicit unknown, so this
  #    fires on a clean exit with no footer too -- review.sh cannot produce one.
  printf 'SUSPECT'
}

# abort_infra STATUS RC -- one terminal row, then stop the batch.
#
# ONE row: zero would make a truncated arm indistinguishable from a
# deliberately short one, and one row per remaining run is the 14-junk-rows
# incident this phase exists to prevent.
#
# The row is not a measurement and MUST NOT occupy a dispatchable key. `run`
# carries the reserved non-numeric token `abort` and `case` is empty, so the
# key-existence scan phase `resume` performs -- numeric `run` values only --
# can never match it. That is what stops an aborted batch from poisoning the
# key it failed on forever.
#
# The numeric columns are padded with 0 rather than left empty because
# summarize_ctx_tiers.py int-casts `secs` and `found` across every row of a
# label; a marked MEASUREMENT row leaves them empty instead, but no reader
# indexes this one, so padding costs nothing and keeps a naive sweep alive.
abort_infra() {
  echo "run_eval.sh: $1 -- infrastructure failure, nothing recorded for this attempt." >&2
  echo "run_eval.sh: fix the cause, then re-run the identical command (exit $INFRA_EXIT)." >&2
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "" "abort" "$2" "" "0" "0" "0" "0" \
    "$1" "$(date +%F)" "$REVIEW_SHA" "" "" >> "$RESULTS"
  exit "$INFRA_EXIT"
}

# probe_server -- is anything answering, checked BETWEEN runs.
#
# It proves a port answers and NOTHING more: not that the labelled model is the
# one loaded, not that a generation will succeed. The footer allowlist above
# still has to fail closed exactly as if this did not exist.
#
# Retried rather than single-shot: a loaded machine mid-prefill does not answer
# promptly, and killing a healthy 40-minute arm on one false negative is
# self-inflicted evidence loss. run_ctx_tiers.sh:130-139 retries for twenty
# minutes for the same reason, against a server that is still loading.
probe_server() {
  # Only llamaserver serves this endpoint. lmstudio's own reachability check
  # lives in review.sh and reports back through the classifier above.
  if [ "$PROVIDER" != "llamaserver" ]; then return 0; fi
  # A missing curl is review.sh's story to tell (scripts/review.sh:163); an
  # infrastructure abort here would bury its far more specific message.
  if ! command -v curl >/dev/null 2>&1; then return 0; fi
  _try=1
  while :; do
    if curl -sf --max-time 10 "$LLAMA_URL" >/dev/null 2>&1; then return 0; fi
    if [ "$_try" -ge "$PROBE_TRIES" ]; then return 1; fi
    _try=$((_try + 1))
    echo "run_eval.sh: nothing answering at $LLAMA_URL, retry $_try/$PROBE_TRIES" >&2
    sleep "$PROBE_SLEEP"
  done
}
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
    # Before the patch is applied, before a log exists, before anything is
    # dispatched: an attempt refused here must leave no artifact that could be
    # mistaken for a run, and no per-run row at all.
    probe_server || abort_infra SERVER-DOWN ""

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

    # Classified as early as the rc allows, so a refusal aborts before any of
    # the scraping below can dress it up as a measurement.
    status=$(classify_run "$rc" "$log.err")
    case "$status" in
      SERVER-DOWN|LOCKED) abort_infra "$status" "$rc" ;;
    esac

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
