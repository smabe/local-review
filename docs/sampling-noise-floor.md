# Sampling noise floor — is a 2-run arm a measurement?

Status: registered 2026-08-20 BEFORE any pipeline run, per
`docs/experiment-loop.md`. The Prior section below is analysis of rows already
in `results.tsv` plus arithmetic; no model ran to produce it. Nothing above
"Measured results" may be edited after the first run.

## The gap

Every ship/revert verdict in `docs/` rests on 2–5 runs per arm at
**temperature 0.7, top_p 0.8, top_k 20** (`qwen38-gguf-nothink` in
`~/.pi/agent/models.json`). Disagreement between runs is repeatedly written off
as noise, and the size of that noise had never been measured:

- `rounds-experiment.md:34` — "1-in-5 either side is variance"
- `evict-gap.md:98` — "inside the baseline variance band"
- `angle-removed-behavior.md:164` — "variance at the edge of reach"

Temperature appears nowhere in `docs/` as an experimental variable.

External evidence for the mechanism, from a probe of Apple's on-device model
run against the same question
(`~/projects/HealthData/docs/claude-references/ai-prompt-architecture.md` §3):
under nucleus sampling "the same prompt scored 1 inversion on one run and 3 on
the next, and prompt rankings REARRANGED when sampling changed"; the fix was
greedy + temperature 0, verified deterministic by checking every metric came
back an exact multiple of the repetition count. Different model, different
harness — which is why this is a hypothesis to test here, not a result to
import.

## Prior (computed from existing rows, before any run)

`results.tsv` holds 319 usable rows. Grouping by (label, case) gives 150 groups
with ≥2 runs — 149 of them exactly n=2. Restricting to the 140 groups where
every run produced a real verdict (exit 0 or 4), **14 groups (10%) disagree on
whether the planted bug was caught.** It is not uniform:

| case | pairs disagreeing | implied per-run catch rate |
|---|---|---|
| `swallow` | 5/26 (19%) | 0.89 |
| `leak` | 5/26 (19%) | 0.89 |
| `boolean` | 2/27 (7%) | 0.96 |
| `clean` | 1/25 (4%) | — (that one is a fabrication, `qwen3coder-gguf-v5`) |
| `offbyone` | 0/27 (0%) | ≈1.0 |

So `rounds-experiment.md`'s "1-in-5 either side" guess was accurate for the
unstable cases. It was never carried into the runs-per-arm standard.

### The consequence is a rule-shape problem, not a sample-size problem

`rounds-experiment.md` decided on the rule "arm B's per-bug catch count is >=
arm A's on EVERY bug, strictly greater on at least one", with k=4 scored bugs
at n=3 per arm. Model two IDENTICAL arms as independent Binomial(n, p) per bug
and ask how often that rule rejects them:

| runs per arm | P(identical variant REJECTED), p=0.89, k=4 |
|---|---|
| n=2 | 52% |
| n=3 | 62% |
| n=5 | 73% |
| n=10 | 82% |
| n→∞ | 94% |

**More runs makes it worse.** As n grows, P(B ≥ A) on one bug converges to 0.5,
so a conjunction over 4 bugs converges to 0.5⁴ — the rule asymptotes to
rejecting 94% of genuinely-equal variants. Raising the runs-per-arm standard
cannot fix a conjunction of noisy one-sided comparisons; only removing the
noise or changing the rule can.

(Assumptions: independence across bugs and a shared p, neither exactly true —
`cache_evict` sat at 1/3 while the other four sat at 3/3. The direction of the
effect does not depend on either.)

This does NOT retract `rounds-experiment.md`'s verdict. Its second finding —
one r6 run exited 3 with no verdict, showing generation can starve on
llama-server and not only on MLX — is independent of sampling noise and stands.
It is the per-bug composition clause that carries less information than it
appears to.

## Hypothesis

Benching at temperature 0 makes a review run's SCORED OUTCOME (exit code,
validated finding count, marker found) reproducible, so one run per arm is a
measurement and case count becomes the only thing worth growing.

## Design

No change to `review.sh`. A second model id is added to `models.json` pointing
at the same `:8080` server with `temperature: 0` and the other sampling knobs
removed; six ids already share that baseUrl, so routing by an id the server
does not itself declare is established practice here. Step 3's served-model
check therefore reports the loaded GGUF, not the arm's id — expected, and
noted per arm rather than treated as a mismatch.

    "id": "qwen38-gguf-nothink-t0",
    "samplingParams": { "temperature": 0 }

## Arms

| # | arm | label | cases | runs |
|---|---|---|---|---|
| 0 | determinism gate, temp 0 | `qwen38-t0-det` | swallow, leak, offbyone, clean | ×4 |
| 1 | rounds re-run, temp 0, `--rounds 3` | `qwen38-t0-r3` | bigdiff | ×3 |
| 1 | rounds re-run, temp 0, `--rounds 6` | `qwen38-t0-r6` | bigdiff | ×3 |

