# local-review

A free, private, offline code reviewer that runs on your own Mac:
**Qwen3-Coder-30B** served by LM Studio, driven by the
[pi](https://github.com/earendil-works/pi) agent harness. It runs
`git diff`, reads your changed files, and reports correctness bugs in
~3–15 seconds per review, touching no network.

It is an **advisory pre-pass**, not a replacement for a frontier-model
review: its blind spots are real but *uncorrelated* with the big models',
which is exactly what makes a second opinion worth having. A false
positive costs you a minute of reading; a false negative costs nothing if
a real review still gates your commits.

**Requirements:** Apple Silicon Mac with ~32 GB+ unified memory (the model
takes ~25 GB), Node.js/npm, [LM Studio](https://lmstudio.ai).

---

## Setup — instructions for a coding agent

> If you are a coding agent (Claude Code, etc.) setting this up for your
> user: follow these steps in order. Every step has a verification
> command — do not proceed past a failing check. Total time is ~20
> minutes, dominated by a ~18 GB model download.

### 1. Serve the model

```bash
# Download (skip if `lms ls` already shows it)
~/.lmstudio/bin/lms get qwen/qwen3-coder-30b

# Load with a BOUNDED context — do not raise this, see Hard rules
~/.lmstudio/bin/lms load "qwen/qwen3-coder-30b" --yes --context-length 49152

# Start the OpenAI-compatible API server on :1234
~/.lmstudio/bin/lms server start
```

Verify: `curl -s http://localhost:1234/v1/models` lists
`qwen/qwen3-coder-30b`.

### 2. Install pi and configure the provider

```bash
npm install -g @earendil-works/pi-coding-agent
pi --version   # expect >= 0.84
mkdir -p ~/.pi/agent
```

Copy [`models.example.json`](models.example.json) from this repo to
`~/.pi/agent/models.json`. If the user already has a `models.json`, merge
the `lmstudio` provider block into it instead of overwriting. Do not add
JSON comments — they fail silently.

Verify (first call wakes the model and can take ~60s; a repeat should
round-trip in 1–2s):

```bash
pi --provider lmstudio --model "qwen/qwen3-coder-30b" \
   --no-session -nc -ns -p "Reply with exactly: OK" </dev/null
```

### 3. Install the skill (Claude Code users)

```bash
mkdir -p ~/.claude/skills/local-review
cp skill/SKILL.md ~/.claude/skills/local-review/SKILL.md
cp -R scripts ~/.claude/skills/local-review/scripts
```

Done. "Run a local review" in any session now triggers it. Non-Claude
users: just use the command and prompt from the skill file directly.

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

### The prompts

Standard review:

> Review the uncommitted changes in this repository for correctness bugs.
> HARD BUDGET: at most 3 rounds of tool calls, then give your verdict with
> whatever you have — batch commands (round 1: git status && git diff HEAD;
> round 2: read the changed files). Report findings as 'file:line —
> defect, concrete failure scenario', most severe first. If nothing is
> wrong, say exactly 'No findings.'

When you know what the diff is supposed to do, add the intent as a
**judging frame** — measured to kill intended-change false positives while
still catching real bugs next to them (a bolt-on "INTENT:" note does NOT
work; the model echoes it and flags the change anyway):

> ... judging every change AGAINST THIS INTENT: \<one sentence\>. A change
> that implements the stated intent is correct by definition; do not
> report it. Report only defects that contradict the intent or are
> unrelated to it.

---

## What's in the repo

| File | What it is |
|---|---|
| `skill/SKILL.md` | The Claude Code skill — invocation, prompts, preconditions, hard limits |
| `models.example.json` | pi provider config for LM Studio (:1234) and llama-server (:8080) |
| `scripts/llama_server.sh` | Fallback engine: serves a Qwen3-Coder GGUF via llama-server on :8080 — ~25% slower than MLX, zero crashes observed |
| `scripts/local_review.py` | Legacy diff-pipe: posts a diff straight to the API, no agent loop. Only useful with *thinking* models, which review diffs well but cannot survive any local agent harness. Do NOT use the coder model with it — diff-blind, it fabricates findings |
| `scripts/test_local_review_scope.py` | Regression tests for the diff-pipe's review scope (untracked files, empty repos) |

## Hard rules (each one was paid for)

- **Model: Qwen3-Coder-30B-A3B, nothing else** for the agentic path.
  Thinking models overflow the context in any local harness (measured:
  DNF). A 9B produces slop. Newer Qwen3.6 models need a thinking-off
  chat-template flag that LM Studio silently drops.
- **Context stays at 49152.** A 96K attempt wired ~35 GB of memory and
  kernel-panicked a 48 GB machine. Leave LM Studio guardrails on Strict.
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

## License

MIT — see [LICENSE](LICENSE).
