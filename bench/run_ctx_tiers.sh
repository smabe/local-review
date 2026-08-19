#!/usr/bin/env bash
# run_ctx_tiers.sh CTX RUNS LABEL — one context-tier arm, end to end.
#
# A tier is TWO knobs that must agree: llama-server's --ctx-size (LLAMA_CTX) and
# pi's contextWindow in ~/.pi/agent/models.json. Raising only the first leaves
# the extra room unused; raising only the second lets pi overrun the server.
# This script sets both, serves the model, runs the small-case bench and the
# bigdiff fixture against it, samples wired memory throughout, and restores
# models.json on the way out.
#
# Restoration is in an EXIT trap because an abandoned arm that left
# contextWindow at 98304 would silently mis-serve every later review.
set -uo pipefail

CTX="${1:?context size required}"
RUNS="${2:-2}"
LABEL="${3:?label required}"

# A tier arm measures the DEFAULT configuration. run_eval.sh/run_bigdiff.sh
# honor several env knobs, and any stray export left over from a variant arm
# or a debugging session would silently change what a ctx-labeled arm ran —
# a mislabel the served-context assertion below cannot see. Drop all of them.
# (LOCAL_REVIEW_ARM_SUITES deliberately survives: it is read by THIS script,
# visible in its output, and exists for resuming a half-completed arm.)
unset LOCAL_REVIEW_EVAL_CASES LOCAL_REVIEW_EVAL_ARGS \
      LOCAL_REVIEW_SH LOCAL_REVIEW_EVAL_TIMEOUT LOCAL_REVIEW_BIGDIFF_TIMEOUT

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$EVAL_DIR/.." && pwd)"
MODELS_JSON="$HOME/.pi/agent/models.json"
MODEL_ID="qwen38-gguf-nothink"
BACKUP="$EVAL_DIR/logs/$LABEL-models.json.bak"
MEMLOG="$EVAL_DIR/logs/$LABEL-wired.txt"
SERVERLOG="$EVAL_DIR/logs/$LABEL-server.txt"

mkdir -p "$EVAL_DIR/logs"

review_sha() {
  # shasum is perl (macOS yes, minimal Linux no); sha256sum is coreutils (the
  # reverse). Try both, take the first that yields a hash. See run_eval.sh.
  if [ ! -r "$1" ]; then
    echo "run_ctx_tiers.sh: cannot read $1 -- no script to review" >&2
    return 1
  fi
  _sha=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
  if [ -z "$_sha" ]; then _sha=$(sha256sum "$1" 2>/dev/null | awk '{print $1}'); fi
  if [ -z "$_sha" ]; then
    echo "run_ctx_tiers.sh: no working shasum or sha256sum -- refusing an arm whose script version cannot be recorded" >&2
    return 1
  fi
  printf '%s' "${_sha:0:12}"
}
# The arm's snapshot, keyed on the label like $BACKUP / $MEMLOG / $SERVERLOG
# above. Taken below, once every gate has passed.
SNAPSHOT="$EVAL_DIR/logs/$LABEL-review.sh"

