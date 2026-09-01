# MTPLX as a served engine for the Qwen3.8 reviewer

Status: registered 2026-09-01. The thinking-off rows below were run BEFORE this
file existed and are kept as the evidence that forced it; the thinking-on arm
is the pre-registered one. Nothing above "Measured results" is edited after
that arm's first run.

## The change

[MTPLX](https://github.com/youssofal/MTPLX) serves Qwen3.8-27B on Apple
Silicon with native multi-token-prediction decoding at roughly twice
llama-server's tokens per second. It is wired as a third `review.sh` provider
(`--provider mtplx`, `models.example.json` block `mtplx`), probed at
`:8000/v1/models`, model owned by the MTPLX app or `mtplx quickstart`. This
file is the single home for what was probed and measured; README, CLAUDE.md
and SKILL.md carry one sentence each and point here.

## What was probed (2026-09-01, MTPLX v2.10.2, pack Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed)

| control | effect |
|---|---|
| `chat_template_kwargs.enable_thinking: false` (request body) | 0 reasoning tokens |
| top-level `enable_thinking: false` | 0 reasoning tokens |
| nothing sent | thinks (MTPLX `--reasoning auto`) |
| `model` field of the request | ignored; one daemon serves one model, any id answers |
| `x-mtplx-tool-prompt-mode: native` header | MTPLX resolves the tool prompt mode as `native`, source `request`, above the `hybrid` it forces for a client identifying as pi |
| `mtplx settings set tool_prompt_mode=…` | "nothing to apply" — not live-settable; the header is the only per-run control |

pi 0.84.2 `Object.assign`s `samplingParams` into the request body last, so a
`chat_template_kwargs` key there reaches MTPLX verbatim. MTPLX writes
`thinkingFormat: "qwen"` into the provider's compat block and re-syncs it on
every `mtplx start pi`; under that format pi sends `enable_thinking` and
`reasoning_effort` only for a model whose entry has `reasoning: true`, and
pi's default level with no `--thinking` flag is `medium`.

`mtplx start pi` also prunes any `mtplx-`-prefixed model id it did not write,
so the repo's alias is `qwen38-mtplx`, no prefix.

## The gap this closes

The first entry (`qwen38-mtplx-nothink`) pinned thinking off, on the belief
that this matched the measured llama-server arm. It does not:
`docs/thinking-off.md` shows `--reasoning-budget 0` is inert and the measured
arm thinks on every run, and that the per-request thinking-off control
(`qwen38-ctk-nothink`) collapses the reviewer — the model re-issues one
computation until the watchdog. On MTPLX the same control reproduced that
signature on a large diff:

| run (thinking OFF, `qwen38-mtplx-nothink`) | outcome |
|---|---|
| 48 KB working-tree diff, `--rounds 4`, tool prompt mode `hybrid` | 99 tool calls, 23 min, killed at 47K tokens, exit 3 |
| same diff, `--rounds 3`, tool prompt mode `native` | 96 tool calls, 18 min, exit 3 |
| pi probe "Run: echo probe-ok" | the identical bash call re-issued 21 times before answering |
| `bench/results.tsv` label `mtplx-native`, 1 run | offbyone caught (17 s), swallow caught (22 s), clean 0 findings (7 s); 3-4 calls each; one extra medium/low finding per bug case |

So thinking-off on MTPLX survives the seeded small cases (unlike llama-server,
where the same control watchdog-killed them) but fails the way the experiment
predicted as soon as the diff is large. The tool prompt mode was a red herring
for that failure; the header is kept only because `hybrid` injects MTPLX's own
agent contract over the reviewer prompt.

## Hypothesis

With thinking ON (`qwen38-mtplx`: `reasoning: true`, the measured arm's four
sampler keys, `maxTokens` 8192, no `chat_template_kwargs`), MTPLX reproduces
the measured llama-server composition on the seeded cases at a fraction of the
wall time, and does not run away on a large diff.

## Arms

| arm | label | runs |
|---|---|---|
| seeded cases `offbyone swallow boolean leak clean` | `mtplx-think` | 1, then a second run if the first passes |
| the 48 KB working-tree diff that broke thinking-off | ad hoc, transcript kept under `bench/logs/` | 1 |
| bigdiff fixture | `mtplx-think` via `run_bigdiff.sh` | blocked on this machine: the fixture bootstrap commit is refused by the machine-wide commit-review git hook |

Baselines: llama-server `qwen38-nothink-bold` rows (2026-08, thinking on,
exactly one finding per bug case, clean 0).

## Decision rule (pre-registered)

KEEP the thinking-on entry as the documented MTPLX option (still not the
shipped default; that stays llama-server) iff, on the seeded arm:

1. `clean` reports 0 findings.
2. every planted line is quoted (`found` = 1 on all four bug cases).
3. every run finishes within the 3-round budget (`N/N tool calls ok`, N ≤ 4,
   exit 4 or 0, never 3 or 124).

Report separately, without gating on it: extra findings beyond the planted
line (the llama-server baseline has none), and whether the 48 KB diff
completes. REVERT to "unmeasured, use at your own risk" wording if any clause
fails.

## Measured results (2026-09-01, `qwen38-mtplx`, thinking on, 3 runs per case)

`bench/results.tsv` label `mtplx-think`; transcripts under `bench/logs/`.

| case | run 1 | run 2 | run 3 | llama-server baseline (`qwen38-nothink-bold`) |
|---|---|---|---|---|
| `offbyone` | caught, 23 s | caught, 30 s | caught, 17 s | caught 2/2 |
| `boolean` | caught, 16 s | caught, 17 s | caught, 19 s | — |
| `leak` | caught, 29 s | caught, 33 s | **missed**, 15 s | caught |
| `swallow` | **missed**, 19 s | **missed**, 15 s | **missed**, 17 s | caught 2/2 |
| `clean` | 0 findings, 16 s | 0 findings, 26 s | 0 findings, 15 s | 0 findings 2/2 |

Every catch was exactly one finding on the planted line — the thinking-off
arm's extra medium/low findings did not recur. Tool calls per run: 2-4,
except `clean` run 2 at 6 (one failed). Wall time 15-33 s a case against
126-273 s for the llama-server rows.

The 48 KB working-tree diff that ran away twice thinking-off: **completed**,
19 tool calls, 46.6K tokens peak, 7.5 min. The verdict was `No findings.`
preceded by a paragraph of prose, which the audit refuses (exit 3, "neither a
clean verdict nor well-formed findings") — the known trailing/leading-prose
failure the audit exists for, not a runaway.

### Verdict: clause 2 FAILS (`swallow` 0/3, `leak` 2/3); clause 3 fails once (6 calls). REVERT the accuracy wording.

What stands: thinking on is the right MTPLX configuration (composition matches
llama-server's one-finding-per-bug shape, no extras, no runaway, ~8x faster).
What does not: it is measurably less accurate than the llama-server rows on
the two hard cases, so it is documented as a fast engine option, not the
accuracy pick. The `mtplx-native` (thinking-off) rows caught `swallow` 1/1
with an extra finding — one run, and the configuration that runs away on
large diffs, so it is not a counter-argument.

Open follow-ups, not decided here: the bigdiff fixture arm (blocked by the
machine-wide commit gate refusing the fixture's bootstrap commit), and
whether MTPLX's `reasoning_effort` above `medium` recovers `swallow`.

## Arm 2: reasoning effort `low` (registered 2026-09-01, before any run)

Entry `qwen38-mtplx-low`: identical to `qwen38-mtplx` plus
`samplingParams.reasoning_effort: "low"`, which pi merges last and so
overrides the `medium` it sends by default (probe-confirmed in MTPLX's
`/metrics`: `request_reasoning_effort: low`). `xhigh` was ruled out by the
operator as too much for this model.

Hypothesis: less deliberation changes composition on the two hard cases in
some direction; the arm exists to measure it, not to argue for it.

Arm: `bench/run_eval.sh mtplx qwen38-mtplx-low 3 mtplx-think-low`, same five
cases, compared row for row with `mtplx-think`.

Decision rule: `low` REPLACES `medium` as the documented MTPLX entry iff
`clean` stays at 0 findings on all runs AND its catches are a superset of
`mtplx-think`'s on every case (no case loses a catch, at least one gains).
Otherwise `medium` stays and the rows are kept as evidence.

### Measured results (2026-09-01, `mtplx-think-low`, 3 runs per case)

| case | low, runs 1-3 | medium (`mtplx-think`), runs 1-3 |
|---|---|---|
| `offbyone` | caught, caught, caught (44 / 30 / 32 s) | caught 3/3 |
| `boolean` | caught, caught, caught (19 / 22 / 31 s) | caught 3/3 |
| `leak` | caught, **missed**, **missed** (45 / 34 / 31 s) | caught 2/3 |
| `swallow` | **missed** x3 (21 / 36 / 36 s) | missed 3/3 |
| `clean` | 0 findings x3 (28 / 14 / 23 s) | 0 findings 3/3 |

One finding per catch, never an extra; 2-5 tool calls per run. Wall time was
not lower at `low` (14-45 s against 15-33 s) — less deliberation did not buy
speed on these cases.

### Verdict: NOT a superset — `leak` drops from 2/3 to 1/3, `swallow` stays at 0. `medium` stays as the documented entry.

The `qwen38-mtplx-low` entry is removed from `models.example.json`; the rows
stay. Effort is not the lever for the hard cases in either direction the
operator was willing to try (`xhigh` ruled out as too much for this model).
