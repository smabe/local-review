# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A local, offline code reviewer driven by the
[pi](https://github.com/earendil-works/pi) agent harness against a local
OpenAI-compatible endpoint. The model is not fixed: any id declared in
`~/.pi/agent/models.json` runs via `--provider` / `--model`, under either of
the two providers review.sh accepts (`llamaserver`, `lmstudio` —
`scripts/review.sh:83`). The shipped defaults are the two that were measured:
Qwen3.8-27B with thinking disabled (llama-server) for accuracy, Qwen3-Coder-30B
(LM Studio) as a fast tier for small diffs only — it false-cleans large ones.
bench/ holds the evidence for both and is the instrument for scoring a
replacement. `scripts/review.sh` is the whole product — everything else is a
test, the bench, or a legacy path. It is an **advisory pre-pass**; it never
gates a commit and never replaces a frontier-model review.

## Commands

```bash
bash tests/test_local_review_audit.sh          # the suite (84 assertions); exit 0 = green
LOCAL_REVIEW_MIRROR=~/projects/abe-skills bash tests/test_local_review_audit.sh   # include the drift checks
python3 scripts/test_local_review_scope.py     # legacy diff-pipe scope tests
python3 scripts/test_local_review_scope.py DefaultScopeIncludesUntracked.test_empty_repo_falls_back_to_untracked_only   # one case

scripts/llama_server.sh                        # serve the default reviewer first (:8080)
scripts/review.sh                              # run a review of the working tree
scripts/review.sh --json                       # same, printing pi's raw event stream
scripts/review.sh --provider lmstudio --model qwen/qwen3-coder-30b   # fast tier, small diffs

bench/run_eval.sh    llamaserver <model-id> 2 <label>   # score a model: 5 seeded one-bug diffs
bench/run_bigdiff.sh llamaserver <model-id> 2 <label>   # score a model: the 18KB fixture
```

The audit suite has no per-test filter — it is one bash file with a
`pass=/fail=/skipped=` footer. **Read `skipped=`**: the two drift checks report
SKIP unless the private mirror is checked out, and a skip is not a pass.

The default provider is llamaserver: start the server yourself (it owns its
model for the life of the process). A non-default provider must be paired with
an explicit `--model` (pi silently forwards an id its provider never declared,
so the per-model sampling settings just do not apply); lmstudio models are
auto-loaded and unloaded by review.sh. LM Studio lifecycle by hand:
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
   frame. An `--angle` run swaps in that angle's own single-class system prompt
   instead of the shared scaffold (docs/angle-stale-comment.md).
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

- **`--parallel 1`.** Parallel slots split the context allocation N ways and
  pi is a single client.
- **The 3-round tool budget is a stability guard, not a speed knob.** LM Studio's
  MLX engine dies on long single generations (~11K tokens); capped rounds plus
  `maxTokens: 8192` keep every generation under it. llama-server does not have
  this problem.
- **Reviews diffs, not whole files.** With no diff to anchor on the model
  fabricated 7/7 findings.
- **Keep system-prompt rules 1 and 2** — quote the offending line verbatim, and
  prose/docs cannot contain a defect. Dropping either brings the fabrications
  back (measured, 3 runs per arm).
- **Keep both halves of the user prompt's Method line** (purpose-anchored
  review, v7). The purpose-first framing is measured recall (docs/evict-gap.md);
  the "silently … spend your output on the verdict" clause is what stops the
  analysis flooding the thinking channel until the generation cap eats the
  verdict — a phrasing without it produced no-verdict runs.
- **`--exclude-tools edit,write` is advisory.** pi has no OS-enforced sandbox and
  its bash tool can still write. For untrusted diffs use
  `codex exec --sandbox read-only`.
- **`--intent` inherits every error in the intent's source.** It makes the stated
  intent unfalsifiable, which also holds when the intent is wrong.
- **Never `git add`.** An advisory reviewer must not touch the index.

Context sizing is a suggestion, not a constraint: 49152 is the default
because every accuracy number was measured there. Measured data for anyone
raising it: llama-server + Qwen3.8 at 96K peaked at 31.5 GB wired on a 48 GB
machine (`LLAMA_CTX=98304`, matching `contextWindow` in models.json; accuracy
above 49152 unmeasured; full-window prefill ~8 min). The one 96K attempt on
MLX/LM Studio wired ~35 GB and kernel-panicked the machine — we keep MLX at
49152 ourselves.

Runs on **macOS and Linux**, so no BSD-only spellings: `mktemp` takes an
explicit `.XXXXXX` template (GNU coreutils rejects a template with fewer than
three X's, which killed the run on Linux), and the same care applies to `sed
-i`, `stat`, and `date`. Only the timings are Apple-Silicon-specific.

Targets **bash 3.2** (macOS system bash): guard empty array expansion as
`${a[@]+"${a[@]}"}` under `set -u`. In the EXIT trap every branch is a full `if`
— bash adopts the trap's last command status, and a trailing failed test would
rewrite a 0/3/4 into 1 and void the exit contract.

## Changing the reviewer: the experiment loop

Any change to the reviewer's prompt, pipeline, or model choice follows
`docs/experiment-loop.md`: hypothesis and ship/revert rule pre-registered in a
docs/ file before any run, benched through the real `review.sh`, scored by
composition (which defects, not how many), researched online when results
disappoint, then shipped or reverted per the pre-registered rule — fixture,
doc, and bench rows kept either way. `docs/evict-gap.md` (shipped) and
`docs/angle-removed-behavior.md` (reverted) are the exemplars.

## Peripheral files

`scripts/llama_server.sh` serves the default engine (~25% slower per token than
MLX, zero crashes observed, which is why it is the default) — bare it serves the
measured reviewer GGUF, and it takes a path plus flags for any other model.
`scripts/local_review.py` is the legacy diff-pipe with no agent loop,
useful only with *thinking* models — do not point the coder model at it, since
diff-blind it fabricates. `skill/SKILL.md` is what gets copied to
`~/.claude/skills/local-review/`; it duplicates the operational guidance by
design, so a change to behaviour usually touches README, SKILL.md, and the tests
together.
