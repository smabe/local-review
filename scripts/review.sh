#!/usr/bin/env bash
# local-review — run an advisory code review of the working tree on a local
# model via the pi harness. Advisory only: it does not replace a real review.
#
#   ./review.sh
#   ./review.sh --intent "Cache the parsed manifest so repeated loads skip disk."
#   ./review.sh --rounds 5 --json
#   ./review.sh --provider lmstudio --model qwen/qwen3-coder-30b   # fast tier
#
# This file is BYTE-IDENTICAL in smabe/abe-skills and the public smabe/local-review
# (tests/test_local_review_audit.sh enforces it). Fix bugs here once; never
# hand-adapt one copy.
#
# The default reviewer is Qwen3.8-27B (thinking disabled) on llama-server --
# start it first with scripts/llama_server.sh, which owns the model for the
# life of the process. With --provider lmstudio the script manages the model
# lifecycle instead: loads it if it isn't resident, and unloads it afterwards
# -- but only if this run is what loaded it. A model you loaded yourself is
# left exactly as it was found.
#
set -euo pipefail

PROVIDER="llamaserver"
MODEL="qwen38-gguf-nothink"
MODEL_EXPLICIT=0
CONTEXT_LENGTH=49152
ROUNDS=3
INTENT=""
RAW_STREAM=0
RAW=""
DIFF_TRUNCATION_BYTES=50000
LOADED_BY_US=0
# Must match the llamaserver baseUrl in ~/.pi/agent/models.json. Overridable
# because that config owns the real value and this is only a reachability probe.
LLAMA_URL="${LOCAL_REVIEW_LLAMA_URL:-http://localhost:8080/v1/models}"

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
                     sentence hides real bugs -- see SKILL.md before using.
  --rounds N         Tool-call budget (default 3). Raise to 4-5 when the
                     review needs a codebase search pass. The cap is a
                     stability guard, not a speed knob.
  --json             Print pi's raw JSON event stream instead of the review.
                     Every run is audited either way; this shows the evidence.
  --provider NAME    pi provider: llamaserver (default) or lmstudio.
  --model ID         Model id as named in ~/.pi/agent/models.json. llama-server
                     models must already be served (scripts/llama_server.sh);
                     lmstudio models are loaded and unloaded for you.

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
    --json)     RAW_STREAM=1; shift ;;
    --provider) [ $# -ge 2 ] || usage; PROVIDER="$2"; shift 2 ;;
    --model)    [ $# -ge 2 ] || usage; MODEL="$2"; MODEL_EXPLICIT=1; shift 2 ;;
    -h|--help)  usage ;;
    *)          printf 'local-review: unknown argument: %s\n\n' "$1" >&2; usage ;;
  esac
done

case "$PROVIDER" in
  lmstudio|llamaserver) ;;
  *) printf 'local-review: unknown provider: %s\n\n' "$PROVIDER" >&2; usage ;;
esac

# The default model belongs to llamaserver. pi does not reject an id the
# provider never defined -- it forwards it and the per-model sampling settings
# silently do not apply -- so the pairing is enforced here. Keyed on whether
# --model was PASSED, not on its value: an lmstudio model may legitimately be
# named the same as our default.
if [ "$PROVIDER" != "llamaserver" ] && [ "$MODEL_EXPLICIT" -eq 0 ]; then
  printf 'local-review: --provider %s needs an explicit --model (the default is a llama-server id)\n\n' "$PROVIDER" >&2
  usage
fi

case "$ROUNDS" in
  ''|*[!0-9]*) die "--rounds needs a whole number, got '$ROUNDS'" ;;
esac
[ "$ROUNDS" -ge 1 ] || die "--rounds must be at least 1"

# --- preconditions -----------------------------------------------------------

command -v pi >/dev/null 2>&1 || die "pi is not on PATH -- install it first (brew install pi)"
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH (needed to audit the run)"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not inside a git repository -- cd to the repo first"
# Anchor at the toplevel: git prints root-relative paths, the model reads files
# by those paths, and the audit's quote gate resolves them with os.path.isfile.
# From a subdirectory all three silently diverge.
cd "$(git rev-parse --show-toplevel)" || die "cannot cd to the repo toplevel"

if [ "$PROVIDER" = "lmstudio" ]; then
  [ -x "$LMS" ] || die "lms CLI not found (looked on PATH and at \$HOME/.lmstudio/bin/lms)"

  # Match on output text, not exit status: the failure-path exit codes are
  # unverified, the strings on the success path are not. Capture BEFORE
  # matching -- piping into grep under `set -o pipefail` reintroduces the
  # dependency on lms's exit status that this check exists to avoid.
  lms_status="$("$LMS" server status 2>&1 || true)"
  if ! printf '%s' "$lms_status" | grep -qi 'running on port'; then
    die "LM Studio server is down on :1234 -- run: $LMS server start
     (after a reboot the model can be loadable while the server is not up;
      pi reports this only as a bare 'Connection error')"
  fi