Arm 0 leads with `swallow` and `leak` because they are the two cases the prior
shows actually flip (19% each). `offbyone` is in as a negative control: it
never flipped in 27 historical pairs, so it must stay stable at temp 0 too or
something other than sampling changed. `clean` is the fabrication control — a
finding there kills the arm regardless of everything else.

Arm 0 gates arm 1: if temperature 0 does not reproduce on the small cases,
arm 1 does not run.

Arm 1 re-runs a decision already on the books (`rounds-experiment.md`, FAIL,
cap stands) at temp 0, scored per-bug by `score_bigdiff.py`, never on totals.
Its fabrication control is that scorer's unmatched-finding count.

The 2-run standard is not raised anywhere in this design. The prior shows that
would make the conjunctive rule worse, not better.

## Decision rule (pre-registered)

**Gate — arm 0.** Determinism holds iff, for each of the four cases, all 4 runs
agree on (exit, nfind, found), AND `clean` is 0 findings in all 4. Byte-identity
of the verdict text is recorded as a stronger signal but is not the bar: the
bench reads the scored outcome, so the scored outcome is what must reproduce.

**Outcome A — gate passes, and arm 1's two temp-0 arms each show identical
per-bug composition across their own 3 runs.** Ship as a change to
`docs/experiment-loop.md` step 3: bench on `qwen38-gguf-nothink-t0`, one run
per arm is a measurement, grow cases rather than reps. The shipped default
sampling for real reviews is NOT changed — greedy is measured elsewhere to risk
repetition loops on free prose, and no arm here tests review quality at temp 0.

**Outcome B — gate passes but arm 1's composition still varies run to run.**
No change to the benching standard. Record that the residual variance is
upstream of sampling (tool-call ordering, diff truncation, round budget) and
name which bug ids moved; that is a different investigation.

**Outcome C — gate fails.** Temperature 0 buys nothing through this stack.
Then the fix is the rule, not the sample count: `experiment-loop.md` step 4
gains a requirement that a per-bug decision rule state its false-reject rate
against an identical variant at the measured p, and any rule above 20% is
rejected as a rule before any arm runs against it. Record the arithmetic for
the rules already used in `rounds-experiment.md` and `evict-gap.md`.

**In every outcome:** `rounds-experiment.md`'s verdict is not rewritten. Any
re-read of it is appended there as a dated note, per the append-only spirit
that doc already follows.

## Measured results (2026-08-20, Qwen3.8-27B Q6_K @ 49152, llama-server)

### API-level probe, before any bench arm

Same prompt, three identical requests each, straight at `/v1/chat/completions`:

| sampling | result |
|---|---|
| `temperature: 0` | 3/3 byte-identical, `finish_reason: stop` |
| shipped `0.7 / top_p 0.8 / top_k 20` | 3/3 different wordings |

A first attempt at 120 `max_tokens` produced three identical EMPTY strings and
hashed as a pass — the generation hit the cap mid-reasoning, so `content` came
back `""`. Three matching empties hash the same as three matching answers.
Any determinism check has to assert on non-empty content.

Routing confirmed: `qwen38-gguf-nothink-t0` is accepted by a server that does
not declare it, and comes back echoed as the served alias.

### Arm 0 — determinism gate: PASSED

16 runs, 4 per case, through the real `review.sh`:

| case | exit | nfind | found | runtimes (s) | verdict text |
|---|---|---|---|---|---|
| `swallow` | 4 ×4 | 1 ×4 | 0 ×4 | 147 / 143 / 146 / 146 | byte-identical ×4 |
| `leak` | 4 ×4 | 1 ×4 | 1 ×4 | 176 / 181 / 182 / 180 | byte-identical ×4 |
| `offbyone` | 4 ×4 | 1 ×4 | 1 ×4 | 60 / 61 / 60 / 61 | byte-identical ×4 |
| `clean` | 0 ×4 | 0 ×4 | 0 ×4 | 69 / 77 / 44 / 44 | byte-identical ×4 |

The gate asked only for agreement on the scored outcome. It got byte-identity
of the whole verdict, through an agent loop with tool calls, on all four cases
— including the two the prior showed flipping 19% of the time at 0.7. The
fabrication control is clean 4/4.

**Determinism froze `swallow` on a miss, not a catch.** All four runs report
one finding that is not the planted `OSError` marker: an untyped `json.load`
result accepted into `self._data`, which contradicts the same function's stated
purpose that a corrupt store "starts empty rather than crashing". That is a
real defect the marker cannot see, scored `found=0`. Determinism buys
reproducibility, not correctness — a frozen wrong answer is as stable as a
frozen right one, which is an argument for growing cases rather than trusting
any single one.

### Arm 1 — rounds re-run at temperature 0: determinism held, and the ranking INVERTED

