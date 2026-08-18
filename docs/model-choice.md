# Why Qwen3.8-27B (thinking off) is the default reviewer

Decision record, 2026-08-18. Everything numeric here is reproducible from
`bench/` (`results.tsv` for the per-run rows, `run_eval.sh` to rerun an arm);
nothing is anticipated or remembered from a model card.

## The decision

**Default: Qwen3.8-27B Q6_K on llama-server with thinking disabled**
(`--reasoning-budget 0 --reasoning-format deepseek`), pi id
`qwen38-gguf-nothink`. `scripts/llama_server.sh` serves exactly this with no
arguments.

**Fast tier, small diffs only: Qwen3-Coder-30B-A3B** on LM Studio
(`--provider lmstudio --model qwen/qwen3-coder-30b`), ~5 s a review.

A diff-size threshold that auto-routes between the two was considered and
deliberately **not** built yet — the split is documented instead, and the
threshold stays on the table for when the two-tier workflow proves annoying
in practice.

## The evidence

The bench plants four bugs (off-by-one slice, swallowed `OSError` causing
silent data loss, inverted validation, leaked file handle) plus one genuinely
clean refactor that measures fabrication, and replays them through
`scripts/review.sh` itself — so every number includes the prompt, the audit,
and the engine, not the model in isolation. A catch counts only when the
model quoted the planted line *and* the audit trusted the output.

| Model (best measured arm; prompt version noted) | Catches | Clean diff | Median |
|---|---|---|---|
| Frontier baseline (Claude agents, same contract) | 8/8 | passed | ~18 s |
| **Qwen3.8-27B no-think, llama-server** (v3–v5) | **8/8** | passed | 92–138 s |
| Qwen3.8-27B thinking, LM Studio MLX (v3) | 8/8 | passed | 145 s |
| Qwen3-Coder-30B, either engine (v3/v6) | 6/8 | passed | 5 s |
| Devstral Small 2 24B, MLX only (v3) | 5/8 | passed | 13 s |
| GLM-4.7-Flash gguf-nothink (v3) | 5/8, +1 fabricated finding on a defect case | passed | 5 s |

