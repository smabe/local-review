#!/usr/bin/env bash
# local-review — run an advisory code review of the working tree on a local
# model via the pi harness. Advisory only: it does not replace a real review.
#
#   ./review.sh
#   ./review.sh --intent "Cache the parsed manifest so repeated loads skip disk."
#   ./review.sh --rounds 5 --json
#   ./review.sh --provider llamaserver --model local-reviewer
#
# With LM Studio it manages the model's lifecycle: loads it if it isn't
# resident, and unloads it afterwards -- but only if this run is what loaded
# it. A model you loaded yourself is left exactly as it was found.
#
set -euo pipefail

PROVIDER="lmstudio"
MODEL="qwen/qwen3-coder-30b"
CONTEXT_LENGTH=49152
ROUNDS=3
INTENT=""
RAW_STREAM=0
RAW=""
DIFF_TRUNCATION_BYTES=50000
LOADED_BY_US=0
LLAMA_URL="http://localhost:8080/v1/models"

# `lms` is on PATH for some installs and only under ~/.lmstudio for others.
LMS="$(command -v lms 2>/dev/null || true)"
[ -n "$LMS" ] || LMS="$HOME/.lmstudio/bin/lms"

die() { printf 'local-review: %s\n' "$1" >&2; exit 1; }
note() { printf 'local-review: %s\n' "$1" >&2; }

usage() {
  cat >&2 <<'USAGE'
usage: review.sh [--intent SENTENCE] [--rounds N] [--json]
                 [--provider NAME] [--model ID]

  --intent SENTENCE  Judge changes against this stated intent. One sentence,
                     about the change only. The reviewer treats anything
                     implementing it as correct by definition, so a wrong
                     sentence hides real bugs -- read SKILL.md before using.
  --rounds N         Tool-call budget (default 3). Raise to 4-5 when the
                     review needs a codebase search pass. The cap is a
                     stability guard, not a speed knob.
  --json             Print pi's raw JSON event stream instead of the review.
                     Every run is audited either way; this shows the evidence.
  --provider NAME    pi provider: lmstudio (default) or llamaserver.
  --model ID         Model id as named in ~/.pi/agent/models.json.

Exit status: 0 clean, 1 error, 2 usage, 3 the verdict cannot be trusted (the
model read nothing, said nothing, or produced output that is neither a clean
verdict nor well-formed findings), 4 defects were reported. Only 0 means
clean -- never read a 3 or a 4 that way.
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --intent)   [ $# -ge 2 ] || usage; INTENT="$2"; shift 2 ;;
    --rounds)   [ $# -ge 2 ] || usage; ROUNDS="$2"; shift 2 ;;
    --provider) [ $# -ge 2 ] || usage; PROVIDER="$2"; shift 2 ;;
    --model)    [ $# -ge 2 ] || usage; MODEL="$2"; shift 2 ;;
    --json)     RAW_STREAM=1; shift ;;
    -h|--help)  usage ;;
    *)          printf 'local-review: unknown argument: %s\n\n' "$1" >&2; usage ;;
  esac
done

case "$ROUNDS" in
  ''|*[!0-9]*) die "--rounds needs a whole number, got '$ROUNDS'" ;;
esac
[ "$ROUNDS" -ge 1 ] || die "--rounds must be at least 1"

# --- preconditions -----------------------------------------------------------

command -v pi >/dev/null 2>&1 || die "pi is not on PATH -- see the README"
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH (needed to audit the run)"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not inside a git repository -- cd to the repo first"

if [ "$PROVIDER" = "lmstudio" ]; then
  [ -x "$LMS" ] || die "lms CLI not found (looked on PATH and at \$HOME/.lmstudio/bin/lms)"

  # Match on output text, not exit status: the strings on the success path are
  # known, the failure-path exit codes are not.
  if ! "$LMS" server status 2>&1 | grep -qi 'running on port'; then
    die "LM Studio server is down on :1234 -- run: $LMS server start
     (after a reboot the model can be loadable while the server is not up;
      pi reports this only as a bare 'Connection error')"
  fi