Six bigdiff runs, `--rounds 3` ×3 and `--rounds 6` ×3, scored per-bug by
`score_bigdiff.py`:

| arm | runs | hits | per-bug composition | fabrication candidates | verdict text |
|---|---|---|---|---|---|
| `--rounds 3` | 3 | 3 | import_after_guard · migrate_discard · export_exit0 | 0 | byte-identical ×3 |
| `--rounds 6` | 3 | 5 | import_after_guard · migrate_discard · export_exit0 · **cache_evict** · **export_default_ns** | 0 | byte-identical ×3 |

Byte-identical across an 18KB diff, seven files and multiple tool rounds. Both
conditions of Outcome A are met.

**r6 is a strict superset of r3** — every bug r3 caught, plus two more, with
zero fabrications in either arm. That satisfies `rounds-experiment.md`'s own
pre-registered SHIP clause ("r6's per-bug catch count is >= r3's on EVERY bug,
strictly greater on at least one, zero unmatched findings"), the clause that
returned FAIL at temperature 0.7 with the same rule, same arms and same
fixture.

**The ranking inverted, it did not merely sharpen.** At 0.7 the r3 arm scored
4 bugs and r6 scored 4-with-a-dead-run, reading as "r6 is worse". At
temperature 0, r3 freezes on a 3-bug answer — it LOSES `export_default_ns`,
which the 0.7 r3 arm caught 3/3 — and r6 gains two. Neither arm's temp-0 result
could be predicted from its 0.7 result, in either direction. This is the effect
the Apple probe named ("prompt rankings REARRANGED when sampling changed"),
now measured on this repo's own fixture against a decision already on the
books.

**`cache_evict` is caught 3/3 at r6.** That is the frontier gap `evict-gap.md`
was built around: 1/8 in all prior history, and the reason prompt v7 exists.

Two things determinism does NOT license:

- **Three identical runs are ONE sample.** r6 produced no starved exit-3 run
  here, but `rounds-experiment.md` observed one at 0.7. The correct statement
  is "this configuration does not starve on this diff", not "r6 does not
  starve". Determinism removes sampling noise; it does not widen coverage. The
  argument for growing cases gets stronger, not weaker.
- **Neither arm is validated as more CORRECT.** Both are frozen answers. r6's
  two extra bugs are real catches by marker, but temp-0 `swallow` in arm 0
  froze on a miss just as stably.

## Verdict: OUTCOME A

Both pre-registered conditions met. `docs/experiment-loop.md` step 3 changes to
bench on `qwen38-gguf-nothink-t0`; one run per arm is a measurement; grow cases
rather than reps. The shipped default sampling for real reviews is NOT changed
— no arm here tested review quality at temperature 0, and greedy is measured
elsewhere to risk repetition loops on free prose.

`rounds-experiment.md` is not rewritten; a dated note is appended there.

## Out of scope, found while probing — the `nothink` arm has been thinking

Not part of this experiment's hypothesis and not folded into its verdict;
recorded here because it was found here, and it needs its own pre-registration
per `experiment-loop.md` step 5.

`scripts/llama_server.sh:42` passes `--reasoning-format deepseek
--reasoning-budget 0` for any Qwen3.8, and the model id is named
`qwen38-gguf-nothink`. **The flag is inert on this build** (`b10450-ece963f41`):

| request to the server started bare by `llama_server.sh` | `reasoning_content` |
|---|---|
| plain | 744 chars |
| + `chat_template_kwargs: {enable_thinking: false}` | 0 |
| + `reasoning_effort: "none"` | 0 |

Both request-level controls work and yield identical output; the server flag
does not. pi sends neither — `supportsReasoningEffort: false` sits in the
llamaserver compat block in `models.json`, and `"reasoning": false` on the
model is not translated into a template kwarg.

It reaches the real pipeline: all 26 preserved pi event streams from
`qwen38-nothink` arms carry thinking blocks, mean 6.7 blocks and 4,695
characters per run. (Only the `verify1` arms kept `.raw` streams; other arms
kept rendered text only, so 26 is what is measurable.)

Consequences to check, none of them established here:

- `docs/evict-gap.md` step 1 ran `qwen38-think-bigdiff` as a distinct condition
  and verified thinking was ON for it by probing for `reasoning_content`. It
  never probed the baseline to confirm thinking was OFF. That comparison is
  budget -1 vs budget 0, and budget 0 appears to be budget -1.
- `qwen38-gguf-nothink` carries `maxTokens: 8192` against the think arm's
  12000. Unbudgeted reasoning eating a smaller cap is a candidate explanation
  for the no-verdict exit-3 runs (`rounds-experiment.md`'s r6 run peaked at
  14,979 tokens) — a hypothesis, not a finding.
- Every accuracy number in this repo was measured with thinking on. That does
  not invalidate them; they are all self-consistent. It means the label is
  wrong and a genuinely thinking-off arm has never been measured.
