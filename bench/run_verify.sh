#!/usr/bin/env bash
# run_verify.sh PROVIDER MODEL RUNS LABEL — verifier capability probe over
# bench/verify/items (docs/verifier-pass.md). Appends TSV rows to
# bench/results-verify.tsv:
#   label item run verdict truth gating secs agree status date sha
#
# `status` and `date` mean what they mean in the other two runners. `sha` is
# THIS script's own checksum, because this runner never invokes review.sh --
# the artifact under measurement here is the verifier prompt below, which lives
# in this file. There is deliberately no vsurv/vtotal pair: this IS the verifier
# probe, `verdict` already carries the survivor signal those columns add
# elsewhere, and a permanently-empty column trains readers to skim past
# emptiness -- after which a genuine parse failure in a verify arm reads as
# normal.
#
# `verdict=none` alone no longer says what happened. It used to mean both "the
# model answered something unparseable" and "nothing ran at all"; the second now
# carries a non-empty `status` and the first does not. `agree` is EMPTY on any
# marked row, never 0 -- a 0 there reads as the verifier disagreeing with ground
# truth, which turns a missing answer into a wrong one and biases the arm
# pessimistically with nothing in the row to catch it.
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$EVAL_DIR/eval-repo"
RESULTS="$EVAL_DIR/results-verify.tsv"
PROVIDER="$1"; MODEL="$2"; RUNS="${3:-1}"; LABEL="${4:?label required}"

SYSTEM_PROMPT='You are a review verifier. You do not write or fix code. You are given ONE finding from an earlier automated review of this repository, and your entire job is to decide whether it survives adversarial checking.
Rules you must obey:
1. First read the named file. If the quoted line does not appear in it, the finding is refuted -- a finding that cannot be located is not a finding.
2. Re-derive the DEFECT claim from the code alone. Actively look for the guard, type, short-circuit, or call pattern that would make the claimed FAILURE impossible.
3. Verdict "refuted" requires constructible evidence: name the exact line, guard, or language rule that defeats the claim. Plausible doubt is not evidence.
4. If you cannot construct such a refutation, the verdict is "real" -- this pass exists to kill provably false findings, not to second-guess plausible ones.
5. Judge only the finding you were given. Never report new defects.
Your entire output is exactly two lines:
VERDICT: real
REASON: <one line>
or
VERDICT: refuted
REASON: <one line>'

# This runner's own version, recorded on every row it writes. Two-way fallback
# because neither tool is universal -- shasum is perl (macOS yes, minimal Linux
# no), sha256sum is coreutils (the reverse) -- and an empty result covers "not
# installed" and "installed but broken" alike. Refuse rather than record a blank
# version: a probe whose prompt version is unknown is not evidence.
# (Hand-copied from run_eval.sh's review_sha, which is now the fourth copy of
# this block; see plans/bench-row-hardening.md's Findings log.)
SELF="$EVAL_DIR/$(basename "$0")"
if [ ! -r "$SELF" ]; then
  echo "run_verify.sh: cannot read $SELF -- no version to record" >&2; exit 2
fi
RUN_SHA=$(shasum -a 256 "$SELF" 2>/dev/null | awk '{print $1}')
if [ -z "$RUN_SHA" ]; then RUN_SHA=$(sha256sum "$SELF" 2>/dev/null | awk '{print $1}'); fi
if [ -z "$RUN_SHA" ]; then
  echo "run_verify.sh: no working shasum or sha256sum -- refusing a batch whose script version cannot be recorded" >&2
  exit 2
fi
RUN_SHA="${RUN_SHA:0:12}"
echo "run_verify.sh: $SELF (sha256 $RUN_SHA)" >&2