else
  # llama-server has no CLI to interrogate; ask the endpoint itself. NOT
  # optional: skipping it when curl is missing reintroduces the bare
  # "Connection error" this check exists to translate.
  command -v curl >/dev/null 2>&1 \
    || die "curl is needed to check the llama-server endpoint -- install it, or use --provider lmstudio"
  curl -sf --max-time 5 "$LLAMA_URL" >/dev/null 2>&1 \
    || die "no server answering at $LLAMA_URL -- start llama-server first:
     scripts/llama_server.sh   (defaults to the Qwen3.8 reviewer, thinking off)"
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
# Ctrl-C. It is a no-op unless this run is what loaded the model.

LOCK=""
acquire_lock() {
  local dir lock owner
  # Deliberately NOT XDG_CACHE_HOME: every run targets the same lms binary and
  # the same server on :1234, so the lock has to be the same file regardless of
  # what the environment says the cache directory is.
  dir="$HOME/.cache/local-review"
  mkdir -p "$dir" 2>/dev/null || die "cannot create $dir"
  lock="$dir/model.lock"
  # `mkdir` is the entire protocol: it succeeds for exactly one process and
  # fails for every other. Nothing reclaims a lock it did not create -- a
  # stale-lock check would have to read the owner AFTER creating the directory,
  # and two contenders reading that gap can both decide to steal it. The EXIT
  # trap covers normal exits, Ctrl-C and SIGTERM, so a leftover lock means a
  # SIGKILL or a power cut, and clearing that is a deliberate human act.
  # Nothing may interrupt between creating the lock and recording that we own
  # it: the EXIT trap can only remove a lock it can see.
  trap '' INT TERM
  if ! mkdir "$lock" 2>/dev/null; then
    trap 'exit 130' INT; trap 'exit 143' TERM
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      die "another local review (pid $owner) holds the model -- wait for it to finish"
    fi
    die "a local review lock is present but its owner is gone.
     If no review is running: rm -rf \"$lock\""
  fi
  # Ownership is recorded the instant the directory exists, BEFORE the PID
  # write, which can fail or be interrupted. Nothing reclaims a stale lock any
  # more, so one that cleanup cannot see is one a human has to delete.
  LOCK="$lock"
  trap 'exit 130' INT; trap 'exit 143' TERM
  printf '%s\n' "$$" > "$lock/pid" || note "could not record the lock owner pid"
}