else
  # llama-server has no CLI to interrogate; ask the endpoint itself.
  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 5 "$LLAMA_URL" >/dev/null 2>&1 \
      || die "no server answering at $LLAMA_URL -- start scripts/llama_server.sh first"
  fi
fi

# --- is there anything to review? --------------------------------------------
# Before loading anything: a clean tree should not cost a model load.

if git rev-parse --verify HEAD >/dev/null 2>&1; then
  DIFF_CMD="git diff HEAD"
  DIFF_BYTES=$(git diff HEAD | wc -c | tr -d ' ')
else
  DIFF_CMD="git diff --cached"   # the prompt must not name a HEAD that is unborn
  # No commits yet: there is no HEAD to diff against, but staged files are
  # already tracked, so `git ls-files --others` will not see them either.
  DIFF_BYTES=$(git diff --cached | wc -c | tr -d ' ')
fi
UNTRACKED_COUNT=$(git ls-files --others --exclude-standard | grep -c . || true)

if [ "$DIFF_BYTES" -eq 0 ] && [ "$UNTRACKED_COUNT" -eq 0 ]; then
  echo "Nothing to review: no uncommitted changes and no untracked files."
  exit 0
fi

# --- model lifecycle ---------------------------------------------------------
# Unload runs from an EXIT trap so it still happens on a failed review or a
# Ctrl-C. It is a no-op unless this run is what loaded the model. llama-server
# owns its own model for the life of the process, so this applies to LM Studio
# only.

# One model, one review at a time. Reference counting cannot express who owns
# the unload -- the loader may exit first, leaving nobody able to unload -- so
# the whole load -> review -> unload lifecycle runs under a mutex instead. An
# atomic mkdir is the primitive. The lock lives under the user's own cache
# directory, never a world-writable one: a predictable name in shared /tmp is a
# symlink attack on a multi-user host.
LOCK=""
acquire_lock() {
  local dir lock owner
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/local-review"
  mkdir -p "$dir" 2>/dev/null || die "cannot create $dir"
  lock="$dir/model.lock"
  # `mkdir` is the entire protocol: it succeeds for exactly one process and
  # fails for every other. Nothing reclaims a lock it did not create -- a
  # stale-lock check would have to read the owner AFTER creating the directory,
  # and two contenders reading that gap can both decide to steal it. The EXIT
  # trap covers normal exits, Ctrl-C and SIGTERM, so a leftover lock means a
  # SIGKILL or a power cut, and clearing that is a deliberate human act.
  if ! mkdir "$lock" 2>/dev/null; then
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      die "another local review (pid $owner) holds the model -- wait for it to finish"
    fi
    die "a local review lock is present but its owner is gone.
     If no review is running: rm -rf \"$lock\""
  fi
  printf '%s\n' "$$" > "$lock/pid"
  LOCK="$lock"
}