# --- infrastructure failures are not model failures --------------------------
#
# Same purpose as in run_eval.sh and run_bigdiff.sh, one step different. Those
# two allowlist review.sh's audit footer; this runner never invokes review.sh,
# so there is no footer here and NEITHER of its refusal signatures can ever
# appear -- failures arrive out of `pi` directly. The allowlist is therefore the
# thing pi is here to produce: a finished assistant answer. The extractor in the
# loop below already drops messages that did not finish (stopReason != stop) or
# errored, so a non-empty extract means the model answered -- whether or not it
# answered in the shape the prompt demanded.
#
# There is no LOCKED analogue for the same reason. review.sh's lock guards
# review.sh; this runner never takes it and never sees its refusal, so a grep
# for that signature would be a pattern that cannot match. A concurrent review
# is still a hazard here, and it is one this runner cannot observe.
#
# EX_TEMPFAIL, and the same value the other two use: nothing was measured and
# nothing recorded, so re-running the identical command is the fix. Deliberately
# not the existing exit 2, which means "the fixture is invalid, do not resume".
INFRA_EXIT=75
# Prior verify items ran 100-149 s at 49152 against the measured reviewer, so
# this is roughly 4x the slowest one observed. NOT the small-case runner's 900 s
# default: a verifier item is a single finding and is much faster, and 900 s
# would score a genuinely stuck item as a fifteen-minute measurement.
#
# Deliberately NOT added to run_ctx_tiers.sh's unset list. That orchestrator
# dispatches run_eval.sh and run_bigdiff.sh only, so a run_verify.sh-only knob
# there would be a dead entry; tests/test_bench_runners.sh asserts that premise
# rather than leaving it to a reader.
TIMEOUT="${LOCAL_REVIEW_VERIFY_TIMEOUT:-600}"
# Same default and same override as scripts/review.sh:38 and the other two
# runners, because it is the same probe against the same endpoint.
LLAMA_URL="${LOCAL_REVIEW_LLAMA_URL:-http://localhost:8080/v1/models}"
PROBE_TRIES="${LOCAL_REVIEW_PROBE_TRIES:-5}"
PROBE_SLEEP="${LOCAL_REVIEW_PROBE_SLEEP:-15}"

# classify_run RC ANSWER -- print the row's `status`. THE ORDER IS LOAD-BEARING.
classify_run() {
  # 1. A timeout first, and for a reason the other two runners do not share:
  #    results-verify.tsv has no `exit` column, so a 124 has nowhere else to
  #    live. `secs` on such a row is the watchdog's timeout rather than a
  #    latency, so even an answer recovered from a killed run is not a clean
  #    measurement -- hence this precedes the answer rule rather than following
  #    it.
  if [ "$1" -eq 124 ]; then printf 'TIMEOUT'; return 0; fi
  # 2. The model produced a finished answer, so a measurement happened. An
  #    answer in the wrong SHAPE is still a model result worth keeping: it
  #    reads as verdict=none with an empty status, and only "nothing ran at
  #    all" is marked.
  #
  #    Tested for non-whitespace content, NOT with -s: the extractor below ends
  #    in a bare `print(txt)`, so a run that produced nothing still leaves a
  #    one-byte file behind and -s would call every dead server a measurement.
  if grep -q '[^[:space:]]' "$2" 2>/dev/null; then return 0; fi
  # 3. The open bucket, and it is not optional: a dead server, an OOM, a pi
  #    crash and a model-unload race all arrive here indistinguishable from
  #    each other. It fires on a clean exit too -- pi cannot exit 0 with
  #    nothing to show and have measured anything.
  printf 'SUSPECT'
}

