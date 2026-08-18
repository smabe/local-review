# Removed-behavior angle pass — MEASURED, NOT SHIPPED

Status: drafted, implemented, and benched 2026-08-18. The pre-registered
decision rule below said no: the angle pass ran exactly as designed — zero
fabrications, zero out-of-class findings — and added zero recall over the
default pass. The `--angle removed` flag was reverted per that rule; this doc,
the fixture at `bench/cases/removedguard/`, the bench rows, and the runner
env-overrides (`LOCAL_REVIEW_EVAL_CASES` / `LOCAL_REVIEW_EVAL_ARGS`) are kept
so the experiment is replayable.

## Measured results (2026-08-18, qwen38-gguf-nothink @ 49152, llama-server)

| arm | result |
|---|---|
| angle pass, 6 small cases ×2 (`qwen38-nothink-angleB`) | `removedguard` caught 2/2 with the right quote; `clean` 0 findings both runs; offbyone/swallow/boolean/leak all silent (out of class, correctly) |
| DEFAULT pass over `removedguard` ×2 (`qwen38-nothink-rg-default`) | caught 2/2 — the default reviewer already sees through the refactor disguise |
| angle pass, 18KB bigdiff ×1 | 1 finding, `migrate_discard`, zero unmatched — but the default pass catches `migrate_discard` in 6/6 recorded runs |

Composition: default ∪ angle = default, on every fixture available. The angle
pass is a well-behaved lens that finds only what the default pass already
finds. Notable negative: it stayed silent on `swallow` both runs — a dropped
error path dressed up as deliberate ("starts empty rather than crashing")
reads to it as intended behaviour, so even in-class recall does not exceed the
default pass.

What this does and does not say: for THIS model the single general prompt is
not leaving removed-behavior recall on the table — the angle-pass mechanism
itself works (format held, quote gate held, no fabrication at 18KB) and would
be worth re-testing on a weaker/faster model (e.g. Qwen3-Coder, whose measured
blindness is exactly the swallow class) or on a future fixture the default
pass fails. Re-create the flag from the prompt text below; the harness hooks
are still in place.

## Why this angle, and why a separate pass

The measured gap between the local reviewer and the frontier baseline is the
swallow class — removed or dropped error handling — plus finding depth
(bench/results.tsv; Qwen3-Coder and Devstral both miss `swallow`). auto-review's
"removed-behavior auditor" angle targets exactly that class, so it is the one
angle worth porting first.

It must be a separate sequential pass, not lines added to the default prompt.
Measured twice: prompt v4's defect-taxonomy list fixed the swallow blindness but
caused clean-diff fabrications, and its removal (v6) restored precision. The
same result is published externally (an exhaustive defect checklist in one
prompt lowers detection accuracy). auto-review itself never merges angles — it
runs one agent per angle. Locally there is no parallelism (one model, one lock),
so an angle is a second full run: opt-in, never default.

## The prompt variant

The system prompt is UNCHANGED — it is the measured anti-fabrication scaffold
and carries no angle. The variant replaces only the `OPENING` of the user
prompt. Everything after it (HARD BUDGET, untracked-files note, finding format,
final reminder, large-diff appendix) stays byte-identical.

```
Review the uncommitted changes in this repository for one class of defect only: behaviour the change REMOVES without replacement.
Work from the diff's deleted lines (they start with "-"): for each one, name the check, guard, error handler, or invariant it enforced, then read the new code and find where that protection is re-established.
If it is re-established, or the situation it protected against can no longer occur, it is not a defect.
If the protection is simply gone, that is a defect. Report it on the NEW code: FILE and QUOTE name the line that now executes without the protection, exactly as it appears in the current file. Never quote a deleted line.
In FAILURE, name the input or state the deleted line used to handle, and what happens to it now.
Ignore every other kind of defect in this pass.
```

Design constraints this threads:

- **The audit's quote gate** (`review.sh`, `quote_in_named_file`) rejects any
  QUOTE not present in the named file. A deleted line no longer exists, so the
  finding must be anchored on the surviving new-code line. The prompt says so
  twice; this is the crux of the variant.
- **System rule 6** ("never report a defect in `-` lines") stays satisfied: the
  deleted line is evidence, the defect is reported in new code.
- **No taxonomy list.** The variant names one class and a method, not a
  checklist of pitfalls — the v4 lesson.
- The audit, exit contract, and finding format need zero changes.

## Wiring (applied for the bench, then reverted per the decision rule)

1. `scripts/review.sh`: `--angle removed` — usage line, arg parser, an
   `if [ "$ANGLE" = removed ]` branch selecting the OPENING above, `--intent`
   mutually exclusive (the intent frame judges against purpose, this pass
   deliberately ignores purpose). REVERTED in both repos after the bench; the
   suite tests for it (three `arg_is` lines incl. one discriminating
   `--angle removed --rounds abc` → exit 1) went with it. Re-apply from this
   description if a future model/fixture justifies the flag. **Caveat since
   prompt v7 shipped (2026-08-18):** the default prompt now carries the
   purpose-anchored Method line after the OPENING, so "everything after the
   OPENING stays identical" no longer reproduces the measured angle arm —
   this pass was measured WITHOUT purpose framing and was made mutually
   exclusive with `--intent` for exactly that reason, so a re-application
   must also suppress the Method line (empty METHOD on the angle branch, as
   the `--intent` branch now does), and the recorded `qwen38-nothink-angleB`
   rows are a v6-prompt baseline — compare against them only from a checkout
   of that era.
2. `bench/run_eval.sh` + `bench/run_bigdiff.sh`: case list and flag
   passthrough via `LOCAL_REVIEW_EVAL_CASES` / `LOCAL_REVIEW_EVAL_ARGS`. KEPT
   — the recorded bench rows are reproducible only with these.
