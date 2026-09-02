# local-review

A free, private, offline code reviewer that runs on your own machine. It
drives a local model — anything you can serve on an OpenAI-compatible
endpoint: llama-server, [MTPLX](https://github.com/youssofal/MTPLX), or LM
Studio — through the
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
  "https://huggingface.co/lmstudio-community/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-Q6_K.gguf"

# Serve it on :8080. The script serves the default GGUF, defaults context to 49152
# (raise via LLAMA_CTX if that suits your machine -- see Context sizing),
# and passes --reasoning-budget 0 -- which is inert on the measured build, so the
# reviewer thinks (docs/thinking-off.md); that IS the measured configuration.
scripts/llama_server.sh
```

Verify: `curl -s http://localhost:8080/health` returns `{"status":"ok"}`.

Serving a different model instead: pass its path and any flags it needs —
`scripts/llama_server.sh ~/models/your-model.gguf --whatever` — and add a
matching entry to `~/.pi/agent/models.json` (step 2). The script never
substitutes a model silently: with no path it serves the default named in
`DEFAULT_MODEL`, and if that file is absent it falls back to discovery — which
lists the candidates and stops rather than guess when it finds more than one,
since quants of one model differ in measured accuracy.

Optional fast tier (small diffs only), via LM Studio:

```bash
~/.lmstudio/bin/lms get qwen/qwen3-coder-30b
~/.lmstudio/bin/lms server start
# review.sh loads and unloads this model for you when you pass:
#   --provider lmstudio --model qwen/qwen3-coder-30b
```

Optional: the same Qwen3.8-27B through [MTPLX](https://github.com/youssofal/MTPLX)
(MLX with native multi-token-prediction decoding, roughly twice llama-server's
tokens per second on the same machine). Load the
`Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed` pack in the MTPLX app and press
play, or run `mtplx quickstart --port 8000`; the daemon owns the model, so
review.sh only checks that `:8000/v1/models` answers:

```bash
scripts/review.sh --provider mtplx --model qwen38-mtplx
# or, to make it this machine's default:
export LOCAL_REVIEW_PROVIDER=mtplx LOCAL_REVIEW_MODEL=qwen38-mtplx
```

The `qwen38-mtplx` entry runs thinking ON, like the measured llama-server arm
actually does (`docs/thinking-off.md`); a thinking-off variant reproduced that
experiment's runaway on a large diff. Measured (`docs/mtplx.md`, 3 runs per
seeded case): `offbyone` and `boolean` 3/3, `leak` 2/3, `swallow` 0/3,
`clean` 0 findings 3/3, one finding per catch and never more, 15-33 s a case
against 126-273 s on llama-server. Faster and less accurate on the hard
cases, so it is a documented engine option, not the accuracy pick. The id is
a local alias (MTPLX ignores the request's `model` field) and must not start
with `mtplx-`, which `mtplx start pi` prunes on re-sync.

### 2. Install pi and configure the provider

```bash
npm install -g @earendil-works/pi-coding-agent
pi --version   # expect >= 0.84
mkdir -p ~/.pi/agent
```

Copy [`models.example.json`](models.example.json) from this repo to
`~/.pi/agent/models.json`. If the user already has a `models.json`, merge
the provider blocks into it instead of overwriting. Do not add
JSON comments — they fail silently, and so does a stray paste: pi ignores
an unparseable `models.json` and every custom provider with it, so
check it with `python3 -m json.tool ~/.pi/agent/models.json`.

Any other model gets an entry alongside these, under whichever of the
three providers serves it, and is then selected with `--provider` / `--model`.
The id must match what the server actually answers to (MTPLX is the
exception: it ignores the field, so its id is a local alias): pi forwards an
id its provider never declared without complaining, and the per-model sampling
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
| `--provider NAME` | `llamaserver` (default), `mtplx`, or `lmstudio`. `LOCAL_REVIEW_PROVIDER` in the environment changes the default |
| `--model ID` | model id as declared in `~/.pi/agent/models.json`; required whenever `--provider` is not the default. `LOCAL_REVIEW_MODEL` in the environment changes the default and counts as explicit |

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

Three personas now ship, each a full system prompt of its own, never a
mode-flag on a shared one:

- **The reviewer** (default, and under `--intent`): the measured
  anti-fabrication scaffold below, plus the v7 purpose-anchored Method line
  (docs/evict-gap.md).
- **The stale-comment angle** (`--angle stalecomment`): the same scaffold
  shape with rule 2 inverted — comments and docstrings the changed code
  contradicts become the ONLY reportable class, anchored on the comment line
  (docs/angle-stale-comment.md).
- **The verifier** (`--verify`): given one finding, it must either construct
  a refutation from the code — a quoted line, guard, or language rule — or
  return "real"; unsure keeps the finding. Byte-identical between review.sh
  and the bench, enforced by the test suite (docs/verifier-pass.md).

The two rules doing the work in the reviewer scaffold: **quote the exact offending line verbatim or
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
| `tests/test_local_review_audit.sh` | The audit, the model lock, and argument validation. The code under test is extracted from `review.sh` at run time, so the tests cannot pass against a stale copy. Run with `bash tests/test_local_review_audit.sh`. Two drift checks report `SKIP` unless you also have the private repo checked out and point `LOCAL_REVIEW_MIRROR` at it — they compare this copy against its counterpart, which a standalone clone has nothing to compare to. `skipped=` in the footer is the count |
| `tests/test_bench_runners.sh` | The second gate: the bench runners, which produce the evidence behind every model decision here. Runs whole batches against a shell stub, so no model is ever loaded and nothing writes into the real `bench/`. Run with `bash tests/test_bench_runners.sh`; it skips wholesale in a checkout without `bench/` |
| `skill/SKILL.md` | The Claude Code skill — invocation, the intent caveat, hard limits |
| `models.example.json` | pi provider config for llama-server (:8080), MTPLX (:8000) and LM Studio (:1234); the template for adding your own model |
| `bench/` | The measurement instrument: seeded-defect cases, an 18KB big-diff fixture, frontier-model transcripts to score against, and the runners that replay them through the real `review.sh`. This is how you check whether a different model holds up |
| `docs/model-choice.md` | Decision record: why these models, the prompts, the settings, the harness |
| `docs/evict-gap.md` | How the purpose-anchored prompt (v7) was measured, and what it moved |
| `docs/angle-removed-behavior.md` | The removed-guard experiment behind the `removedguard` bench case |
| `docs/experiment-loop.md` | the codified loop every reviewer change goes through: pre-registered hypothesis and decision rule, bench, ship or revert |
| `docs/angle-stale-comment.md` | the stale-comment angle experiment: pre-registration, measured results, ship verdict |
| `docs/angle-stale-removal.md` | removal-shaped staleness: the shipped angle covers it 3/3; the default pass reproduces the motivating miss |
| `docs/verifier-pass.md` | the verifier capability probe: 14/14 retention, 8/8 refutation on a 13-item corpus |
| `docs/verify-flag.md` | the `--verify` wiring: design, decision rule, post-ship hardening, measured results |
| `docs/rounds-experiment.md` | `--rounds 6` on the big diff: no ship — the 3-round cap stands on merit |
| `docs/bold-finder-experiment.md` | relaxing unsure-omit under `--verify`: no ship (a trade), and the discovered `rename_prefix` bug |
| `docs/mtplx.md` | MTPLX as a served engine: every probe, the thinking-off runaway that forced a thinking-on entry, the bench arms and decision rule |
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
  accurate on llama-server served with `--reasoning-budget 0` — a flag that is
  inert on the measured build, so the reviewer thinks and must keep thinking
  (`docs/thinking-off.md`: genuinely off, it re-issues one command until the
  watchdog and loses every catch) — ~100s a review. Big-diff validated (18KB fixture, 2026-08-18):
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
- **MTPLX does honour the request-level thinking switch**, which is why the
  `qwen38-mtplx` entry leaves it ON: pinning it off reproduced the
  thinking-off collapse on a large diff. Probes and rows: `docs/mtplx.md`.
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
scripts/llama_server.sh ~/models/your-model.gguf        # or load it in LM Studio / MTPLX
# add a matching entry to ~/.pi/agent/models.json, then:
scripts/review.sh --provider llamaserver --model your-model-id   # or --provider mtplx / lmstudio

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