# abort_infra STATUS -- one terminal row, then stop the batch.
#
# ONE row: zero would make a truncated arm indistinguishable from a deliberately
# short one, and one row per remaining item is the junk-rows incident this
# whole workstream exists to prevent.
#
# The row is not a measurement and MUST NOT occupy a dispatchable key. `run`
# carries the reserved non-numeric token `abort` and `item` is empty, so a
# key-existence scan over numeric `run` values can never match it.
#
# `gating` and `secs` are padded with 0 rather than left empty, matching the
# other two runners: nothing indexes this row, and a bare int() sweep over a
# label stays alive. `agree` is the one exception and is left EMPTY, because a
# padded 0 there does not read as a placeholder -- it reads as the verifier
# disagreeing with ground truth, which is the false fact this whole phase
# exists to stop the file from asserting. The other two runners can pad their
# equivalents because summarize_ctx_tiers.py filters their abort rows out
# first; results-verify.tsv has no such reader to be protected by.
abort_infra() {
  echo "run_verify.sh: $1 -- infrastructure failure, nothing recorded for this attempt." >&2
  echo "run_verify.sh: fix the cause, then re-run the identical command (exit $INFRA_EXIT)." >&2
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "" "abort" "" "" "0" "0" "" \
    "$1" "$(date +%F)" "$RUN_SHA" >> "$RESULTS"
  exit "$INFRA_EXIT"
}

# probe_server -- is anything answering, checked BETWEEN items.
#
# It proves a port answers and NOTHING more: not that the labelled model is
# loaded, not that a generation will succeed. The classifier above still has to
# fail closed exactly as if this did not exist.
#
# Retried rather than single-shot: a loaded machine mid-prefill does not answer
# promptly, and killing a healthy arm on one false negative is self-inflicted
# evidence loss.
probe_server() {
  # Only llamaserver serves this endpoint. An lmstudio arm is covered by the
  # classifier alone, which is where a dead LM Studio surfaces anyway -- as a
  # pi failure with nothing to show.
  if [ "$PROVIDER" != "llamaserver" ]; then return 0; fi
  # A missing curl is not an infrastructure abort: it would bury the real cause
  # under a probe that never ran.
  if ! command -v curl >/dev/null 2>&1; then return 0; fi
  _try=1
  while :; do
    if curl -sf --max-time 10 "$LLAMA_URL" >/dev/null 2>&1; then return 0; fi
    if [ "$_try" -ge "$PROBE_TRIES" ]; then return 1; fi
    _try=$((_try + 1))
    echo "run_verify.sh: nothing answering at $LLAMA_URL, retry $_try/$PROBE_TRIES" >&2
    sleep "$PROBE_SLEEP"
  done
}

mkdir -p "$EVAL_DIR/logs"

# --- one batch at a time per results file -------------------------------------
#
# Identical in shape and reasoning to the other two runners, which carry the
# full commentary: resume reads the very file it appends to, so two batches
# racing on one results file both compute the same missing set and both dispatch
# it. `mkdir` is the entire protocol (scripts/review.sh:210), nothing reclaims a
# lock it did not create, and the INT/TERM traps are what make that affordable.
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
    echo "run_verify.sh: another batch (pid $_owner) is appending to $RESULTS -- wait for it to finish, then re-run the identical command." >&2
  else
    echo "run_verify.sh: a results lock is present but its owner is gone. If no batch is running: rm -rf \"$RESULTS_LOCK\"" >&2
  fi
  # No terminal row: the process holding the lock is writing that label's rows
  # right now, and a row claiming the arm aborted would be a false statement
  # about a run that is going fine.
  exit "$INFRA_EXIT"
fi
LOCK_HELD="$RESULTS_LOCK"
trap 'exit 130' INT; trap 'exit 143' TERM
printf '%s\n' "$$" > "$RESULTS_LOCK/pid" || echo "run_verify.sh: could not record the lock owner pid" >&2

if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$REPO"; cp "$EVAL_DIR"/base/*.py "$REPO/"
  git -C "$REPO" init -q; git -C "$REPO" add -A
  git -C "$REPO" commit -qm "base: store + parser"
fi
[ -f "$RESULTS" ] || printf 'label\titem\trun\tverdict\ttruth\tgating\tsecs\tagree\tstatus\tdate\tsha\n' > "$RESULTS"

