---
name: local-review
description: Run a free, private code review on a local LLM served on this machine (llama-server or LM Studio) using the pi agent harness — the shipped default is Qwen3.8-27B no-think, with a Qwen3-Coder-30B fast tier for small diffs, and any other model selectable with --provider/--model. Advisory pre-pass only — it never replaces the real review gate. Use when the user asks for a local review, a free second opinion on a diff, or offline review.
---

# local-review — code review on a local model

Advisory reviewer running entirely on this machine. Its blind spots are
uncorrelated with a cloud reviewer's; it does NOT replace one.

## Run it

```bash
# LR = the local-review checkout, or its ~/.claude/skills/local-review install
cd <repo with uncommitted changes>
"$LR"/scripts/llama_server.sh    # serve the default reviewer first (:8080)
"$LR"/scripts/review.sh
"$LR"/scripts/review.sh --intent "<one sentence>"
```

That is the whole happy path. The script checks the preconditions, assembles
the round-capped prompt, runs pi, and audits the result. Read it rather than
reconstructing the invocation by hand — the flag set is load-bearing and easy
to get subtly wrong.

| flag | when |
|---|---|
| `--intent "<sentence>"` | you made the change and can state its purpose — read the caveat below first |
| `--rounds N` | default 3; raise to 4–5 when the review needs a codebase search pass |
| `--angle stalecomment` | opt-in single-class pass for stale comments/docstrings the changed code contradicts — the class the default pass is banned from reporting. Replaces the general review for that run: run it in addition to the default pass, never instead (its exit 0 says nothing about correctness bugs). Anchors findings on the comment line; mutually exclusive with `--intent` |
| `--verify` | adversarially re-check each finding with a second model pass; refuted findings drop from the verdict (all-refuted → exit 0) but stay printed as evidence. Measured 14/14 retention / 8/8 refutation. One extra generation per finding |
| `--json` | print pi's raw event stream instead of the review |
| `--provider` / `--model` | switch engine/model — any id declared in `~/.pi/agent/models.json`, under `llamaserver` or `lmstudio`. E.g. `--provider lmstudio --model qwen/qwen3-coder-30b` for the ~5s fast tier on SMALL diffs (it false-cleans large ones) |

**It manages the model for you** (LM Studio only). If the model isn't resident
it clears what is loaded, loads it at 49152 context, and unloads it when the
review ends — including on a failed run or a Ctrl-C. A model you loaded by hand
is used and left alone. The cost is a load on every cold run, which dwarfs the
review itself, so load it yourself first when running several reviews.

Because one machine has one resident model, reviews are serialised: a run takes
a lock for its whole load/review/unload cycle, and a second run started
meanwhile exits immediately saying which process holds it.

**Every run is audited**, and the exit status carries the verdict: **0** clean,
**4** defects reported, **3** the verdict cannot be trusted. Only 0 means clean. (Exception under `--verify`: all findings refuted → exit 0, with the refuted blocks printed as evidence.)

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

The user prompt adds the purpose-anchored method (v7, measured 2026-08-18 —
docs/evict-gap.md in the repo): determine each changed function's purpose
first, then judge its lines against that purpose, silently. Measured effect:
an inverted-comparator bug went from 1/10 to 2/5 catches on the 18KB fixture,
mean catches ~3.3 → ~3.8 of 5, clean diffs still zero findings in every run.
Both halves of the line are load-bearing — the purpose-first framing carries
the recall, and the brevity/"spend output on the verdict" clause prevents the
analysis flooding the thinking channel until the generation cap kills the
verdict (measured failure of an earlier phrasing).

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
- **Context sizing is a suggestion.** 49152 is the accuracy-measured default.
  llama-server + Qwen3.8 at 96K measured 31.5GB wired peak (2026-08-18):
  `LLAMA_CTX=98304 "$LR"/scripts/llama_server.sh` plus a matching `contextWindow`
  in `~/.pi/agent/models.json`; accuracy above 49152 is unmeasured and full-window prefill runs ~8 min. Our one
  96K attempt on MLX/LM Studio wired ~35GB and kernel-panicked the machine,
  so we keep MLX at 49152 and its guardrails on Strict.
- **This reviews DIFFS.** Pointed at committed files with no diff to anchor on,
  it produced 7/7 false positives, mostly from treating independent components
  as one pipeline. A whole-file audit needs ~150 tokens of design context in
  the prompt (component map + behavioural contract), which flips it to a
  correct verdict — but that is verification against an authored spec, not
  discovery, and a stale block blinds it.
- **Model choice is open; the defaults are just what survived measurement.**
  Nothing in the script pins a model — serve another one and select it with
  `--provider`/`--model`, and score it with the repo's `bench/` before trusting
  it. What the candidates scored: Qwen3.8-27B no-think is the default,
  Qwen3-Coder-30B the fast tier. A
  5-case seeded-defect eval (4 planted bugs + 1 clean diff, 2+ runs per arm,
  both engines, 2026-08-18) scored Qwen3-Coder 6/8 catches with zero false
  positives at ~5s/review — it reliably misses the hardest case (a swallowed
  error path causing silent data loss). Qwen3.8-27B caught 31/32 across every
  prompt version with zero false positives, and stays that accurate on
  llama-server with thinking DISABLED (`--reasoning-budget 0`), ~40% faster
  than thinking mode (~100s median). Big-diff validated (18KB fixture, 2026-08-18):
  no-think completes in 9-15 min with real findings and zero fabrications,
  while Qwen3-Coder false-cleaned the same diff twice in ~20s — use the
  accuracy pick for anything beyond a small diff. Devstral Small 2 24B:
  5/8 strict (misses the same hard case both runs, plus intermittent leak
  misses); its 2512 GGUFs do not load on llama.cpp stable 10450
  ("invalid gguf type for tokenizer.ggml.scores"). GLM-4.7-Flash
  fabricates plausibly-quoted findings and wedged LM Studio's MLX engine;
  disqualified.
- **Thinking cannot be limited through LM Studio.** Probed directly against its
  OpenAI endpoint: `chat_template_kwargs.enable_thinking`, a top-level
  `enable_thinking`, and `reasoning_effort` are all accepted and all ignored.
  pi does not send a level either unless the provider declares a
  `thinkingFormat` or `supportsReasoningEffort: true`. Seeing thinking blocks
  in the event stream proves thinking happened, not that a level was honoured.
- **Do not feed the reviewer a project's AGENTS.md / CLAUDE.md.** Thousands of
  tokens of workflow rules aimed at an implementing agent, with no correctness
  content.

## Engines

llama-server is the default engine: `"$LR"/scripts/llama_server.sh` serves a
GGUF on :8080 and owns it for the life of the process — called bare it serves
the measured default (Qwen3.8, thinking disabled), and it takes a model path
plus flags for anything else. Zero crashes observed across the whole
experiment. LM Studio (MLX) is the fast tier:
review.sh manages its model lifecycle for you, but its engine dies on long
single generations — the 3-round budget exists because of it — and thinking
cannot be controlled through its API.

## Legacy path — diff-pipe script

`scripts/local_review.py` posts a diff plus a review prompt straight to an
OpenAI-compatible endpoint, with no agent loop and no repo access. Kept because
it is the only path that suits thinking models, which review diffs well but are
too slow to finish agentically. Do NOT use the coder model with it — given only
a diff, with no ability to read the surrounding code, it fabricates (~70 fake
findings in one run).
