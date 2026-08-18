#!/bin/bash
# Tests for skills/local-review/scripts/review.sh — the run audit that decides
# clean vs defects vs untrustworthy, and the lock that serialises model access.
# Run: bash tests/test_local_review_audit.sh   (exit 0 = all pass)
#
# A SIBLING of the other two gate tests, same shape (pass/fail counters, one
# assert helper), for the same reason: a reader moves between them without
# relearning anything.
#
# The audit code is EXTRACTED from the shipped script rather than duplicated
# here. A copy would keep passing after the real thing drifted, which is the
# one failure a test like this must not have.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# This file is byte-identical in smabe/abe-skills and the public mirror, which
# keep review.sh at different depths. Resolve either.
SCRIPT="$ROOT/skills/local-review/scripts/review.sh"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/scripts/review.sh"
# Overridable: the default is only right on the author's machine, so an outside
# contributor or CI can point at their own checkout instead of silently skipping.
MIRROR="${LOCAL_REVIEW_MIRROR:-$HOME/projects/local-review}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
# Counted, not just printed: a check that never ran must not be indistinguishable
# from a green one in the footer the commit workflow reads.
skip() { skipped=$((skipped+1)); echo "SKIP: $1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }

# --- the audit ---------------------------------------------------------------

awk '/^python3 - "\$RAW" "\$RAW_STREAM" <<.PY./{f=1;next} f&&/^PY$/{exit} f' \
    "$SCRIPT" > "$TMP/audit.py"
[ -s "$TMP/audit.py" ] || { echo "FAIL: could not extract the audit from $SCRIPT"; exit 1; }

# Writes a pi --mode json event stream.
#   $1 tool calls  $2 assistant text  $3 stopReason (default stop)
#   $4 tool isError (default false)  $5 message isError (default false)
# Shapes match a real captured run: tool results arrive as their own
# message_end with role "toolResult" and carry text, which is why the auditor
# may only read assistant messages.
stream() {
    /usr/bin/python3 -c '
import json, sys
tools, text = int(sys.argv[1]), sys.argv[2]
stop = sys.argv[3] or None
tool_err = sys.argv[4] == "1"
msg_err = sys.argv[5] == "1"
out = []
for i in range(tools):
    out.append(json.dumps({"type": "tool_execution_start", "toolName": "bash"}))
    out.append(json.dumps({"type": "tool_execution_end", "toolName": "bash",
                           "isError": tool_err}))
    out.append(json.dumps({"type": "message_end", "message": {
        "role": "toolResult", "stopReason": None, "isError": tool_err,
        "content": [{"type": "text", "text": "DEFECT: this is tool output, not a verdict"}]}}))
msg = {"role": "assistant", "stopReason": stop, "isError": msg_err,
       "usage": {"totalTokens": 42},
       "content": ([{"type": "text", "text": text}] if text else [])}
out.append(json.dumps({"type": "message_end", "message": msg}))
print("\n".join(out))
' "$1" "$2" "${3-stop}" "${4-0}" "${5-0}" > "$TMP/events.jsonl"
}

# $1=label  $2=expected exit  $3=tool calls  $4=assistant text
#   [$5=stopReason] [$6=tool isError] [$7=message isError]
audit_is() {
    stream "$3" "$4" "${5-stop}" "${6-0}" "${7-0}"
    /usr/bin/python3 "$TMP/audit.py" "$TMP/events.jsonl" 0 >/dev/null 2>&1
    local got=$?
    [ "$got" -eq "$2" ] && ok || bad "$1 (expected exit $2, got $got)"
}

# Fixture paths live under $TMP/none -- a directory that never exists --
# so the audit's quote-vs-file gate stays exempt no matter the cwd.
FINDING="FILE: $TMP/none/metrics.py:15 | confidence: high
QUOTE: end = min(start + per_page, total - 1)
DEFECT: off by one
FAILURE: page 2 of 10 items drops index 9"

# The quote-vs-file gate: a FILE header naming a file that exists on disk
# demands the QUOTE actually occur in that file. Fixture written to $TMP so
# the repo needs no test-data file; nonexistent fixture paths elsewhere in
# this suite stay exempt by design.
printf 'first_line = 0\nthe_real_line = 1\n\x60\n' > "$TMP/quotegate.py"
audit_is "real file, real quote"     4 3 "FILE: $TMP/quotegate.py:2 | confidence: high
QUOTE: the_real_line = 1
DEFECT: assigns a constant where a computed value is required
FAILURE: every caller sees 1"
audit_is "real file, invented quote" 3 3 "FILE: $TMP/quotegate.py:2 | confidence: high
QUOTE: invented_line = 99
DEFECT: assigns a constant where a computed value is required
FAILURE: every caller sees 99"

# Gate semantics pinned: a fabricated quote anywhere poisons the whole verdict
# (label counts no longer match valid blocks -> exit 3), a wholesale echo of the
# prompt's worked example dies on its placeholder path, and normalization
# accepts quotes carried with backticks, collapsed whitespace, or a diff marker.
audit_is "fabricated quote poisons verdict" 3 3 "FILE: $TMP/quotegate.py:2 | confidence: high
QUOTE: the_real_line = 1
DEFECT: assigns a constant where a computed value is required
FAILURE: every caller sees 1
FILE: $TMP/quotegate.py:1 | confidence: high
QUOTE: fabricated_line = 42
DEFECT: also looks wrong
FAILURE: never happens"
audit_is "echoed worked example"            3 3 'FILE: example/demo.py:12 | confidence: high
QUOTE: total =+ amount
DEFECT: `=+` reassigns total to +amount instead of adding to it.
FAILURE: Summing [5, 5] returns 5, not 10.'
audit_is "quote with diff marker+backticks" 4 3 "FILE: $TMP/quotegate.py:2 | confidence: high
QUOTE: \`+the_real_line  =  1\`
DEFECT: assigns a constant where a computed value is required
FAILURE: every caller sees 1"
audit_is "backtick-only quote is a real line"  4 3 "FILE: $TMP/quotegate.py:3 | confidence: low
QUOTE: \`
DEFECT: stray backtick opens an unterminated command substitution
FAILURE: sourcing the file swallows every following line"

# 0 = clean. The clean verdict is the WHOLE output, never a phrase inside it.
audit_is "exact clean verdict"            0 3 'No findings.'
audit_is "clean verdict, no full stop"    0 3 'No findings'
audit_is "clean verdict plus chatter"     3 3 'No findings. I could not open two of the files.'

# 4 = defects, and only for complete blocks.
audit_is "one complete finding"           4 3 "$FINDING"
audit_is "two complete findings"          4 3 "$FINDING

$FINDING"
audit_is "finding plus trailing sentinel" 4 3 "$FINDING
No findings."
audit_is "extensionless path"             4 3 "FILE: $TMP/none/Makefile:12 | confidence: low
QUOTE: CFLAGS = -O2
DEFECT: wrong flag
FAILURE: build breaks"

# 3 = the verdict could not be established.
audit_is "labels out of order"            3 3 'DEFECT: bad
FILE:a.py:1
QUOTE: x
FAILURE: boom'
audit_is "labels present but empty"       3 3 'FILE:
QUOTE:
DEFECT:
FAILURE:'
audit_is "truncated block"                3 3 'DEFECT: something looks off'
audit_is "prose instead of a verdict"     3 3 'Overall this looks fine to me.'
audit_is "non-path FILE value"            3 3 'FILE: I could not determine the file
QUOTE: x = 1
DEFECT: bad
FAILURE: boom'
# QUOTE carries a copied SOURCE line, so punctuation-only is legitimate: a
# finding on a stray closing brace is still a finding. Only DEFECT and FAILURE
# are prose fields that must actually say something.
for q in "}" "});" "[weak self]" "(status == 0)"; do
    audit_is "punctuation-only QUOTE $q"  4 3 "FILE: $TMP/none/a.swift:12 | confidence: high
QUOTE: $q
DEFECT: leaks self
FAILURE: retain cycle survives dismissal"
done
audit_is "exact prompt placeholder QUOTE" 3 3 "FILE: $TMP/none/a.swift:12 | confidence: high
QUOTE: <the offending line, copied verbatim>
DEFECT: leaks self
FAILURE: retain cycle survives dismissal"
# Angle brackets are ordinary source in JSX, HTML and XML. Only the prompt's
# exact placeholders are rejected, never the shape.
for q in "<div>" "<Foo />" "</section>"; do
    audit_is "markup QUOTE $q"            4 3 "FILE: $TMP/none/App.jsx:12 | confidence: high
QUOTE: $q
DEFECT: element never closed
FAILURE: everything below it stops rendering"
done

# The model really does echo the prompt's own template back when it has
# nothing to say; a placeholder is not a finding.
audit_is "echoed prompt template"         3 3 'FILE:LINE | confidence: high|medium|low
QUOTE: <the offending line, copied verbatim>
DEFECT: <what is wrong with that line>
FAILURE: <concrete input or state that produces wrong behaviour>'
audit_is "ellipsis placeholders"          3 3 'FILE: ...
QUOTE: ...
DEFECT: ...
FAILURE: ...'
audit_is "zero tool calls"                3 0 'No findings.'
audit_is "zero tool calls with findings"  3 0 "$FINDING"
audit_is "empty response"                 3 2 ''

# A tool that STARTED proves nothing. If every tool call failed, the model read
# nothing and its verdict is worthless however confident it sounds.
audit_is "all tool calls failed"          3 3 'No findings.' stop 1
audit_is "failed tools, claims a defect"  3 3 "$FINDING" stop 1

# A verdict is only a verdict if the message carrying it finished. A truncated
# answer can read exactly like a clean one.
audit_is "stopReason length (truncated)"  3 3 'No findings.' length
audit_is "stopReason error"               3 3 'No findings.' error
audit_is "stopReason aborted"             3 3 'No findings.' aborted
audit_is "stopReason missing"             3 3 'No findings.' ''
audit_is "stopReason toolUse (unfinished)" 3 3 'No findings.' toolUse
audit_is "assistant message isError"      3 3 'No findings.' stop 0 1
audit_is "truncated mid-finding"          3 3 "$FINDING" length

# toolResult messages carry text too — in these fixtures, text containing
# "DEFECT:". Reading the last text block blindly would hand back tool output as
# the verdict; only assistant messages count.
audit_is "tool output is not a verdict"   3 3 ''

# --- placeholders track the prompt -------------------------------------------
# The rejection set is kept in step with the prompt by hand. This is the test
# that notices when it stops being: every "<...>" placeholder the prompt emits
# must appear in the auditor's rejection set, or an echoed template silently
# becomes a reported defect.

missing=$(/usr/bin/python3 - "$SCRIPT" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
prompt = src[src.index('PROMPT="${OPENING}'):src.index('# --- run ---')]
emitted = set(re.findall(r"<[^<>\n]+>", prompt))
rejected = set(re.findall(r'"(<[^"]+>)"', src[src.index("PLACEHOLDERS = {"):]))
print(" ".join(sorted(e for e in emitted if e.lower() not in {r.lower() for r in rejected})))
PY
)
[ -z "$missing" ] && ok || bad "prompt placeholders missing from the rejection set: $missing"

# --- argument validation -----------------------------------------------------
# These run before any precondition, so they need neither a model nor a server.

arg_is() { # $1=label  $2=expected exit  $3.. = args
    local label="$1" want="$2"; shift 2
    ( cd "$TMP" && bash "$SCRIPT" "$@" >/dev/null 2>&1 )
    local got=$?
    [ "$got" -eq "$want" ] && ok || bad "$label (expected exit $want, got $got)"
}

# --model is passed deliberately: without it these exit 2 through the MODEL
# pairing check below and would pass even with the provider `case` deleted.
arg_is "unknown provider is a usage error"  2 --provider bogus --model x
arg_is "provider is case-sensitive"         2 --provider LMStudio --model x
arg_is "--provider with no value"           2 --provider
# The default model id is an LM Studio one; pi forwards an id the provider never
# defined rather than rejecting it, so the pairing is enforced up front.
arg_is "llamaserver without --model"        2 --provider llamaserver
arg_is "--rounds needs a number"            1 --rounds abc
arg_is "unknown flag"                       2 --nope

# --- the lock ----------------------------------------------------------------
# Exercised through the script's own acquire_lock, sourced with everything
# after it stripped, so the test drives the shipped implementation.

# Extract acquire_lock, cleanup AND the production traps, so the release path
# under test is the shipped one rather than a description of it.
/usr/bin/python3 - "$SCRIPT" "$TMP/locklib.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index('LOCK=""\nacquire_lock()')
# Anchor on the TOP-LEVEL trap (column 0). acquire_lock sets the same traps
# internally when it masks signals, so an unanchored search truncates it.
MARK = "\ntrap 'exit 143' TERM"
end = src.index(MARK, start) + len(MARK)
open(sys.argv[2], "w").write(
    "set -u\n"
    'die() { printf "die: %s\\n" "$1" >&2; exit 1; }\n'
    'note() { printf "note: %s\\n" "$1" >&2; }\n'
    'RAW=""; LOADED_BY_US=0; LMS=/usr/bin/true; MODEL=stub\n'
    + src[start:end] + "\n"
)
PY
# The extracted library carries cleanup and its EXIT trap, so the lock is
# released when the helper exits — the acquisition assertions therefore report
# from INSIDE the run, not from the filesystem afterwards.
printf '. "%s"\nacquire_lock\n[ -d "$LOCK" ] && printf "held:%%s\\n" "$LOCK"\n' \
    "$TMP/locklib.sh" > "$TMP/lock.sh"

# The lock deliberately ignores XDG_CACHE_HOME (two runs with different values
# would take different locks while sharing one LM Studio instance), so the
# tests isolate by overriding HOME instead.
export HOME="$TMP/home"
mkdir -p "$HOME"
LOCK="$HOME/.cache/local-review/model.lock"

out=$(bash "$TMP/lock.sh" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok || bad "acquire_lock succeeds on a free lock (rc=$rc)"
case "$out" in *"held:$LOCK"*) ok ;; *) bad "the lock directory exists while held" ;; esac

# A lock held by a LIVE process is refused, and is NOT stolen.
mkdir -p "$LOCK"
printf '%s\n' $$ > "$LOCK/pid"
out=$(bash "$TMP/lock.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "a live lock is refused"
case "$out" in *"holds the model"*) ok ;; *) bad "refusal names the holding pid" ;; esac
[ -d "$LOCK" ] && ok || bad "a refused acquisition leaves the live lock intact"

# A lock whose owner is gone is still NOT reclaimed: two racing contenders that
# each reclaim can both end up holding it. It refuses, and says how to clear it.
mkdir -p "$LOCK"; printf '999999\n' > "$LOCK/pid"
out=$(bash "$TMP/lock.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "a dead-owner lock is refused rather than reclaimed"
case "$out" in *"rm -rf"*) ok ;; *) bad "dead-owner refusal prints the command to clear it" ;; esac
[ -d "$LOCK" ] && ok || bad "a dead-owner lock is left in place for a human"

# A lock with no pid file at all is a lock mid-acquisition, not a free one.
mkdir -p "$LOCK"; rm -f "$LOCK/pid"
bash "$TMP/lock.sh" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok || bad "a lock with no pid file is refused"

# --- release: drives the production cleanup + traps --------------------------

rm -rf "$LOCK"
bash "$TMP/lock.sh" >/dev/null 2>&1
[ ! -d "$LOCK" ] && ok || bad "a normal exit releases the lock"

# SIGTERM after acquisition must still release it. Nothing reclaims a stale
# lock any more, so a leak here blocks every later review permanently.
rm -rf "$LOCK"
printf '. "%s"\nacquire_lock\nkill -TERM $$\nsleep 5\n' "$TMP/locklib.sh" > "$TMP/term.sh"
bash "$TMP/term.sh" >/dev/null 2>&1
[ ! -d "$LOCK" ] && ok || bad "SIGTERM after acquisition still releases the lock"

# Ownership must be recorded BEFORE the pid write, which can fail or be
# interrupted; otherwise cleanup sees an empty LOCK and the directory survives
# forever. Asserted on the source order, because a pid write made to fail by
# permissions also makes the directory undeletable, which would test the
# filesystem rather than the ordering.
own_line=$(grep -n 'LOCK="\$lock"' "$SCRIPT" | head -1 | cut -d: -f1)
pid_line=$(grep -n 'printf .*"\$\$" > "\$lock/pid"' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$own_line" ] && [ -n "$pid_line" ] && [ "$own_line" -lt "$pid_line" ]; then
    ok
else
    bad "ownership is recorded before the pid write (own=$own_line pid=$pid_line)"
fi

# And the pid write must not be fatal: losing the owner label is not losing the
# lock.
grep -q 'pid" || note' "$SCRIPT" && ok || bad "a failed pid write warns instead of dying"

# Interrupts are masked across creation AND ownership assignment. Asserting the
# full ordering, not merely that masking appears somewhere: mask, then create,
# then record ownership, and only then restore the handlers. Restoring before
# the assignment would reopen the window the round-1 finding was about.
mask=$(grep -n "trap '' INT TERM" "$SCRIPT" | head -1 | cut -d: -f1)
mkdirl=$(grep -n 'if ! mkdir "\$lock"' "$SCRIPT" | head -1 | cut -d: -f1)
ownl=$(grep -n 'LOCK="\$lock"' "$SCRIPT" | head -1 | cut -d: -f1)
# the restore that follows a SUCCESSFUL acquisition, i.e. after ownership
restore=$(awk -v o="$ownl" "NR>o && /trap 'exit 130' INT/ {print NR; exit}" "$SCRIPT")
if [ -n "$mask" ] && [ -n "$mkdirl" ] && [ -n "$ownl" ] && [ -n "$restore" ] \
   && [ "$mask" -lt "$mkdirl" ] && [ "$mkdirl" -lt "$ownl" ] && [ "$ownl" -lt "$restore" ]; then
    ok
else
    bad "mask($mask) < mkdir($mkdirl) < own($ownl) < restore($restore)"
fi

# The failure path must restore the handlers too, or a refused acquisition
# leaves the caller unable to be interrupted.
fail_restore=$(awk -v m="$mkdirl" -v o="$ownl" \
    "NR>m && NR<o && /trap 'exit 130' INT/ {print NR; exit}" "$SCRIPT")
[ -n "$fail_restore" ] && ok || bad "the refusal path restores INT/TERM handlers"

# The lock assertions above drive the extracted function. This one pins that
# the script still CALLS it, unconditionally: commenting the call out leaves
# every lock test green while no review ever takes a lock.
call_line=$(grep -n '^acquire_lock$' "$SCRIPT" | head -1 | cut -d: -f1)
[ -n "$call_line" ] && ok || bad "review.sh calls acquire_lock at top level"
# ...and that no INDENTED call is the only one, which would mean some providers
# skip the lock. (The assertion above already anchors at column 0, so this is
# the real second guard: an indented call with no top-level one.)
if [ -z "$call_line" ] && grep -qE '^[[:space:]]+acquire_lock$' "$SCRIPT"; then
    bad "acquire_lock is only called inside a conditional, so some runs skip the lock"
else
    ok
fi

# The EXIT trap must not end on a command that can fail: bash adopts its last
# status as the script's, which would rewrite 0/3/4 into 1.
# Both `[ ... ] &&` and `[[ ... ]] &&` rewrite the exit status identically.
if awk '/^cleanup\(\) \{/,/^\}/' "$SCRIPT" | grep -qE '^[[:space:]]*\[\[?.*\]\]?[[:space:]]*&&'; then
    bad "cleanup uses a && chain; a failing last test rewrites the exit status"
else
    ok
fi

# --- preconditions, driven through the real script with stubs ----------------
# These two repairs are the highest-consequence ones in the file and had no
# coverage: reverting either left the suite fully green.

STUBS="$TMP/stubs"; mkdir -p "$STUBS"
# pi that emits a minimal valid clean-verdict stream, so a run can complete.
cat > "$STUBS/pi" <<'PISTUB'
#!/usr/bin/env bash
printf '%s\n' '{"type":"tool_execution_start"}'
printf '%s\n' '{"type":"tool_execution_end","isError":false}'
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"totalTokens":9},"content":[{"type":"text","text":"No findings."}]}}'
PISTUB
# lms that PRINTS a matching line but EXITS NON-ZERO -- the shape that used to
# be misread as "server down" / "model not loaded" under `set -o pipefail`.
cat > "$STUBS/lms" <<'LMSSTUB'
#!/usr/bin/env bash
case "$1" in
  server) printf 'The server is running on port 1234.\n' ;;
  ps)     printf 'IDENTIFIER MODEL\nqwen/qwen3-coder-30b IDLE\n' ;;
  *)      printf 'stub\n' ;;
esac
exit 7
LMSSTUB
chmod +x "$STUBS/pi" "$STUBS/lms"

REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
printf 'x = 1\n' > "$REPO/a.py"

# A non-zero lms exit must not make the matched text invisible. If it does, the
# script decides the model is absent, unloads and reloads it, and then unloads
# a model the user had loaded -- breaking its own stated promise.
out=$(cd "$REPO" && PATH="$STUBS:$PATH" HOME="$TMP/home" bash "$SCRIPT" 2>&1); rc=$?
case "$out" in
  *"already loaded"*) ok ;;
  *) bad "a non-zero lms exit hid the matching line (got: $(printf '%s' "$out" | head -1))" ;;
esac
case "$out" in
  *"clearing resident models"*) bad "the script unloaded a model the user had loaded" ;;
  *) ok ;;
esac
[ "$rc" -eq 0 ] && ok || bad "stubbed clean review should exit 0, got $rc"

# The llamaserver reachability probe is not optional: without curl the bare
# "Connection error" it exists to translate comes back instead.
NOCURL="$TMP/nocurl"; mkdir -p "$NOCURL"
cp "$STUBS/pi" "$NOCURL/pi"
for b in bash git printf sed grep awk python3 mktemp rm mkdir cat wc tr head cmp find; do
    src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$NOCURL/$b" 2>/dev/null
done
out=$(cd "$REPO" && PATH="$NOCURL" HOME="$TMP/home" bash "$SCRIPT" --provider llamaserver --model local-reviewer 2>&1); rc=$?
case "$out" in
  *curl*) ok ;;
  *) bad "a missing curl must hard-error, not skip the reachability check" ;;
esac
[ "$rc" -eq 1 ] && ok || bad "missing curl should exit 1, got $rc"

# --- the two copies must not drift --------------------------------------------
# review.sh is safety-critical and lives in two repos. Hand-porting it is what
# shipped known false-clean bugs to the public mirror once already, so identity
# is a gate rather than a habit. Skipped when the mirror is not checked out.

pair_check() { # $1=this repo's copy  $2=the other repo's copy
    local here="$1" there="$2"
    if [ ! -f "$there" ]; then
        skip "$there not checked out; drift unverified"
        return
    fi
    # Same file resolved twice compares equal to itself and proves nothing. This
    # is the normal case when the suite runs FROM the mirror, where ROOT and
    # MIRROR are one directory.
    if [ "$here" -ef "$there" ]; then
        skip "$(basename "$here"): both paths are the same file; run from the other repo, or set LOCAL_REVIEW_MIRROR"
        return
    fi
    cmp -s "$here" "$there" && ok || bad "$(basename "$here") differs between the two repos"
}

# review.sh sits at a different depth in each repo, so the counterpart has to be
# resolved the same way SCRIPT is rather than assuming the other side's layout.
counterpart() {
    if [ -f "$1/skills/local-review/scripts/review.sh" ]; then
        printf '%s' "$1/skills/local-review/scripts/review.sh"
    else
        printf '%s' "$1/scripts/review.sh"
    fi
}

if [ -d "$MIRROR" ]; then
    pair_check "$SCRIPT" "$(counterpart "$MIRROR")"
    pair_check "$ROOT/tests/test_local_review_audit.sh" "$MIRROR/tests/test_local_review_audit.sh"
else
    skip "$MIRROR not checked out; drift unverified (set LOCAL_REVIEW_MIRROR)"
fi

echo "-----"
echo "pass=$pass fail=$fail skipped=$skipped"
[ "$fail" -eq 0 ]