# --- resume: RUNS means "ensure N rows exist for this key" --------------------
#
# Identical in shape and reasoning to the other two runners, which carry the
# full commentary, over the key (label, item, run). `item` is load-bearing in
# that key: 13 items share every run number, so a (label, run) key would skip
# twelve of them. The skip predicate is key-existence and nothing else -- a row
# exists iff the run reached the model, the terminal abort row reserves a
# non-numeric `run`, and every marker (including this runner's own TIMEOUT) is a
# terminal observation that is never re-sampled.
NL='
'
KSEP=$(printf '\t')   # a TSV cell cannot contain one, so joined keys cannot collide
RECORDED=""
RECORDED_N=0

# A kill during an append leaves a final line with no newline; appending to it
# would glue the next row onto its tail. The short line itself stays -- it is
# corruption, not a completed key.
if [ -s "$RESULTS" ] && [ -n "$(tail -c 1 "$RESULTS")" ]; then
  echo "run_verify.sh: $RESULTS does not end in a newline (a batch killed mid-append) -- starting the next row on a fresh line" >&2
  printf '\n' >> "$RESULTS"
fi

# scan_recorded COLUMN... -- fill RECORDED / RECORDED_N from $RESULTS. Columns
# are addressed BY NAME so a later widening cannot silently re-key this; a row
# wider than the header or cut short of the key columns is dropped loudly, while
# one merely narrower than the header is a pre-provenance row and is silent.
scan_recorded() {
  RECORDED=$(awk -F'\t' -v label="$LABEL" -v cols="$*" -v sep="$KSEP" \
                 -v runner="run_verify.sh" -v f="$RESULTS" '
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

# provenance_guard -- refuse to extend an arm measured with a different version
# of this script than this batch runs. The artifact under measurement here is
# the verifier prompt inside this file, so a reworded prompt is exactly the
# mismatch worth refusing. A MISSING sha is never a signal: every row written
# before the column existed has none.
provenance_guard() {
  awk -F'\t' -v label="$LABEL" -v sha="$RUN_SHA" \
             -v runner="run_verify.sh" -v f="$RESULTS" '
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
    # that this label was measured by another version of this script.
    $(idx["run"]) !~ /^[0-9]+$/ { next }
    $(idx["sha"]) == "" || $(idx["sha"]) == sha { next }
    { seen[$(idx["sha"])] = 1 }
    END {
      if (bad) exit 2
      n = 0
      for (s in seen) { n++; list = list (n > 1 ? ", " : "") s }
      if (n) {
        print runner ": " label " already carries rows from a different version of this script (" list "); this batch runs " sha "." > "/dev/stderr"
        print runner ": resuming would mix two prompt versions under one label -- use a new label, or move the old rows aside." > "/dev/stderr"
        exit 2
      }
    }
  ' "$RESULTS"
}

provenance_guard || exit 2

scan_recorded label item run
# Walked over the same key space the item loop below does -- the same glob, so
# the report cannot drift from what is actually dispatched.
_want=0; _have=0
for run in $(seq 1 "$RUNS"); do
  for dir in "$EVAL_DIR"/verify/items/*/; do
    _want=$((_want + 1))
    if recorded "$LABEL" "$(basename "$dir")" "$run"; then _have=$((_have + 1)); fi
  done
done
echo "run_verify.sh: $LABEL: $_have of $_want already recorded, dispatching $((_want - _have))" >&2
if [ "$RECORDED_N" -gt "$_want" ]; then
  echo "run_verify.sh: $LABEL: $RECORDED_N row(s) already recorded, more than the $_want requested -- RUNS never deletes rows." >&2
fi

for run in $(seq 1 "$RUNS"); do
  for dir in "$EVAL_DIR"/verify/items/*/; do
    # FIRST in the body, before the probe and before the fixture is applied: a
    # key already on disk costs this batch nothing, and probing for a key nobody
    # will dispatch could abort a complete arm on a server it never needed.
    if recorded "$LABEL" "$(basename "$dir")" "$run"; then continue; fi

    # Before the fixture is applied, before a log exists, before anything is
    # dispatched: an attempt refused here must leave no artifact that could be
    # mistaken for a run, and no per-item row at all.
    probe_server || abort_infra SERVER-DOWN

    item="$(basename "$dir")"
    fixture=""; truth=""; gating=""
    while IFS='=' read -r k v; do
      case "$k" in fixture) fixture="$v";; truth) truth="$v";; gating) gating="$v";; esac
    done < "$dir/meta"

    git -C "$REPO" checkout -q -- .
    git -C "$REPO" apply "$EVAL_DIR/cases/$fixture/case.patch"

    PROMPT="An automated reviewer of the uncommitted changes in this repository reported the finding below. Adversarially check it against the actual files.