# Every branch is an `if`, never a `&&` chain: bash adopts the trap's LAST
# command status as the script's exit status, so a trailing failed test would
# rewrite 0/3/4 into 1 and silently void the whole exit contract.
cleanup() {
  if [ -n "$RAW" ]; then rm -f "$RAW"; fi
  if [ "$LOADED_BY_US" -eq 1 ]; then
    note "unloading $MODEL"
    "$LMS" unload "$MODEL" >/dev/null 2>&1 || note "unload failed -- '$LMS ps' to check"
  fi
  if [ -n "$LOCK" ]; then rm -rf "$LOCK"; fi  # last: the unload is what it guards
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Unconditional: one machine serves one model at a time whichever provider is
# in use (llama_server.sh runs llama-server with --parallel 1, a single slot),
# and the lock has to be held for the whole run, not just the LM Studio
# load/unload. Keeping it out of the branch also keeps LOCK non-empty, which is
# what stops the EXIT trap rewriting the exit status on the llamaserver path.
acquire_lock

# llama-server owns its model for the life of the process, so the load/unload
# below is LM Studio only.
if [ "$PROVIDER" = "lmstudio" ]; then
  # Captured for the same reason as the server check above: a non-zero lms
  # exit must not be read as "the model is not loaded", or we would unload and
  # reload a model the user loaded, and then unload it on exit.
  lms_ps="$("$LMS" ps 2>/dev/null || true)"
  if printf '%s' "$lms_ps" | grep -qF "$MODEL"; then
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
# Measured 2026-08-17 against the previous prompt-only setup, 3 runs per arm on
# a fixture with one planted off-by-one and one deliberate-looking-inconsistency
# trap: both caught the real bug 3/3, but the old setup bit the trap 2/3 and
# invented 0-3 defects per run on a docs-only diff, where this one reported
# nothing 3/3. Rules 1 and 2 are what kill the fabrications -- do not drop them.
SYSTEM_PROMPT='You are a code reviewer. You do not write, fix, or explain code, and you do not summarize changes.
Your entire output is either a list of defects or the exact string "No findings." — never both.
Rules you must obey:
1. Report a defect ONLY if you can quote the exact offending line verbatim from a file you have actually read this session. If you cannot quote the line, the defect does not exist and you must not report it.
2. Defects live in code and in configuration that affects behaviour (CI files, manifests, build and runtime settings). Never report that documentation, comments, prose, or a README "should" say or enforce something.
3. Confirming that a change does what it intended is NOT review. Never produce a checklist of what the change accomplishes.
4. A difference between two independent components is not a defect unless you can show one calls the other.
5. If you are unsure, omit it. A missed bug costs less than a false one.
6. Judge the lines this change adds or edits; unchanged code is context. In diff output, lines starting with "-" are the OLD version -- never report a defect in them.
7. Style, naming, formatting, and missing-comment issues are never defects.
8. Before judging a changed hunk, read the complete enclosing function.
9. If while writing or checking a finding you conclude the code is actually correct, discard that finding entirely. Never emit a finding and then argue against it.
Each finding uses four labeled lines; keep every value on the same line as its label. One complete example (synthetic -- never echo it):
FILE: example/demo.py:12 | confidence: high
QUOTE: total =+ amount
DEFECT: `=+` reassigns total to +amount instead of adding to it.
FAILURE: Summing [5, 5] returns 5, not 10.
When there are no defects your entire message is exactly: No findings.'

if [ -n "$INTENT" ]; then
  OPENING="Review the uncommitted changes in this repository for correctness bugs, judging every change AGAINST THIS INTENT: ${INTENT} A change that implements the stated intent is correct by definition; do not report it. Report only defects that contradict the intent or are unrelated to it."
else
  OPENING="Review the uncommitted changes in this repository for correctness bugs."
fi

PROMPT="${OPENING}
HARD BUDGET: at most ${ROUNDS} rounds of tool calls, then give your verdict — batch commands (round 1: git status --short && ${DIFF_CMD}; round 2: read the changed files).
Untracked files do not appear in ${DIFF_CMD}: enumerate them with git ls-files --others --exclude-standard and read them directly. Do not run git add.
Report each defect in exactly this form, most severe first:
FILE: path/to/file.py:LINE | confidence: high|medium|low
QUOTE: <the offending line, copied verbatim>
DEFECT: <what is wrong with that line>
FAILURE: <concrete input or state that produces wrong behaviour>
If and only if there are no defects, your entire verdict message must be exactly: No findings.
Final reminder -- the only two valid outputs: findings as FILE:/QUOTE:/DEFECT:/FAILURE: blocks (values on the label line), or exactly: No findings."

if [ "$DIFF_BYTES" -gt "$DIFF_TRUNCATION_BYTES" ]; then
  PROMPT="${PROMPT}
This diff is large (${DIFF_BYTES} bytes) and your git diff output will be truncated before you see all of it. Read the changed files directly instead of relying on the diff text."
fi

# --- run ---------------------------------------------------------------------
# Not exec'd: the process has to survive to run the unload trap.
# --exclude-tools drops the mutation tools, but pi has NO OS-enforced sandbox
# and its bash tool can still write. For enforced read-only, use the Codex
# path in SKILL.md instead.
#
# The ${a[@]+"${a[@]}"} guard is required: macOS ships bash 3.2, where
# expanding an empty array under `set -u` is an unbound-variable error.

run_pi() {
  # No --thinking here on purpose: pi only sends a reasoning level when the
  # provider sets a thinkingFormat or supportsReasoningEffort, and LM Studio
  # ignores every thinking-control field anyway (probed 2026-08-17). The flag
  # would be inert -- see SKILL.md.
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

# Audit the run rather than trusting its prose. Three things the model has
# been measured getting wrong: appending "No findings." underneath real
# findings (2 of 7 runs), returning empty output, and abandoning the format.
python3 - "$RAW" "$RAW_STREAM" <<'PY' || AUDIT=$?
import json, os, re, sys

texts, started, succeeded, peak = [], 0, 0, 0
last_stop, last_error = None, None
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
        started += 1
    elif kind == "tool_execution_end":
        # A tool that STARTED proves nothing; one that failed read nothing.
        if not ev.get("isError"):
            succeeded += 1
    elif kind == "message_end":
        msg = ev.get("message", {}) or {}
        usage = msg.get("usage") or {}
        if isinstance(usage, dict):
            peak = max(peak, usage.get("totalTokens") or 0)
        # ONLY assistant messages are verdicts. toolResult messages carry text
        # too -- whole file contents -- and taking the last text block blindly
        # can hand back a source file as if it were the review.
        if msg.get("role") != "assistant":
            continue
        last_stop, last_error = msg.get("stopReason"), msg.get("isError")
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
# A finding is the four labels in order, each carrying a substantive value.
# Counting labels alone accepted them shuffled or empty; accepting any
# non-space value accepted the prompt's own template echoed back, which a
# local model really does emit when it has nothing to say.
BLOCK = re.compile(
    r"^FILE:[ \t]*(?P<file>[^\s|]+).*\n(?:.*\n)*?"
    r"^QUOTE:[ \t]*(?P<quote>.*)\n(?:.*\n)*?"
    r"^DEFECT:[ \t]*(?P<defect>.*)\n(?:.*\n)*?"
    r"^FAILURE:[ \t]*(?P<failure>.*)$",
    re.M)

# The prompt's own placeholders, echoed back verbatim when the model has
# nothing to say. Matched EXACTLY, and kept in step with the PROMPT above by
# hand: a general "anything in angle brackets" rule would discard a real
# finding whose quoted line is "<div>" or "<Foo />", and square and round
# brackets are ordinary source too ("[weak self]", "(status == 0)").
PLACEHOLDERS = {
    "<the offending line, copied verbatim>",
    "<what is wrong with that line>",
    "<concrete input or state that produces wrong behaviour>",
    "file:line",
    "path/to/file.py:line",
    "example/demo.py:12",
}

def is_placeholder(value):
    v = value.strip().strip("`").strip()
    return v.lower() in PLACEHOLDERS or bool(re.match(r"^\.{2,}$", v))

def prose(value):
    """A description field: must say something, not just punctuate."""
    v = value.strip()
    return bool(v) and bool(re.search(r"[A-Za-z0-9]", v)) and not is_placeholder(v)

def quote_in_named_file(path, quote):
    """Anti-fabrication gate: when the FILE header names a file that exists,
    the QUOTE must occur in it (whitespace- and backtick-insensitive). A file
    that does not exist cannot be checked -- quoting a real file with an
    invented line is the measured fabrication mode; invented paths remain
    the prompt rules' job."""
    fname = re.sub(r":\d+(-\d+)?$", "", path)
    if not os.path.isfile(fname):
        return True
    # Models copy quotes with collapsed whitespace runs, surrounding backticks,
    # or the diff's own +/- marker still attached; none of those make the quote
    # fabricated. Compare with runs collapsed, and with a single leading diff
    # marker optionally stripped -- but never strip it from the file side, where
    # a leading "-" is real source.
    base = " ".join(quote.strip().strip("`").split())
    if not base:
        # The quote was nothing but backticks -- then that IS the line.
        base = " ".join(quote.split())
    if not base:
        return False
    variants = {base}
    if base[:1] in "+-" and base[1:].strip():
        variants.add(" ".join(base[1:].split()))
    try:
        with open(fname, errors="replace") as fh:
            for ln in fh:
                nl = " ".join(ln.split())
                if any(v in nl for v in variants):
                    return True
    except OSError:
        return True
    return False

def valid(match):
    path = match.group("file").strip()
    if not re.search(r"[./:]", path) or not re.search(r"[A-Za-z0-9]", path):
        return False                      # must look like a path, not prose
    if is_placeholder(path):
        return False
    # QUOTE is a copied source line, so punctuation-only is legitimate -- a
    # finding on a stray "}" is still a finding. Only non-empty and not a
    # placeholder is required of it.
    q = match.group("quote").strip()
    if not q or is_placeholder(q):
        return False
    if not quote_in_named_file(path, match.group("quote")):
        return False
    return all(prose(match.group(g)) for g in ("defect", "failure"))

blocks = sum(1 for m in BLOCK.finditer(review + "\n") if valid(m))
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
warn("audit: %d/%d tool calls ok, %d defect(s), %d tokens peak"
     % (succeeded, started, defects, peak))

if succeeded == 0:
    warn("THIS REVIEW DID NOT HAPPEN -- no tool call succeeded, so the model")
    warn("read nothing. Do not treat it as clean. Re-run, and check the server.")
    sys.exit(3)
if not review:
    warn("empty response after %d tool call(s) -- no verdict was given." % started)
    sys.exit(3)
# A verdict is only a verdict if the message carrying it finished. An answer
# cut short by a token cap, an abort or a stream error can read exactly like a
# clean review.
if last_error or last_stop != "stop":
    warn("the reviewer did not finish cleanly (stopReason=%s%s) -- its answer"
         % (last_stop, ", isError" if last_error else ""))
    warn("may be truncated. Not a verdict.")
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