Qwen3.8 no-think scored 31/32 across the four prompt versions (8/8 under
v3, v4, and v5; 7/8 under the shipped v6, where one leak run false-cleaned —
a single-run miss, within the eval's n=2 noise) with zero fabrications
anywhere. Only Qwen3.8 and the frontier baseline catch the
swallowed-error/data-loss case, which is precisely the bug class a reviewer
is for. GLM's fabrication was a plausibly-quoted non-bug (a real `with
open()` line accused of leaking); its MLX arm separately produced zero
trusted verdicts and wedged the engine — the two engines' failures are
listed separately in the eliminations below.

**The big-diff validation settled the default.** On an 18.3 KB, 7-file
refactor (three seeded bugs plus, accidentally, two real ones — fixture,
verdicts, and method in `bench/bigdiff/`):

- Qwen3.8 no-think completed both runs (9.3 and 14.7 min) with 3–4 findings
  per run, **all real, zero fabrications** — including both accidental bugs.
  Its historical 19 KB stall was a thinking-mode failure and does not
  reproduce with thinking off.
- Qwen3-Coder read all seven files (10/10 tool calls) and answered
  **"No findings." — twice, in ~20 s.** A false clean at exactly the scale
  where review matters is the worst possible failure under this tool's
  "only exit 0 means clean" contract, and is why it lost the default despite
  the 20× speed advantage.

Eliminations: **GLM-4.7-Flash** fabricated a plausibly-quoted finding (a real
line with wrong reasoning about it — the class no mechanical quote check can
catch) and separately wedged LM Studio's MLX engine mid-generation for half
an hour. **Devstral Small 2** missed the same hard case plus intermittent
leak misses, and its 2512 GGUFs do not load on llama.cpp stable 10450
(`invalid gguf type for tokenizer.ggml.scores` from two independent
conversions) — worth a retry after a llama.cpp bump.

## Why thinking is OFF for a thinking model

Measured, not assumed: no-think matched thinking-mode accuracy (8/8 both) at
~40% less latency, and bounded generations are what eliminate the long-diff
stall. Thinking control is also the reason the default engine is
llama-server: LM Studio accepts `chat_template_kwargs.enable_thinking` and
silently ignores it (probed twice, different models), while llama-server
honors `--reasoning-budget` and splits any residual reasoning out of the
message with `--reasoning-format deepseek`, so the audit only ever sees the
verdict text.

## The prompts

The system prompt (in `scripts/review.sh`) replaces pi's coding-assistant
persona. Rules 1–5 are the original measured anti-fabrication set — dropping
rule 1 (verbatim quote) or rule 2 (prose cannot contain a defect) brings
fabrications back, 3 runs per arm. Rules 6–9 came out of this bake-off's
research pass: diff-scoping with the `-`-lines warning, style exclusion,
read-the-enclosing-function, and discard-self-refuted-findings. The worked
example plus "keep every value on the same line as its label" is what took
format failures from the dominant error class to zero — the single biggest
measured gain of the whole exercise was fixing our own ambiguous
`FILE:LINE` template, which literal-minded models were copying as
`FILE:37`.

Two prompt lessons that cost real runs:

- **A defect taxonomy is a knife edge.** Listing bug categories (v4) fixed
  Qwen3-Coder's data-loss blindness — and made it fabricate findings on the
  clean diff. Softening it (v5) half-worked. It was removed (v6): by this
  repo's own creed, a missed bug costs less than a false one.
- **An echo-guarded example.** Any model that parrots the worked example
  back is caught by the audit's placeholder set; the example's quote line is
  deliberately *not* globally banned, so a real repo containing that exact
  line still gets its finding.

The user prompt carries the 3-round tool budget (an MLX stability guard,
not a speed knob), the untracked-files instruction, the finding template,
and a closing restatement of the two valid outputs. `--intent` swaps the
opening line and inherits every error in the intent's source.

## The settings

Context is 49152 with `--parallel 1` everywhere. **Accuracy across context
tiers has now been measured, and it is flat** — see "Context tiers" below.
The historical 96K kernel panic (~35 GB wired) was MLX/LM Studio-specific;
on llama-server with Qwen3.8 higher context is a safe opt-in (`LLAMA_CTX`),
it is simply not a useful one for this workload. Output caps at 8192 tokens (12000 for
thinking arms). Per-model sampling lives in `~/.pi/agent/models.json`
(template: `models.example.json`); pi merges `samplingParams` verbatim into
every request body, which is how request-level engine knobs are reachable
without pi changes.

| Arm | Serve | Sampling |
|---|---|---|
| Qwen3.8 no-think (default) | `scripts/llama_server.sh` → llama-server, f16 KV (its hybrid cache is small), `--reasoning-format deepseek --reasoning-budget 0` | temp 0.7 · top_p 0.8 · top_k 20 · min_p 0 |
| Qwen3-Coder (fast tier) | LM Studio, auto-managed by review.sh; or llama-server with `--cache-type-k q8_0 --cache-type-v q8_0` | temp 0.7 · top_p 0.8 · top_k 20 · repeat 1.05 · min_p 0.01 |

Qwen3.8's embedded MTP head (`--spec-type draft-mtp`) was measured and
skipped: correctness held but the advertised decode speedups are CUDA
numbers; on Metal it was a wash.

## The harness

`bench/` is the measurement instrument: cases ship as patches (the planted
delta is the only thing a case can contain), the runner bootstraps its own
eval repo, applies a case, runs the real `review.sh` under a watchdog, and
scores from the audit's own validated finding count plus a strict
quoted-line check. The audit itself gained a mechanical anti-fabrication
gate during the bake-off: a finding whose quoted line does not exist in the
file it names invalidates the verdict (normalized for diff markers,
whitespace runs, and backticks; the run anchors at the repo toplevel so the
gate cannot be silently disabled from a subdirectory).

Known limits, stated so they don't get rediscovered: the quote gate cannot
catch a *correctly quoted* line with wrong reasoning (GLM's failure mode) —
a second-pass verifier is the known fix and the next experiment; per-arm n
is small (2 runs per case), so single-run deltas are noise and only
patterns that repeated across versions were acted on; and the frontier
baseline (fresh Claude agents, identical contract) marks the ceiling: the
remaining local gap is analysis depth, not detection or format.

## Context tiers — measured 2026-08-18, and the answer is "it does not matter"

Three arms at 49152 / 65536 / 98304, each running the five small cases twice
and the 18.3 KB big diff twice, with `LLAMA_CTX` and pi's `contextWindow`
raised together per arm (raising one without the other either wastes the room
or lets pi overrun the server). Driver: `bench/run_ctx_tiers.sh`.

| ctx | small cases | clean diff | big diff hits | median s | peak wired |
|---|---|---|---|---|---|
| 49152 | 7/8 | passed | 3, 3 | 140 | 31.5 GB |
| 65536 | 7/8 | passed | 3, 4 | 115 | 32.0 GB |
| 98304 | 7/8 | passed | 4, 3 | 110 | 32.6 GB |

Identical detection at every tier, zero fabrications, and no untrusted verdict
or timeout anywhere in 36 runs. Latency and memory differences are inside the
noise — the same case ranged 45–585 s *within* single arms.

**The mechanism, which matters more than the table.** Every big-diff run peaked
between 13.9K and 16.6K total tokens. That is roughly a third of the *smallest*
window tested. The workload never comes close to filling 49152, so there is no
mechanism by which a larger window could change an answer, and the flat result
is what the token counts predict rather than a surprise. Anyone tempted to
raise `LLAMA_CTX` for quality should check the "N tokens peak" figure in the
audit's stderr line first; raise it only when that number approaches the window.

Two single-run results inside these arms are worth naming precisely so they are
not mistaken for findings. The 98304 arm produced what was, at the time, the
only local catch of the cache-eviction bug ever recorded (verified by hand:
correct line, correct reasoning — the v7 prompt work later that day made the
catch repeatable; see "The frontier gap, located" below), and the 65536 arm
produced one of the first local catches of the default-namespace export bug. Neither repeated in its own arm's second run, and
both runs peaked at the same ~15K tokens as every other run. At n=2 per arm
these are variance on bugs sitting at the edge of the model's reach, not tier
effects.

**Decision: keep 49152.** Raising it is safe and costs nothing measurable, but
it also buys nothing measurable. Untested: a diff large enough to actually fill
the window — this fixture is 18.3 KB, and that question is a different
experiment.

## The frontier gap, located

Also measured 2026-08-18: the frontier baseline was run on the big diff for the
first time (four Claude agents, verbatim system and user prompts, same diff,
verdicts in `bench/bigdiff/frontier-r*.txt`). All four scored 4/5 with zero
unmatched findings, in ~50 s.

The one bug they all caught and the local model almost never did is the cache
eviction (`victim = max(...ts)` evicts the NEWEST entry). Local under the v6
prompt caught it once in eight runs (the six context-tier rows plus the two
rounds-probe rows; the ~3.3 mean-hits figure below is the six tier rows alone,
27/8 ≈ 3.4 over all eight); frontier caught it 4 for 4. **That gap was
real headroom, not a capability ceiling** — which is the question the baseline
was run to settle, and the prompt work it justified then landed: v7's
purpose-anchored method (shipped 2026-08-18, docs/evict-gap.md) lifted the
catch to 2/5 with the reliable trio intact, mean hits ~3.3 → ~3.8, and clean
diffs still at zero findings.

Nothing else about relative strengths on this fixture is currently supported.
The default-namespace export bug is caught by local 2 of 8 and frontier 0 of 4,
which is not a distinguishable difference at this n, and reading it as one is a
mistake this bench has already invited more than once.