HARD BUDGET: at most 3 rounds of tool calls, then give your verdict.
$(cat "$dir/finding.txt")"

    log="$EVAL_DIR/logs/$LABEL-$item-r$run.txt"
    t0=$(date +%s)
    ( cd "$REPO" && pi --provider "$PROVIDER" --model "$MODEL" \
        --no-session -nc -ns --exclude-tools edit,write \
        --system-prompt "$SYSTEM_PROMPT" --mode json -p "$PROMPT" </dev/null ) \
      > "$log.raw" 2> "$log.err" &
    wpid=$!
    # Watchdog, mirrored from run_eval.sh:67-94. Without it a wedged pi hangs
    # the whole batch; without the rc below, a dead server was recorded as the
    # verifier disagreeing with ground truth.
    ( sleep "$TIMEOUT"
      # Marker first: rc=124 keys on the watchdog FIRING, not on wall clock --
      # date +%s advances across a suspend while sleep does not, so elapsed
      # seconds alone would rewrite a genuine verdict into a timeout after any
      # lid-close.
      : > "$log.timeout"
      # TERM the deepest descendant first: pi is a node script (process name
      # "node", never "pi"), so the generation process itself must die before
      # the wrapper is signalled. Never a machine-wide pkill, and never a KILL.
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

    # Last assistant text block only -- tool results also arrive as message_end.
    python3 - "$log.raw" <<'PY' > "$log"
import json, sys
txt = ""
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    m = e.get("message") or {}
    if e.get("type") == "message_end" and m.get("role") == "assistant":
        if m.get("stopReason") != "stop" or m.get("isError"):
            continue
        t = "".join(c.get("text", "") for c in m.get("content", []) if c.get("type") == "text")
        if t.strip(): txt = t
print(txt)
PY
    # Retention-safe reduction, matching review.sh: any "real" line wins (the
    # prompt's format reminder ends with "VERDICT: refuted", so an echoed
    # template must not read as a refutation). No sed alternation (BSD sed).
    verdicts=$(sed -n 's/^VERDICT:[[:space:]]*//p' "$log" | tr -d ' \t' | tr '[:upper:]' '[:lower:]' || true)
    if printf '%s\n' "$verdicts" | grep -qx real; then verdict=real
    elif printf '%s\n' "$verdicts" | grep -qx refuted; then verdict=refuted
    else verdict=none; fi
    agree=0; [ "$verdict" = "$truth" ] && agree=1
    # Classified from the rc and the EXTRACTED answer, never from the raw
    # stream: a stream with events in it but no finished assistant message is
    # not an answer.
    status=$(classify_run "$rc" "$log")
    # A marked row is not a measurement, so the scored cell is left empty rather
    # than 0. agree=0 reads as the verifier disagreeing with ground truth, which
    # turns a missing answer into a wrong one -- the exact misreading this whole
    # phase exists to remove. `verdict` is left as extracted: it is a raw
    # observation, and `none` beside a non-empty status is unambiguous.
    if [ -n "$status" ]; then agree=""; fi
    # Per row, never hoisted: 13 items x N runs is a long batch.
    rowdate=$(date +%F)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$LABEL" "$item" "$run" "$verdict" "$truth" "$gating" "$secs" "$agree" \
      "$status" "$rowdate" "$RUN_SHA" | tee -a "$RESULTS"
  done
done
git -C "$REPO" checkout -q -- .