SERVER_PID=""
SAMPLER_PID=""
cleanup() {
  if [ -n "$SAMPLER_PID" ]; then kill "$SAMPLER_PID" 2>/dev/null; fi
  if [ -n "$SERVER_PID" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null
    # llama-server frees ~25 GB of Metal buffers on the way down; the next arm
    # allocates more than this one, so wait for the teardown to actually finish.
    for _ in $(seq 1 60); do
      if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
      sleep 1
    done
    kill -KILL "$SERVER_PID" 2>/dev/null
  fi
  # Restore, then retire the backup: a consumed backup must not linger, or the
  # no-clobber guard below would pin THIS arm's snapshot over a future run
  # whose baseline the operator has legitimately changed since.
  if [ -f "$BACKUP" ]; then cp "$BACKUP" "$MODELS_JSON" && rm -f "$BACKUP"; fi
  return 0
}
trap cleanup EXIT

# No-clobber: after a hard death (SIGKILL, panic) models.json is left mutated
# and the EXIT trap never ran. Re-running the same label must NOT capture that
# mutated file as "original" — the old backup is the good copy, and
# overwriting it would make the wrong contextWindow permanent and invisible
# (the served-context assertion checks the server, never pi's side).
if [ -f "$BACKUP" ]; then
  echo "run_ctx_tiers.sh: keeping existing backup $BACKUP (prior arm did not restore cleanly?)" >&2
else
  cp "$MODELS_JSON" "$BACKUP"
fi

python3 - "$MODELS_JSON" "$MODEL_ID" "$CTX" <<'PY'
import json, sys
path, model_id, ctx = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = json.load(open(path))
hits = 0
for prov in cfg["providers"].values():
    for m in prov.get("models", []):
        if m["id"] == model_id:
            m["contextWindow"] = ctx
            hits += 1
if hits != 1:
    sys.exit(f"expected exactly one {model_id} entry, found {hits}")
json.dump(cfg, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(f"models.json: {model_id} contextWindow -> {ctx}")
PY
[ $? -eq 0 ] || exit 1

echo "=== arm $LABEL: serving at ctx $CTX ==="
LLAMA_CTX="$CTX" bash "$REPO_ROOT/scripts/llama_server.sh" > "$SERVERLOG" 2>&1 &
SERVER_PID=$!

# Sample wired memory every 15 s for the whole arm; the peak is what a 48 GB
# machine has to survive, and it is only observable while the arm is running.
( while :; do
    printf '%s\t%s\n' "$(date +%s)" \
      "$(vm_stat | awk '/Pages wired down/ {gsub(/\./,"",$4); print $4 * 16384}')"
    sleep 15
  done ) > "$MEMLOG" 2>/dev/null &
SAMPLER_PID=$!

# Wait for the API, not the process: a model that is still mmap-ing answers
# nothing, and a review fired at that window fails as a bare connection error.
#
# Liveness is checked BEFORE reachability, because port 8080 answering does not
# mean THIS server answered it. llama-server exits immediately when the port is
# already bound, so a foreign server -- one the operator started, or the
# previous arm's still finishing its teardown -- satisfies a bare curl probe
# while this arm's server is already dead. The arm would then run to completion
# and append a full set of rows labeled with a context size it never served.
ready=0
for _ in $(seq 1 240); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "llama-server died during load at ctx $CTX (is something else on port 8080?); see $SERVERLOG" >&2
    tail -20 "$SERVERLOG" >&2
    exit 1
  fi
  if curl -s -m 3 http://localhost:8080/v1/models >/dev/null 2>&1; then ready=1; break; fi
  sleep 5
done
if [ "$ready" -ne 1 ]; then
  echo "llama-server never became reachable at ctx $CTX; see $SERVERLOG" >&2
  exit 1
fi

# Assert what was actually served rather than trusting that the flag took. This
# is the check that makes a mislabeled arm impossible: the whole experiment is a
# comparison BETWEEN context sizes, so a row labeled with a size it was not
# measured at is worse than no row at all.
served=$(grep -o 'n_ctx_slot[ ]*=[ ]*[0-9]*' "$SERVERLOG" | head -1 | grep -o '[0-9]*$')
if [ -z "$served" ]; then
  echo "could not confirm served context from $SERVERLOG; refusing to label rows as ctx $CTX" >&2
  exit 1
fi
if [ "$served" -ne "$CTX" ]; then
  echo "served context is $served, not the requested $CTX; refusing to run arm $LABEL" >&2
  exit 1
fi
echo "=== arm $LABEL: server ready, serving n_ctx_slot=$served ==="

# ONE snapshot, pinned across BOTH suites below. Letting each suite take its own
# would reproduce, inside a single label, exactly the cross-session
# misattribution this workstream exists to remove: one arm reporting two
# different measured scripts. Exported AFTER the unset at the top of the file --
# that unset is deliberate and stays; this is the one override an arm sets for
# itself.
#
# Taken HERE, after every gate above (models.json rewrite, server liveness,
# reachability, served-context assertion), so an arm that refuses to run leaves
# no copy behind: a snapshot on disk asserts that suites were dispatched.
#
# Reused, loudly, when it already exists. LOCAL_REVIEW_ARM_SUITES exists to
# finish a half-completed arm in a second invocation, and a fresh snapshot there
# would let one label's eval rows and bigdiff rows measure two different scripts
# -- the very failure this block prevents, surviving in the one workflow built
# for resuming. This is why the name is label-keyed rather than random: within an
# arm, reuse is the point. Re-running a COMPLETED arm under the same label
# already double-counts its rows, so it is out of bounds for other reasons.
if [ -f "$SNAPSHOT" ]; then
  echo "run_ctx_tiers.sh: reusing the existing snapshot $SNAPSHOT for arm $LABEL" >&2
  echo "run_ctx_tiers.sh: (resuming an arm measures the script it started with, not today's)" >&2
  SNAPSHOT_OWNED=0
else
  SNAPSHOT_OWNED=1
  cp "$REPO_ROOT/scripts/review.sh" "$SNAPSHOT" \
    || { echo "run_ctx_tiers.sh: could not copy review.sh to $SNAPSHOT" >&2; rm -f "$SNAPSHOT"; exit 1; }
fi
# Checksummed from the COPY, so the reported version is the executed bytes.
# A refusal here removes the copy only if THIS invocation made it -- the same
# rule the model lock follows (never reclaim what you did not create). Deleting
# a reused snapshot would orphan the transcripts an earlier invocation wrote,
# and leaving an unreused one would let the resume branch above adopt an arm
# that never dispatched anything.
ARM_SHA=$(review_sha "$SNAPSHOT") \
  || { if [ "$SNAPSHOT_OWNED" -eq 1 ]; then rm -f "$SNAPSHOT"; fi; exit 1; }
LOCAL_REVIEW_SH="$SNAPSHOT"
export LOCAL_REVIEW_SH
# KEPT deliberately -- cleanup() must not delete it. Every .err this arm writes
# names this path, so removing it on the way out orphans the transcripts.
echo "=== arm $LABEL: snapshot $SNAPSHOT (sha256 $ARM_SHA) ==="

# Which suites this arm runs. Defaults to both; exists so an arm interrupted
# partway can be completed without re-running the half that already produced
# valid rows (duplicate rows under one label would silently double its counts).
SUITES="${LOCAL_REVIEW_ARM_SUITES:-eval bigdiff}"
# A suite that fails closed (e.g. run_eval.sh's unknown-case exit 2) must not
# end in a clean "done" banner over an arm that produced no rows.
arm_rc=0
case " $SUITES " in *" eval "*)
  bash "$EVAL_DIR/run_eval.sh"    llamaserver "$MODEL_ID" "$RUNS" "$LABEL" || arm_rc=$? ;;
esac
case " $SUITES " in *" bigdiff "*)
  bash "$EVAL_DIR/run_bigdiff.sh" llamaserver "$MODEL_ID" "$RUNS" "$LABEL" || arm_rc=$? ;;
esac

peak=$(awk -F'\t' 'NF==2 && $2+0 > m {m = $2+0} END {printf "%.1f", m/1073741824}' "$MEMLOG")
if [ "$arm_rc" -ne 0 ]; then
  echo "=== arm $LABEL FAILED (a suite exited $arm_rc): peak wired ${peak} GB ===" >&2
  exit "$arm_rc"
fi
echo "=== arm $LABEL done: peak wired ${peak} GB ==="
