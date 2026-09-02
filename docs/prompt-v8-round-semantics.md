# Prompt v8: define "round", drop `confidence:` — SHIPPED 2026-09-01

Status: registered 2026-09-01 BEFORE any run, per `docs/experiment-loop.md`.
Nothing above "Measured results" is edited after the baseline arm's first run.

## The gap

An external read of the prompt (a Qwen review of the repo, 2026-09-01)
raised five items. Three were checked against the code and dismissed — the
finding-count cap (max observed findings per run across ~380 seeded rows is
3), the "missing recall benchmark" (`bench/run_eval.sh` and the bigdiff are
exactly that), and "make confidence load-bearing" (already measured as
no-ship in `docs/bold-finder-experiment.md`). Two survive as prompt gaps:

- **"Round" is undefined.** The HARD BUDGET line says "at most N rounds of
  tool calls" but never says what a round is. The budget is prompt-only (pi
  gets no turn cap from `review.sh`), so a round is one assistant turn, and
  the bench logs show pi does issue several tool calls per turn (19 of 61
  tool-bearing assistant messages in `bench/logs/*.raw` carry 2). A model
  that reads "round" as "one tool call" would ration file reads on a
  multi-file diff and judge the rest from diff context, violating rule 8.
  `docs/evict-gap.md` measured that extra rounds change nothing, so the fix
  is wording, not budget.
- **`confidence:` is consumed by nothing.** The audit's block regex reads
  only the path from the FILE line; `--verify` never reads it. It costs
  output tokens on every finding and a decision per finding for no
  downstream effect.

## The change (variant arm only; `scripts/review.sh` untouched until verdict)

1. HARD BUDGET line becomes:
   `HARD BUDGET: at most N rounds of tool calls, then give your verdict. A
   round is one turn; a turn may issue several tool calls, and one command
   may read every changed file. Batch: round 1: git status --short && DIFF;
   round 2: read all changed files in a single command.`
2. `| confidence: high|medium|low` removed from the user prompt's FILE
   format line and from the system prompt's worked example. The angle and
   verify prompts are separate measured variables and are not touched.

Nothing else moves: rules 1–9, the v7 Method line, the placeholder set.

## Engine caveat, stated before any number

The MTPLX daemon on :8000 today serves pack
`mtplx-qwen38-27b-optimized-quality` (`curl :8000/v1/models`), not the
Optimized-Speed pack every `mtplx-*` row in `bench/results.tsv` was measured
on. MTPLX ignores the request's `model` field, so the repo alias
`qwen38-mtplx` (thinking on, medium) drives it unchanged. The baseline arm is
therefore also the first measurement of this pack; the pack-vs-pack
comparison against `mtplx-think` is reported but is NOT the decision here.
The decision compares the two arms below, same pack, same script sha except
for the prompt diff.

## Arms

Sampling is the shipped 0.7, so per `docs/sampling-noise-floor.md` one run is
not a measurement; 3 runs per case, matching the earlier `mtplx-*` arms.

| arm | label | script | runs/case |
|---|---|---|---|
| baseline | `mtplx-quality-base` | `scripts/review.sh` as committed | 3 |
| variant | `mtplx-quality-v8` | scratch copy with change 1+2 only | 3 |

Cases: `offbyone swallow boolean leak clean` via `bench/run_eval.sh mtplx
qwen38-mtplx 3 <label>`; the variant via `LOCAL_REVIEW_SH=<copy>`.

## Ship / revert rule (pre-registered)

SHIP the variant (port to `scripts/review.sh`, README, SKILL.md, tests,
mirror) iff ALL of:

1. `clean`: 0 findings in 3/3 variant runs.
2. No variant run exits 3 where the baseline's same case had 0/3 exit-3 runs.
3. Summed `found` over the four bug cases: variant ≥ baseline.
4. No single bug case drops by 2 or more of 3 against baseline.

Otherwise REVERT (keep doc, rows, scratch copy under `bench/logs/`).
False-reject note: at the measured 19% pair-disagreement floor, a 1-run drop
on one case is within noise and rule 4 tolerates it; a 2-run drop on one
case is not, and rule 3 refuses a net trade. Rule 3 is a tie-or-better rule
because the change is a token cut plus a clarification, not a recall claim.

## Measured results (2026-09-01, MTPLX Optimized-Quality pack, `qwen38-mtplx`, 3 runs/case)

`found` per case (planted line quoted AND exit 4); rows in `bench/results.tsv`.

| case | baseline `mtplx-quality-base` (sha 3f95b7b291e9) | variant `mtplx-quality-v8` (sha 13455e2a9cdb) |
|---|---|---|
| offbyone | 3/3 | 3/3 |
| boolean | 3/3 | 3/3 |
| swallow | 1/3 | 1/3 |
| leak | 1/3 | 2/3 |
| clean (findings) | 0, 0, 0 | 0, 0, 0 |
| exit 3 anywhere | none | none |
| sum over bug cases | 8 | 9 |

Rule check: 1 clean 0/3 ✓ · 2 no exit 3 ✓ · 3 sum 9 ≥ 8 ✓ · 4 no case dropped ✓.
Verdict: SHIP. The leak +1 is within the 0.7 noise floor and is not claimed as
a gain; the claim is that the token cut and the round definition cost nothing
ON ONE-FILE DIFFS. Every seeded case changes one file, so the behaviour the
round wording targets — rationing reads across many changed files — was not
exercised. The multi-file measurement is the bigdiff fixture; a
baseline/variant `run_bigdiff.sh` pair on this pack, scored by bug
composition, is the open follow-up and is not claimed here.
Every variant finding carried a bare `FILE: path:LINE` — the model dropped the
tag as instructed, no stray `confidence:` in any of the 15 runs.

Pack note (not the decision): this is the first measurement of the
Optimized-Quality pack. Against the Optimized-Speed rows (`mtplx-think`:
offbyone 3/3, boolean 3/3, leak 2/3, swallow 0/3, clean 0) it is the same
picture with swallow caught once — n=3 at 0.7 sampling, treat as parity.

Shipped: `scripts/review.sh`, README, this doc; ported byte-identical to
the abe-skills mirror. The audit needed no change — it never read the tag —
and the test fixtures that still carry `| confidence: high` stay as they are,
since they prove older-format output still parses.

## Post-measurement amendment (2026-09-01, after the verdict; not pre-registered)

The pre-registered change said the angle prompt was "not touched". That was
wrong as a description of the effective prompt: `--angle stalecomment` swaps
only the SYSTEM prompt and shares this USER prompt, so change 1 and the
format line of change 2 reach angle runs regardless. Shipping left the angle's
worked example carrying `| confidence: high` against a user prompt that no
longer shows the tag. Repair, made while the change was under review: the
angle example drops the tag too (one line, `scripts/review.sh` stalecomment
branch), so the shipped script is sha `e911d9042fe7`, not the measured
variant's `13455e2a9cdb`; the diff between the two is that single example
line, which no default or `--intent` run ever sees. The angle pass has not
been re-benched under v8 and its evidence in `docs/angle-stale-comment.md`
predates it; an angle run inherits shared user-prompt changes by design (as
it inherited v7's HARD BUDGET line), and re-benching it is the angle's own
follow-up.
