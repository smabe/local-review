# local-review

A free, private, offline code reviewer that runs on your own Mac:
**Qwen3.8-27B with thinking disabled**, served by llama-server and driven
by the [pi](https://github.com/earendil-works/pi) agent harness. It runs
`git diff`, reads your changed files, and reports correctness bugs —
about a minute on a small diff, up to ~15 minutes on a large one — touching
no network. A second tier, **Qwen3-Coder-30B** on LM Studio, reviews a
small diff in ~5 seconds but false-cleans large ones (measured — see
`bench/`); use it only when the diff is small and the clock matters.

It is an **advisory pre-pass**, not a replacement for a frontier-model
review: its blind spots are real but *uncorrelated* with the big models',
which is exactly what makes a second opinion worth having. A false
positive costs you a minute of reading; a false negative costs nothing if
a real review still gates your commits.

**Requirements:** Apple Silicon Mac with ~32 GB+ unified memory (the model
takes ~23 GB), Node.js/npm, llama.cpp (`brew install llama.cpp`).
[LM Studio](https://lmstudio.ai) only if you want the fast tier.

---

## Setup — instructions for a coding agent

> If you are a coding agent (Claude Code, etc.) setting this up for your
> user: follow these steps in order. Every step has a verification
> command — do not proceed past a failing check. Total time is ~20
> minutes, dominated by a ~21 GB model download.

### 1. Serve the model

```bash
# Download the reviewer GGUF (~21 GB, one time)
mkdir -p ~/models && curl -L -o ~/models/Qwen3.8-27B-Q6_K.gguf \
  "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-Q6_K.gguf"

# Serve it on :8080. The script finds the GGUF, defaults context to 49152
# (raise via LLAMA_CTX if that suits your machine -- see Context sizing),
# and disables thinking, which is the measured reviewer configuration.
scripts/llama_server.sh
```

Verify: `curl -s http://localhost:8080/health` returns `{"status":"ok"}`.

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

One machine has one resident model, so reviews are serialised: a run holds a
lock for its whole duration, and a second run started while it is held exits
immediately naming the process that holds it.

Verify: in a repo with a deliberate bug, the script reports it as
`FILE: path/to/file.py:LINE | confidence: ... / QUOTE: ... / DEFECT: ... / FAILURE: ...`
followed by an audit line reading `audit: N tool call(s), 1 defect(s)`.

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
batch commands") which is **stability-critical**: LM Studio's MLX engine
crashes on long single generations (~11K tokens). Capped rounds plus
`maxTokens: 8192` keep every generation under the threshold.

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

Findings come back structured — `FILE: path/to/file.py:LINE | confidence`, `QUOTE:`,
`DEFECT:`, `FAILURE:` — which is what lets the script count them.

### Every run is audited

A local model will occasionally return something that reads like a review
without having been one. `review.sh` therefore always runs pi in JSON mode,
counts tool calls and structured defects, and prints them beneath the
review:

```
local-review: audit: 4 tool call(s), 1 defect(s), 8672 tokens peak
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
it. Only 0 means clean.

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
| `tests/test_local_review_audit.sh` | 60+ assertions over the audit, the model lock, and argument validation. The code under test is extracted from `review.sh` at run time, so the tests cannot pass against a stale copy. Run with `bash tests/test_local_review_audit.sh`. Two drift checks report `SKIP` unless you also have the private repo checked out and point `LOCAL_REVIEW_MIRROR` at it — they compare this copy against its counterpart, which a standalone clone has nothing to compare to. `skipped=` in the footer is the count |
| `skill/SKILL.md` | The Claude Code skill — invocation, the intent caveat, hard limits |
| `models.example.json` | pi provider config for LM Studio (:1234) and llama-server (:8080) |
| `docs/model-choice.md` | Decision record: why this model, the prompts, the settings, the harness |
| `scripts/llama_server.sh` | Serves the default reviewer (Qwen3.8 GGUF, thinking off) via llama-server on :8080; pass a path + flags for anything else |
| `scripts/local_review.py` | Legacy diff-pipe: posts a diff straight to the API, no agent loop. Only useful with *thinking* models, which review diffs well but are too slow to finish agentically. Do NOT use the coder model with it — diff-blind, it fabricates findings |
| `scripts/test_local_review_scope.py` | Regression tests for the diff-pipe's review scope (untracked files, empty repos) |

## Hard rules (each one was paid for)

- **Model: Qwen3.8-27B no-think default; Qwen3-Coder-30B fast tier.** The
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
