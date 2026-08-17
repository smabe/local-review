---
name: local-review
description: Run a free, private code review on a local LLM (Qwen3-Coder-30B via LM Studio or llama-server) using the pi agent harness. Advisory pre-pass only — it never replaces the real review gate. Use when the user asks for a local review, a free second opinion on a diff, or offline review.
---

# local-review — code review on a local model

Advisory reviewer running entirely on this machine. Its blind spots are
uncorrelated with a cloud reviewer's; it does NOT replace one.

## Run it

```bash
cd <repo>
scripts/review.sh
scripts/review.sh --intent "<one sentence>"
```

That is the whole happy path. The script checks the preconditions, assembles
the round-capped prompt, runs pi, and audits the result. Read it rather than
reconstructing the invocation by hand — the flag set is load-bearing and easy
to get subtly wrong.

| flag | when |
|---|---|
| `--intent "<sentence>"` | you made the change and can state its purpose — read the caveat below first |
| `--rounds N` | default 3; raise to 4–5 when the review needs a codebase search pass |
| `--json` | print pi's raw event stream instead of the review |
| `--provider` / `--model` | switch to the llama-server engine |

**It manages the model for you** (LM Studio only). If the model isn't resident
it clears what is loaded, loads it at 49152 context, and unloads it when the
review ends — including on a failed run or a Ctrl-C. A model you loaded by hand
is used and left alone. The cost is a load on every cold run, which dwarfs the
review itself, so load it yourself first when running several reviews.

Because one machine has one resident model, reviews are serialised: a run takes
a lock for its whole load/review/unload cycle, and a second run started
meanwhile exits immediately saying which process holds it.

**Every run is audited**, and the exit status carries the verdict: **0** clean,
**4** defects reported, **3** the verdict cannot be trusted. Only 0 means clean.

A 3 covers every way a run can look clean without being one:
- no tool call **succeeded**, so the model read nothing (a tool that merely
  started proves nothing — this has already caught a real run against an
  unloaded model whose output read like a review)
- the message carrying the verdict did not finish — truncated by the token cap,
  aborted, or errored. A cut-off answer reads exactly like a clean one
- the output is neither an exact clean verdict nor complete findings: a
  half-emitted block, or "No findings." with explanatory text trailing it

Only ASSISTANT messages are read as verdicts. Tool results arrive as their own
messages and carry text — whole file contents — so anything else risks handing
back a source file as the review.

Status 4 certifies at least one complete finding block: FILE, QUOTE, DEFECT and
FAILURE in order, non-empty, with a path-like header. QUOTE holds a copied
source line, so `}`, `[weak self]` and `<div>` are all legitimate; only the
prompt's own placeholders are rejected, and by exact match rather than shape.

Also handled: a dead API server (reported with the fix, instead of surfacing
pi's bare "Connection error"), a tree with nothing to review, untracked files
being invisible to `git diff HEAD`, and diffs over 50KB, where the reviewer is
told its own `git diff` output truncates and to read the changed files.

Two things it does not do. It never runs `git add` — an advisory review must
not mutate the index. And `--exclude-tools edit,write` is advisory: pi has no
OS-enforced sandbox and its bash tool can still write, so for an untrusted diff
use a harness with an enforced read-only sandbox instead.

## The reviewer system prompt is the quality lever

pi's default system prompt makes a coding assistant, not a reviewer, and the
difference is large. `review.sh` replaces it with a persona whose rules were
measured, 3 runs per arm, against a fixture holding one planted off-by-one and
one deliberate-looking inconsistency:

| | default prompt | reviewer prompt |
|---|---|---|
| caught the planted bug | 3/3 | 3/3 |
| bit the false-positive trap | 2/3 | 0/3 |
| bogus claims on a docs-only diff | 0, 1, 3 | 0, 0, 0 |

The two rules doing the work are "quote the exact offending line verbatim or
the defect does not exist" and "prose and documentation cannot contain a
defect". Removing either brings the fabrications back.

## The intent frame, and what it costs

When the diff's intent is known — it usually is, since the session invoking
this skill made the change — `--intent` folds it in as the JUDGING FRAME rather
than a note. A bolt-on "INTENT: ..." preamble gets echoed and then ignored;
framing is what a 30B obeys.

**The frame inherits every error in the intent's source.** It suppresses false
positives by making the intent unfalsifiable, which also holds when the intent
is wrong. Use it only for a change you made yourself and a sentence you are
confident in; keep it to one sentence about the change, never a blanket "this
area is fine". Skip it when reviewing someone else's intent, or a plan whose
claims you have not checked against the source.

## Limits that are not preferences

- **The round cap is stability-critical.** The LM Studio MLX engine leaks Metal
  buffer descriptors (`metal::malloc Resource limit (499000) exceeded`) and
  kills long single generations around 11K tokens regardless of free RAM.
  Capped rounds keep every response under the threshold; `maxTokens: 8192` is
  the second line of defense. llama-server does not have this problem.
- **Context stays at 49152.** Pushing toward 96K+ wired ~35GB and
  kernel-panicked a 48GB machine. Keep LM Studio guardrails on Strict.
- **This reviews DIFFS.** Pointed at committed files with no diff to anchor on,
  it produced 7/7 false positives, mostly from treating independent components
  as one pipeline. A whole-file audit needs ~150 tokens of design context in
  the prompt (component map + behavioural contract), which flips it to a
  correct verdict — but that is verification against an authored spec, not
  discovery, and a stale block blinds it.
- **Model choice: Qwen3-Coder-30B-A3B.** Two alternatives were measured against
  a planted off-by-one and both lost. A Qwen3.8-27B thinking model writes the
  best analysis of anything tested and finishes a tiny diff in under two
  minutes, but a 19KB diff went unfinished at both 10 and 20 minutes. Devstral
  Small 2 24B missed the planted bug 8 times out of 9 despite reading the diff
  every run — its higher SWE-bench score measures *fixing* a bug you have been
  handed, which is the opposite of detection.
- **Thinking cannot be limited through LM Studio.** Probed directly against its
  OpenAI endpoint: `chat_template_kwargs.enable_thinking`, a top-level
  `enable_thinking`, and `reasoning_effort` are all accepted and all ignored.
  pi does not send a level either unless the provider declares a
  `thinkingFormat` or `supportsReasoningEffort: true`. Seeing thinking blocks
  in the event stream proves thinking happened, not that a level was honoured.
- **Do not feed the reviewer a project's AGENTS.md / CLAUDE.md.** Thousands of
  tokens of workflow rules aimed at an implementing agent, with no correctness
  content.

## Fallback engine — llama-server (GGUF)

If the MLX engine misbehaves, or you are not on Apple Silicon,
`scripts/llama_server.sh` serves a Q6 GGUF on :8080 — about 25% slower
generation, zero crashes observed across the whole experiment. Point the script
at it with `--provider llamaserver --model local-reviewer`, using the second
provider entry in `models.example.json`.

## Legacy path — diff-pipe script

`scripts/local_review.py` posts a diff plus a review prompt straight to an
OpenAI-compatible endpoint, with no agent loop and no repo access. Kept because
it is the only path that suits thinking models, which review diffs well but are
too slow to finish agentically. Do NOT use the coder model with it — given only
a diff, with no ability to read the surrounding code, it fabricates (~70 fake
findings in one run).