cleanup() {
  [ -n "$RAW" ] && rm -f "$RAW"
  if [ "$LOADED_BY_US" -eq 1 ]; then
    note "unloading $MODEL"
    "$LMS" unload "$MODEL" >/dev/null 2>&1 || note "unload failed -- '$LMS ps' to check"
  fi
  [ -n "$LOCK" ] && rm -rf "$LOCK"   # released last: the unload is part of what it guards
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$PROVIDER" = "lmstudio" ]; then
  acquire_lock
  if "$LMS" ps 2>/dev/null | grep -qF "$MODEL"; then
    note "$MODEL already loaded -- leaving it resident afterwards"
  else
    # Any resident model has to go first: the memory guardrail sizes the new
    # instance on top of the live one, so loading over it fails outright. Run
    # unconditionally -- it is a no-op when nothing is loaded, and that is
    # cheaper than parsing `lms ps` to find out.
    note "clearing resident models to make room"
    "$LMS" unload --all >/dev/null 2>&1 || true

    note "loading $MODEL at ${CONTEXT_LENGTH} context (takes a moment)"
    # --parallel 1: the default of 4 multiplies the KV allocation.
    "$LMS" load "$MODEL" --yes --context-length "$CONTEXT_LENGTH" --parallel 1 >/dev/null \
      || die "failed to load $MODEL -- '$LMS load \"$MODEL\" --yes' by hand for the real error"
    LOADED_BY_US=1
  fi
fi

# --- prompt ------------------------------------------------------------------

# The reviewer persona replaces pi's default coding-assistant system prompt.
# Measured against the prompt-only setup, 3 runs per arm, on a fixture with one
# planted off-by-one and one deliberate-looking-inconsistency trap: both caught
# the real bug 3/3, but the old setup bit the trap 2/3 and invented 0-3 defects
# per run on a docs-only diff, where this one reported nothing 3/3. Rules 1 and
# 2 are what kill the fabrications -- do not drop them.
SYSTEM_PROMPT='You are a code reviewer. You do not write, fix, or explain code, and you do not summarize changes.
Your entire output is either a list of defects or the exact string "No findings." — never both.
Rules you must obey:
1. Report a defect ONLY if you can quote the exact offending line verbatim from a file you have actually read this session. If you cannot quote the line, the defect does not exist and you must not report it.
2. Defects live in code and in configuration that affects behaviour (CI files, manifests, build and runtime settings). Never report that documentation, comments, prose, or a README "should" say or enforce something.
3. Confirming that a change does what it intended is NOT review. Never produce a checklist of what the change accomplishes.
4. A difference between two independent components is not a defect unless you can show one calls the other.
5. If you are unsure, omit it. A missed bug costs less than a false one.'

if [ -n "$INTENT" ]; then
  OPENING="Review the uncommitted changes in this repository for correctness bugs, judging every change AGAINST THIS INTENT: ${INTENT} A change that implements the stated intent is correct by definition; do not report it. Report only defects that contradict the intent or are unrelated to it."
else
  OPENING="Review the uncommitted changes in this repository for correctness bugs."
fi

PROMPT="${OPENING}
HARD BUDGET: at most ${ROUNDS} rounds of tool calls, then give your verdict — batch commands (round 1: git status --short && ${DIFF_CMD}; round 2: read the changed files).
Untracked files do not appear in ${DIFF_CMD}: enumerate them with git ls-files --others --exclude-standard and read them directly. Do not run git add.
Report each defect in exactly this form, most severe first:
FILE:LINE | confidence: high|medium|low
QUOTE: <the offending line, copied verbatim>
DEFECT: <what is wrong with that line>
FAILURE: <concrete input or state that produces wrong behaviour>
If and only if there are no defects, output exactly: No findings."

if [ "$DIFF_BYTES" -gt "$DIFF_TRUNCATION_BYTES" ]; then
  PROMPT="${PROMPT}
This diff is large (${DIFF_BYTES} bytes) and your git diff output will be truncated before you see all of it. Read the changed files directly instead of relying on the diff text."
fi

# --- run ---------------------------------------------------------------------
# Not exec'd: the process has to survive to run the unload trap.
# --exclude-tools drops the mutation tools, but pi has NO OS-enforced sandbox
# and its bash tool can still write. For enforced read-only, use a harness that
# provides one (e.g. codex exec --sandbox read-only).

run_pi() {
  pi --provider "$PROVIDER" --model "$MODEL" \
    --no-session -nc -ns --exclude-tools edit,write \
    --system-prompt "$SYSTEM_PROMPT" --mode json \
    -p "$PROMPT" </dev/null
}

RAW=$(mktemp -t local-review) || die "could not create a temp file"
RC=0
run_pi >"$RAW" || RC=$?

# --json hands back the raw evidence, but still gets audited: a zero-tool-call
# run is exactly what someone reaches for --json to detect.
[ "$RAW_STREAM" -eq 1 ] && cat "$RAW"

# Audit the run rather than trusting its prose. Three measured failure modes:
# appending "No findings." underneath real findings, returning empty output,
# and abandoning the required format.
python3 - "$RAW" "$RAW_STREAM" <<'PY' || AUDIT=$?
import json, re, sys

texts, tools, peak = [], 0, 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    kind = ev.get("type")
    if kind == "tool_execution_start":
        tools += 1
    elif kind == "message_end":
        msg = ev.get("message", {}) or {}
        usage = msg.get("usage") or {}
        if isinstance(usage, dict):
            peak = max(peak, usage.get("totalTokens") or 0)
        for block in msg.get("content", []) or []:
            if block.get("type") == "text" and block.get("text", "").strip():
                texts.append(block["text"].strip())

raw_mode = len(sys.argv) > 2 and sys.argv[2] == "1"
review = texts[-1] if texts else ""

# A finding is only counted when the whole block is present. Counting DEFECT:
# alone accepted truncated findings; requiring every label and equal counts
# means a half-emitted block reads as malformed rather than as a defect.
counts = {label: len(re.findall(r"^%s:" % label, review, re.M))
          for label in ("FILE", "QUOTE", "DEFECT", "FAILURE")}
# A finding is the four labels in order, each carrying a non-empty value.
# Counting labels alone accepted them shuffled, or present but empty.
# The FILE value must look like a path -- one whitespace-free token containing
# a dot, slash or colon (metrics.py:15, src/a.go, Makefile:12). That rejects a
# header like "FILE: I could not determine the file" without rejecting the
# three header shapes this model actually emits.
BLOCK = re.compile(
    r"^FILE:[ \t]*[^\s|]*[./:][^\s|]*.*\n(?:.*\n)*?"
    r"^QUOTE:[ \t]*\S.*\n(?:.*\n)*?"
    r"^DEFECT:[ \t]*\S.*\n(?:.*\n)*?"
    r"^FAILURE:[ \t]*\S",
    re.M)
blocks = len(BLOCK.findall(review + "\n"))
well_formed = blocks > 0 and all(v == blocks for v in counts.values())
defects = blocks if well_formed else 0

# The clean verdict is the WHOLE output, not a phrase inside it: "No findings.
# I checked the files but could not open two of them" is not a clean review.
clean_verdict = review.strip().rstrip(".").strip().lower() == "no findings"
mentions_clean = re.search(r"\bno findings\b", review, re.I) is not None

if review and not raw_mode:   # raw mode already emitted the stream
    print(review)
sys.stdout.flush()   # keep the footer below the review when stdout is a pipe

warn = lambda m: sys.stderr.write("local-review: %s\n" % m)
warn("audit: %d tool call(s), %d defect(s), %d tokens peak" % (tools, defects, peak))

if tools == 0:
    warn("THIS REVIEW DID NOT HAPPEN -- the model answered without reading")
    warn("anything. Do not treat it as clean. Re-run, and check the server.")
    sys.exit(3)
if not review:
    warn("empty response after %d tool call(s) -- no verdict was given." % tools)
    sys.exit(3)
if defects:
    if mentions_clean:
        warn('the model appended "No findings." beneath %d real finding(s).' % defects)
        warn("The findings stand; the sentinel is a known tic of this model.")
    sys.exit(4)
if not clean_verdict:
    if any(counts.values()):
        warn("findings are incomplete -- got %s, and every finding needs all four."
             % ", ".join("%s x%d" % (k, v) for k, v in counts.items()))
    else:
        warn("output is neither a clean verdict nor well-formed findings --")
        warn("read it yourself, nothing here could be validated.")
    sys.exit(3)
PY
AUDIT=${AUDIT:-0}

# The audit's verdict outranks pi's exit code: pi exits 0 both for a run that
# returned nothing at all and for one that found real defects.
[ "$AUDIT" -ne 0 ] && exit "$AUDIT"
exit "$RC"
