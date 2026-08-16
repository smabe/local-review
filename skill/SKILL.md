---
name: local-review
description: Run a free, private code review on a local LLM (Qwen3-Coder-30B via LM Studio) using the pi agent harness. Advisory pre-pass only — it never replaces the real review gate. Use when the user asks for a local review, a free second opinion on a diff, or offline review.
---

# local-review — code review on a local model

Advisory reviewer running entirely on this machine. Its blind spots are
uncorrelated with cloud reviewers'; it does NOT replace them.

## Run it

```bash
cd <repo> && pi --provider lmstudio --model "qwen/qwen3-coder-30b" \
  --no-session -nc -ns --exclude-tools edit,write \
  -p "<review prompt>" </dev/null
```

The flags are the speed win: `-nc` skips AGENTS.md/CLAUDE.md loading, `-ns`
skips skills, `--no-session` skips session writes. Do not feed the reviewer
a project's AGENTS.md — workflow rules aimed at an implementing agent add
no correctness content and triple the prompt ingestion time.

The prompt MUST contain a hard round cap (stability-critical on the MLX
engine — long single generations around 11K tokens crash it):

> Review the uncommitted changes in this repository for correctness bugs.
> HARD BUDGET: at most 3 rounds of tool calls, then give your verdict with
> whatever you have — batch commands (round 1: git status && git diff HEAD;
> round 2: read the changed files). Report findings as 'file:line — defect,
> concrete failure scenario', most severe first. If nothing is wrong, say
> exactly 'No findings.'

When the diff's intent is known (it usually is — the session invoking this
skill made the change), fold it in as the JUDGING FRAME, not a note.
A bolt-on "INTENT: ..." preamble gets echoed and ignored; this phrasing
kills intended-change false positives while still catching real bugs:

> ... judging every change AGAINST THIS INTENT: <one sentence>. A change
> that implements the stated intent is correct by definition; do not
> report it. Report only defects that contradict the intent or are
> unrelated to it.

## Preconditions (check, don't assume)

1. Model loaded: `~/.lmstudio/bin/lms ps` shows `qwen/qwen3-coder-30b`.
   If not: `~/.lmstudio/bin/lms load "qwen/qwen3-coder-30b" --yes --context-length 49152`
2. API server up: `~/.lmstudio/bin/lms server status` — after a reboot the
   model can be loaded while the server is down (`lms server start`). A
   dead server surfaces in pi as a plain "Connection error."
3. Feed stdin `</dev/null` when scripting.
4. Untracked files are invisible to `git diff HEAD` — tell the reviewer to
   enumerate them (`git status --short` / `git ls-files --others
   --exclude-standard`) and read them directly. Never `git add -N` from an
   advisory review; it mutates the index.

## Hard limits (measured, not guessed)

- **Review DIFFS.** Whole-file audits fabricate (measured: 7/7 false
  positives on committed files with no diff anchor) unless the prompt
  supplies a component map + behavioral contract to judge against.
- **No OS sandbox.** `--exclude-tools edit,write` drops the mutation tools
  but bash can still write. For untrusted diffs use a harness with
  enforced read-only (e.g. `codex exec --sandbox read-only`).
- **Model choice is fixed: Qwen3-Coder-30B-A3B.** Thinking models overflow
  the context in any local harness (measured: DNF); small models produce
  slop reviews.
- **Context stays at 49152.** Bigger KV caches have kernel-panicked a
  48 GB machine. Keep LM Studio guardrails on Strict.

## Fallback engine — llama-server (GGUF)

If the MLX engine misbehaves: `scripts/llama_server.sh` serves a Q6 GGUF
on :8080 (~25% slower, zero crashes observed). Point pi at it with a
second provider entry (`baseUrl: http://localhost:8080/v1`, model id
`local-reviewer`).