3. `skill/SKILL.md` + README: never updated — the flag did not ship.

## The fixture: `bench/cases/removedguard`

A refactor-shaped deletion in `parser.py`: the `KEY=VALUE` separator check is
consolidated into `partition()`/`if not sep` (correct, and sold by a comment),
while the `if not key: raise ValueError("empty key")` guard silently vanishes.
Verified behaviour after apply: `parse_config("=value")` returns
`{'': 'value'}` instead of raising; malformed lines still raise. A line-by-line
scan tends to bless the refactor; the removed-behavior question ("where did the
empty-key raise go?") is the only road to it.

`meta`: `expected_exit=4`, `marker=result[key.strip()]`.

**Marker caveat:** the marker scores a catch only if the model quotes the
`result[key.strip()] = value.strip()` line. A model that instead quotes the
`partition(` line has found the defect but scores `found=0` — eyeball the logs
for that near-miss before trusting the aggregate.

## Bench plan and expected map for an angle arm

Run the angle pass over all six cases, 2+ runs, label like
`qwen38-nothink-angleB`. The `expected` column in results.tsv comes from case
meta and is calibrated for the DEFAULT pass, so score an angle arm by hand:

| case | angle-pass expectation |
|---|---|
| removedguard | 4, marker quoted — the point of the exercise |
| swallow | 4 — dropped error path is in class |
| clean | 0 — the fabrication tripwire; a 4 here kills the variant |
| offbyone, boolean, leak | ideally 0 (out of class). A 4 with a genuinely quoted line is not a fabrication, but does not count as a catch for this arm |

Also worth one arm: the DEFAULT prompt over `removedguard`, to measure whether
the angle pass actually adds recall over the baseline on this case — if the
default pass already catches it, the angle buys nothing here and needs a harder
fixture.

Decision rule: ship the flag only if the angle arm catches `removedguard` (and
keeps `swallow`) with `clean` still exiting 0 across every run. Fabrications on
clean or out-of-class cases mean the answer was no — delete the flag, keep the
fixture.

Composition check, not just counts: also run the angle pass over the big-diff
fixture once and compare bug IDS against the default pass's runs
(`score_bigdiff.py` last column). An angle arm that gains `removedguard` but
loses a bug the default pass reliably catches has traded, not gained — the
per-bug table decides, never the total. Bench rows append to the shared
`bench/results.tsv`; use a distinct label and never rewrite the file.

## Context from the 2026-08-18 context-tier benchmark (mid-run)

Passed over from the benchmark session while its arms were still running;
sharpens what this angle can and cannot claim.

- **Context is not the constraint.** Big-diff runs peak at 13.9–15.5K of the
  49152-token window, and the 49152 and 65536 arms scored identically. A prompt
  variant has headroom; a bigger window will not rescue one that isn't landing.
- **The strongest measured recall gap is OUT of this angle's class — and it is
  real headroom, not a ceiling.** The big-diff cache-eviction bug (`cache.py`,
  `max(...ts)` evicting the newest entry instead of the oldest): frontier
  baseline 4/4 with the right line and the right reasoning
  (bench/bigdiff/frontier-r*.txt; n=4 after one non-compliant run was
  discarded — the baseline is Claude agents on verbatim prompts, not a
  hermetic harness). Local: exactly ONE catch ever, in the 98304 context-tier
  arm, non-repeating within its arm and at the same ~15K token peak as every
  other run — variance at the edge of reach, NOT a tier effect (the
  context-tier benchmark measured identical detection at 49152/65536/98304;
  docs/model-choice.md "Context tiers"). Still the real target for a future
  variant, as separate work from angle-B (wrong-comparator bug in ADDED code,
  a different class). No design yet: the v4 taxonomy lesson applies in full,
  since "check comparator direction" is exactly category-shaped.
- **Score WHICH bugs were hit, not how many.** A prompt change can trade one
  catch for another while the total stays flat; only a per-bug table shows the
  composition (`score_bigdiff.py`'s last column carries the bug ids). Note the
  earlier claim that local and frontier have measurably different strengths on
  this fixture (the default-namespace export bug) was RETRACTED by the
  benchmark session — two local catches across all recorded runs vs frontier
  0/4 is not distinguishable from noise; every relative-strength claim on
  this fixture beyond the cache-eviction gap is currently unsupported.
- **Prompt history says shape beats content.** The bake-off's biggest single
  gain was fixing an ambiguous template models copied literally, not adding
  instructions. This variant is mostly a shape change (re-anchoring the quote
  onto surviving code); the class description is the content part, and the
  clean case is where it would break — measure that case first.
- **Untested rounds hypothesis (not a finding):** the 3-round budget is
  documented as an MLX stability guard, but MLX is no longer the default
  engine, and the logs could not confirm the cap binds (audit counts CALLS,
  budget is ROUNDS). Worth a separate two-run probe at `--rounds 6` before
  attributing any angle-arm miss to the budget.
- **Attribute results to what was actually served.** review.sh's readiness
  probe only checks that the port answers — it would pass against somebody
  else's server. Before labeling any bench arm, verify the served model/context
  (e.g. `curl :8080/v1/models` output or the llama-server banner), don't trust
  that the flag took effect. (A bug of exactly this shape nearly mislabeled a
  whole context-tier arm.)
- **Scoring gotchas inherited from the big-diff work:** a two-line defect can
  be legitimately quoted from either line, so signature lists need both
  anchors (the `removedguard` marker caveat above is the same failure mode);
  and if a scoring rule changes mid-run, `bench/rescore_bigdiff.py` must
  rebuild stored rows or the comparison is void.
