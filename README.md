# local-review

A free, private, offline code reviewer that runs on your own machine. It
drives a local model — anything you can serve on an OpenAI-compatible
endpoint, llama-server or LM Studio — through the
[pi](https://github.com/earendil-works/pi) agent harness: it runs `git diff`,
reads your changed files, and reports correctness bugs, touching no network.

It is an **advisory pre-pass**, not a replacement for a frontier-model
review: its blind spots are real but *uncorrelated* with the big models',
which is exactly what makes a second opinion worth having. A false
positive costs you a minute of reading; a false negative costs nothing if
a real review still gates your commits.

### Which model

Your choice — declare it in `~/.pi/agent/models.json` and select it with
`--provider` / `--model`. Two are measured here and ship as the defaults:

| tier | model | speed | use it for |
|---|---|---|---|
| **accuracy** (default) | Qwen3.8-27B, thinking disabled, on llama-server | ~1 min small diff, up to ~15 min large | everything |
| **fast** | Qwen3-Coder-30B on LM Studio | ~5 s small diff | small diffs only — it false-cleans large ones |

Those numbers are measured, not estimated; `bench/` holds the evidence and is
the instrument for scoring any other model you want to try. The
["Model choice" rule](#hard-rules-each-one-was-paid-for) below records what
the rejected candidates scored.

**Requirements:** macOS or Linux, with enough memory to run the model you
choose — RAM on a unified-memory Mac, VRAM (or RAM, slowly) on a Linux box.
The default reviewer weighs ~23 GB, so ~32 GB is the comfortable floor for
it; a smaller model asks for less. Plus git, Node.js/npm, python3, curl, and
llama.cpp (`brew install llama.cpp`, or build it from source).
[LM Studio](https://lmstudio.ai) only if you want the fast tier.

Everything here was *measured* on Apple Silicon. The accuracy numbers are
properties of the model and the prompt and carry over; the timings are not —
expect different wall-clock on different hardware.

---

## Setup — instructions for a coding agent

> If you are a coding agent (Claude Code, etc.) setting this up for your
> user: follow these steps in order. Every step has a verification
> command — do not proceed past a failing check. Total time is ~20
> minutes, dominated by a ~21 GB model download.

### 1. Serve the model

```bash
# Download the default reviewer GGUF (~21 GB, one time)
mkdir -p ~/models && curl -L -o ~/models/Qwen3.8-27B-Q6_K.gguf \
  "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-Q6_K.gguf"

# Serve it on :8080. The script finds the GGUF, defaults context to 49152
# (raise via LLAMA_CTX if that suits your machine -- see Context sizing),
# and disables thinking, which is the measured reviewer configuration.
scripts/llama_server.sh
```

Verify: `curl -s http://localhost:8080/health` returns `{"status":"ok"}`.

Serving a different model instead: pass its path and any flags it needs —
`scripts/llama_server.sh ~/models/your-model.gguf --whatever` — and add a
matching entry to `~/.pi/agent/models.json` (step 2). The script never
substitutes a model silently: with no path it serves the measured default or
tells you it cannot find it.

Optional fast tier (small diffs only), via LM Studio:

```bash
~/.lmstudio/bin/lms get qwen/qwen3-coder-30b
~/.lmstudio/bin/lms server start
# review.sh loads and unloads this model for you when you pass:
#   --provider lmstudio --model qwen/qwen3-coder-30b
```

### 2. Install pi and configure the provider

```bash
npm install -g @earendil-works/pi-coding-agent
pi --version   # expect >= 0.84
mkdir -p ~/.pi/agent
```

Copy [`models.example.json`](models.example.json) from this repo to
`~/.pi/agent/models.json`. If the user already has a `models.json`, merge
both provider blocks into it instead of overwriting. Do not add
JSON comments — they fail silently.

Any other model gets an entry alongside these two, under whichever of the
two providers serves it, and is then selected with `--provider` / `--model`.
The id must match what the server actually answers to: pi forwards an id its
provider never declared without complaining, and the per-model sampling
settings then silently do not apply.

Verify (first call wakes the model and can take ~60s; a repeat should
round-trip in 1–2s):

```bash
pi --provider llamaserver --model qwen38-gguf-nothink \
   --no-session -nc -ns -p "Reply with exactly: OK" </dev/null
```

### 3. Install the skill (Claude Code users)

```bash
mkdir -p ~/.claude/skills/local-review
cp skill/SKILL.md ~/.claude/skills/local-review/SKILL.md
cp -R scripts ~/.claude/skills/local-review/scripts
```

Done. "Run a local review" in any session now triggers it.

### 4. Run one

```bash
cd <any repo with uncommitted changes>
~/.claude/skills/local-review/scripts/review.sh
```

`scripts/review.sh` is the whole interface, for Claude users and everyone
else alike. It checks the preconditions (including that llama-server is
answering — start it with `scripts/llama_server.sh`, which owns the model
for the life of the process), assembles the round-capped prompt, runs pi,
and audits the result. Nothing needs assembling by hand. On the lmstudio
fast tier it additionally loads the model if it is not already resident and
unloads it afterwards.

| flag | what it does |
|---|---|
| `--intent "<sentence>"` | judge the diff against a stated purpose — read the caveat below before using it |
| `--rounds N` | tool-call budget, default 3; raise to 4–5 when the review needs a codebase search pass |
| `--angle stalecomment` | opt-in single-class pass: reports ONLY comments and docstrings the changed code contradicts, quoting the comment line — the one class rule 2 bans from the default pass. It replaces the general review for that run, so run it in addition to the default pass, never instead; its exit 0 says nothing about correctness bugs. Measured fabrication-free (docs/angle-stale-comment.md); mutually exclusive with `--intent` |
| `--verify` | opt-in second stage: each validated finding is adversarially re-checked by a verifier pass; refuted findings are dropped from the verdict but stay printed with the refutation reason. All findings refuted → exit 0 with a loud note. Measured: 14/14 true findings retained, 8/8 provably-false refuted (docs/verifier-pass.md, docs/verify-flag.md). Costs one generation per finding |
| `--json` | print pi's raw event stream instead of the review; every run is audited either way |
| `--provider NAME` | `llamaserver` (default) or `lmstudio` |
| `--model ID` | model id as declared in `~/.pi/agent/models.json`; required whenever `--provider` is not the default |

One machine has one resident model, so reviews are serialised: a run holds a
lock for its whole duration, and a second run started while it is held exits
immediately naming the process that holds it.

Verify: in a repo with a deliberate bug, the script reports it as
`FILE: path/to/file.py:LINE | confidence: ... / QUOTE: ... / DEFECT: ... / FAILURE: ...`
followed by an audit line reading `audit: N/N tool calls ok, 1 defect(s), … tokens peak`.

---

## How it works

The whole trick is **harness weight**. A local model ingests prompts at a
few hundred tokens/second, and every agent round re-reads the whole
conversation — so the harness's opening prompt dominates wall-clock time:

| Harness | Opening prompt | Result with a local 30B |
|---|---|---|
| pi (`-nc -ns --no-session`) | ~1.6K tokens | works — canary review in 12.7s |
| Codex CLI (`codex exec`) | ~20K tokens | works — same review in 50s |
| Claude Code as the harness | >65K tokens | model emits garbage at that depth |

pi's entire review — system prompt, three tool rounds, diff, verdict —
peaks under 9K tokens, leaving ~40K of the 49K context window for your
actual diff. Same model, same verdict quality; the difference is purely
overhead. (Claude Code *invoking* pi via the skill is fine — pi is the
harness, Claude just launches it.)

The review prompt carries a hard cap ("at most 3 rounds of tool calls,
batch commands") which is **stability-critical** on LM Studio: its MLX engine
crashes on long single generations (~11K tokens). Capped rounds plus
`maxTokens: 8192` keep every generation under the threshold. llama-server has
not shown the problem, but the cap is the default on both paths — every
accuracy number here was measured with it in place.

### The system prompt is the quality lever

pi's default system prompt makes a coding assistant, not a reviewer, and
the gap is large. `review.sh` replaces it with a reviewer persona whose
rules were measured, 3 runs per arm, on a fixture holding one planted
off-by-one and one deliberate-looking inconsistency:

| | pi's default prompt | reviewer prompt |
|---|---|---|
| caught the planted bug | 3/3 | 3/3 |
| bit the false-positive trap | 2/3 | 0/3 |
| bogus claims on a docs-only diff | 0, 1, 3 | 0, 0, 0 |

The two rules doing the work: **quote the exact offending line verbatim or
the defect does not exist**, and **prose and documentation cannot contain a
defect**. Drop either and the fabrications come back.

The user prompt adds the **purpose-anchored method** (v7, measured
2026-08-18, `docs/evict-gap.md`): before judging a changed function's lines,
the reviewer first determines what that function is supposed to do, then
judges the lines against that purpose — silently, with its output spent on
the verdict. On an 18KB fixture this turned an inverted-comparator bug from
a 1-in-10 catch into 2-in-5 and lifted mean catches from ~3.3 to ~3.8 of 5,
with clean diffs still at zero findings across every run. Both halves of the
method line are load-bearing: the purpose-first framing is the recall, and
the "silently / spend output on the verdict" clause is what keeps the
analysis out of the thinking channel — an earlier phrasing that asked for
written notes hit the generation cap and produced no verdict at all.

Findings come back structured — `FILE: path/to/file.py:LINE | confidence`, `QUOTE:`,
`DEFECT:`, `FAILURE:` — which is what lets the script count them.

### Every run is audited

A local model will occasionally return something that reads like a review
without having been one. `review.sh` therefore always runs pi in JSON mode,
counts tool calls and structured defects, and prints them beneath the
review:

```
local-review: audit: 4/4 tool calls ok, 1 defect(s), 8672 tokens peak
```

The exit status carries the verdict, so a caller never has to parse prose:

| status | meaning |
|---|---|
| 0 | clean — the output was exactly `No findings.` |
| 4 | defects reported, all well-formed |
| 3 | the verdict cannot be trusted |
| 1 / 2 | error / usage |

A 3 covers every way a run can look clean without being one: **no tool call
succeeded** (a tool that merely *started* proves nothing), the message carrying
the verdict **did not finish** — truncated, aborted or errored — an empty
response, a half-emitted finding, or a `No findings.` with explanatory text
trailing it. A clean verdict has to be the whole output, not a phrase inside
it. Only 0 means clean. (One documented exception: a `--verify` run whose findings were ALL refuted by the verifier also exits 0 — the refuted blocks and reasons stay printed as evidence.)

Only assistant messages are read as verdicts: tool results arrive as their own
messages carrying whole file contents, and parsing those would let a source
file be returned as the review.

### The intent frame, and what it costs

When you know what the diff is supposed to do, `--intent "<one sentence>"`
folds it in as a **judging frame** rather than a note — a bolt-on "INTENT:"
preamble gets echoed and then ignored.

The catch: **the frame inherits every error in the intent's source.** It
suppresses false positives by making the intent unfalsifiable, and that
holds just as well when the intent is wrong. Use it only for a change you
made yourself and a sentence you are confident in, and skip it entirely for
someone else's stated intent.

---

## What's in the repo

| File | What it is |
|---|---|
| `scripts/review.sh` | **The entry point.** Preconditions, model load/unload, prompt assembly, and the run audit |
| `tests/test_local_review_audit.sh` | 98 assertions over the audit, the model lock, and argument validation. The code under test is extracted from `review.sh` at run time, so the tests cannot pass against a stale copy. Run with `bash tests/test_local_review_audit.sh`. Two drift checks report `SKIP` unless you also have the private repo checked out and point `LOCAL_REVIEW_MIRROR` at it — they compare this copy against its counterpart, which a standalone clone has nothing to compare to. `skipped=` in the footer is the count |
| `skill/SKILL.md` | The Claude Code skill — invocation, the intent caveat, hard limits |
| `models.example.json` | pi provider config for LM Studio (:1234) and llama-server (:8080); the template for adding your own model |
| `bench/` | The measurement instrument: seeded-defect cases, an 18KB big-diff fixture, frontier-model transcripts to score against, and the runners that replay them through the real `review.sh`. This is how you check whether a different model holds up |
| `docs/model-choice.md` | Decision record: why these models, the prompts, the settings, the harness |
| `docs/evict-gap.md` | How the purpose-anchored prompt (v7) was measured, and what it moved |
| `docs/angle-removed-behavior.md` | The removed-guard experiment behind the `removedguard` bench case |
| `docs/experiment-loop.md` | the codified loop every reviewer change goes through: pre-registered hypothesis and decision rule, bench, ship or revert |
| `docs/angle-stale-comment.md` | the stale-comment angle experiment: pre-registration, measured results, ship verdict |
| `scripts/llama_server.sh` | Serves a GGUF via llama-server on :8080 — the measured default reviewer when called bare, or any model you pass a path and flags for |
| `scripts/local_review.py` | Legacy diff-pipe: posts a diff straight to the API, no agent loop. Only useful with *thinking* models, which review diffs well but are too slow to finish agentically. Do NOT use the coder model with it — diff-blind, it fabricates findings |
| `scripts/test_local_review_scope.py` | Regression tests for the diff-pipe's review scope (untracked files, empty repos) |

## Hard rules (each one was paid for)

- **The model is a recommendation; these are the scores behind it.** Nothing
  in the script enforces a model — the defaults are simply the two that
  survived measurement, and `bench/` will score whatever you swap in. The
  bench/ seeded-defect eval (2026-08-18, both engines) scored Qwen3-Coder
  6/8 trusted catches (zero false positives under the shipped prompt; two mid-iteration prompt variants did produce clean-diff fabrications) at ~5s a review; it reliably
  misses the hardest case (a swallowed error path causing silent data loss).
  **Qwen3.8-27B** caught 31/32 with zero false positives — and stays that
  accurate on llama-server with thinking disabled (`--reasoning-budget 0`),
  ~100s a review. Big-diff validated (18KB fixture, 2026-08-18):
  no-think completes in 9-15 min with real findings and zero fabrications,
  while Qwen3-Coder false-cleaned the same diff twice in ~20s — use the
  accuracy pick for anything beyond a small diff. **Devstral Small 2 24B**: 5/8 strict, same
  hard-case blindness plus intermittent leak misses; its 2512 GGUFs do not
  load on llama.cpp stable 10450. **GLM-4.7-Flash** fabricates
  plausibly-quoted findings and wedged the MLX engine; disqualified. A 9B
  produces slop.
- **Thinking cannot be limited through LM Studio.** Probed against its OpenAI
  endpoint: `chat_template_kwargs.enable_thinking`, a top-level
  `enable_thinking`, and `reasoning_effort` are all accepted and all ignored.
  pi does not send a level either unless the provider declares a
  `thinkingFormat` or `supportsReasoningEffort: true`. Seeing thinking blocks
  in the event stream proves thinking happened, not that a level was honoured.
- **Leave LM Studio guardrails on Strict.**
- **Review diffs, not whole files.** Pointed at committed files with no
  diff anchor, the reviewer fabricated 7/7 findings. If you must audit
  whole files, supply a component map + behavioral contract in the prompt
  and ask it to judge against that contract.
- **No OS sandbox in pi.** `--exclude-tools edit,write` removes the
  mutation tools, but bash can still write. Review diffs you wrote, not
  diffs you downloaded — or use `codex exec --sandbox read-only` as the
  enforced-read-only alternative harness.
- **Never download large models while a server holds weights** —
  page-cache eviction cut prompt ingestion from 380 to 8 tok/s.
- **After a reboot**, the model may load while the API server stays down:
  `lms server status` / `lms server start`. A dead server shows up in pi
  as a bare "Connection error."

## Trying a different model

Serve it, declare it, run the bench against it:

```bash
scripts/llama_server.sh ~/models/your-model.gguf        # or load it in LM Studio
# add a matching entry to ~/.pi/agent/models.json, then:
scripts/review.sh --provider llamaserver --model your-model-id

# score it: PROVIDER MODEL RUNS LABEL
bench/run_eval.sh    llamaserver your-model-id 2 yourmodel   # 5 seeded one-bug diffs
bench/run_bigdiff.sh llamaserver your-model-id 2 yourmodel   # the 18KB fixture
```

Results append to `bench/results.tsv` and `bench/results-bigdiff.tsv`, with the
full transcripts under `bench/logs/`. Read `bench/README.md` before judging the
numbers — the `clean` case measures fabrication, and the big-diff run is the
one that separates a model that reviews from a model that agrees.

Two things to hold onto whatever you serve: `--parallel 1` (pi is a single
client, and parallel slots split the context N ways), and the round cap, which
is a stability guard rather than a speed knob.

## Context sizing — a suggestion, not a rule

49152 is the default because it is the size every accuracy number was
measured at — use whatever works on your machine. Data points to judge by:
on llama-server with Qwen3.8, 96K measured 31.5 GB wired at peak on a 48 GB
Mac (`LLAMA_CTX=98304 scripts/llama_server.sh`, plus a matching
`contextWindow` in `~/.pi/agent/models.json`); prefill on a full 96K window
runs ~8 minutes; review accuracy above 49152 is unmeasured. On MLX/LM
Studio our one 96K attempt wired ~35 GB and kernel-panicked the machine,
so we keep MLX at 49152 ourselves.

## License

MIT — see [LICENSE](LICENSE).
