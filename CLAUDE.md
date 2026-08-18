# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A local, offline code reviewer driven by the
[pi](https://github.com/earendil-works/pi) agent harness against any
OpenAI-compatible endpoint — LM Studio (MLX) or llama-server today, and any
model declared in `~/.pi/agent/models.json` via `--provider` / `--model`.
Qwen3-Coder-30B is the default and the only model measured so far, not a
requirement. `scripts/review.sh` is the whole product — everything else is a test,
a fallback engine, or a legacy path. It is an **advisory pre-pass**; it never
gates a commit and never replaces a frontier-model review.

## Commands

```bash
bash tests/test_local_review_audit.sh          # the suite (60+ assertions); exit 0 = green
LOCAL_REVIEW_MIRROR=~/projects/abe-skills bash tests/test_local_review_audit.sh   # include the drift checks
python3 scripts/test_local_review_scope.py     # legacy diff-pipe scope tests
python3 scripts/test_local_review_scope.py DefaultScopeIncludesUntracked.test_empty_repo_falls_back_to_untracked_only   # one case

scripts/review.sh                              # run a review of the working tree
scripts/review.sh --json                       # same, printing pi's raw event stream
scripts/review.sh --provider llamaserver --model local-reviewer   # another engine/model
```

The audit suite has no per-test filter — it is one bash file with a
`pass=/fail=/skipped=` footer. **Read `skipped=`**: the two drift checks report
SKIP unless the private mirror is checked out, and a skip is not a pass.

Auto-load only knows the default model, and a non-default provider must be
paired with an explicit `--model` (pi silently forwards an id its provider never
declared, so the per-model sampling settings just do not apply). Load anything
else yourself. Model lifecycle by hand:
`~/.lmstudio/bin/lms server status` · `lms ps` ·
`lms load "qwen/qwen3-coder-30b" --yes --context-length 49152 --parallel 1` ·
`lms unload --all`.

## Architecture

`scripts/review.sh` runs a five-stage pipeline, and each stage exists because of
a failure that was measured, not anticipated:

1. **Preconditions** — pi on PATH, python3, inside a git repo, and the *server*
   reachable (LM Studio via `lms server status` text matching, llama-server via
   a curl probe). After a reboot the model can be loadable while the API server
   is down; pi surfaces that only as a bare "Connection error", so the script
   translates it.
2. **Is there anything to review** — computed before any model load, so a clean
   tree costs nothing. With no HEAD yet it diffs `--cached`, and untracked files
   are counted separately because `git diff HEAD` cannot see them.
3. **Lock + model lifecycle** — one machine serves one model, so a `mkdir`-based
   lock in `~/.cache/local-review` serialises whole runs. Nothing ever reclaims
   a lock it did not create. The model is unloaded from an EXIT trap, and only
   if this run is what loaded it.
4. **Prompt assembly** — a reviewer system prompt replaces pi's default
   coding-assistant one, plus a round-capped user prompt and an optional intent
   frame.
5. **The audit** — an inline Python heredoc parses pi's JSON event stream and
   decides the exit status. This is the part that must not be wrong.

### The exit contract

`0` clean · `1` error · `2` usage · `3` the verdict cannot be trusted · `4`
defects reported. **Only 0 means clean.** A 3 covers every way a run can look
clean without being one: no tool call *succeeded* (one that merely started
proves nothing), the verdict message did not finish (`stopReason != stop` or
`isError`), an empty response, a half-emitted finding block, or `No findings.`
with text trailing it.

Two invariants inside the audit that are easy to break by "simplifying":

- **Only assistant messages are verdicts.** Tool results arrive as their own
  `message_end` carrying whole file contents; taking the last text block blindly
  would return a source file as the review.
- **A finding is all four labels** — FILE, QUOTE, DEFECT, FAILURE — in order,
  non-empty, path-like header, and not one of the prompt's own placeholders.
  Counting `DEFECT:` alone accepted truncated blocks.

### Two things that shape every edit here

**`review.sh` and `tests/test_local_review_audit.sh` are byte-identical in this
repo and in the private `smabe/abe-skills` (where they live under
`skills/local-review/`).** Fix bugs in one copy and port verbatim; never
hand-adapt. The suite's `pair_check` enforces this when `LOCAL_REVIEW_MIRROR`
points at the other checkout. Scripts resolve their own path at both depths —
keep that dual-path handling when touching either file.

**The tests extract the audit from `review.sh` at run time** (an `awk` range on
the `python3 - "$RAW" ... <<PY` heredoc) rather than duplicating it. Renaming
that heredoc or its `PY` terminator breaks extraction, and the suite fails loudly
rather than passing against a stale copy — keep it that way.

## Constraints that are not preferences

Each cost something to learn; the README's "Hard rules" section carries the full
list and the evidence.

- **Context stays at 49152, `--parallel 1`.** A 96K attempt wired ~35 GB and
  kernel-panicked a 48 GB machine.
- **The 3-round tool budget is a stability guard, not a speed knob.** LM Studio's
  MLX engine dies on long single generations (~11K tokens); capped rounds plus
  `maxTokens: 8192` keep every generation under it. llama-server does not have
  this problem.
- **Reviews diffs, not whole files.** With no diff to anchor on the model
  fabricated 7/7 findings.
- **Keep system-prompt rules 1 and 2** — quote the offending line verbatim, and
  prose/docs cannot contain a defect. Dropping either brings the fabrications
  back (measured, 3 runs per arm).
- **`--exclude-tools edit,write` is advisory.** pi has no OS-enforced sandbox and
  its bash tool can still write. For untrusted diffs use
  `codex exec --sandbox read-only`.
- **`--intent` inherits every error in the intent's source.** It makes the stated
  intent unfalsifiable, which also holds when the intent is wrong.
- **Never `git add`.** An advisory reviewer must not touch the index.

Targets **bash 3.2** (macOS system bash): guard empty array expansion as
`${a[@]+"${a[@]}"}` under `set -u`. In the EXIT trap every branch is a full `if`
— bash adopts the trap's last command status, and a trailing failed test would
rewrite a 0/3/4 into 1 and void the exit contract.

## Peripheral files

`scripts/llama_server.sh` is the fallback engine (~25% slower, zero crashes
observed). `scripts/local_review.py` is the legacy diff-pipe with no agent loop,
useful only with *thinking* models — do not point the coder model at it, since
diff-blind it fabricates. `skill/SKILL.md` is what gets copied to
`~/.claude/skills/local-review/`; it duplicates the operational guidance by
design, so a change to behaviour usually touches README, SKILL.md, and the tests
together.
