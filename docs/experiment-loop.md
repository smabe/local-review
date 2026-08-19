# The experiment loop — how a change to the reviewer gets made

Codified 2026-08-18 from the two experiments that established it:
`docs/evict-gap.md` (prompt v7 — shipped) and
`docs/angle-removed-behavior.md` (angle-B — reverted). Every change to the
reviewer's prompt, pipeline, or model choice goes through this loop. The loop
exists because both exemplars produced the *opposite* of the intuitive
outcome — the "obvious win" reverted, the "long shot" shipped — and only the
pre-registered rule made either verdict trustworthy.

## The loop

1. **Hypothesis and decision rule first, in writing.** Before any run, a
   `docs/` file states: the change, the gap it targets (cite the measured
   evidence for the gap), the bench arms, and the exact ship/revert rule.
   Deciding after seeing the numbers is how variance ships. The rule names
   thresholds ("2/2 with the marker quoted, clean 0 findings every run"),
   not directions ("should improve recall").

2. **Seed the evidence.** One fixture per claim (`bench/cases/` or
   `bench/bigdiff/`), with a `marker` line the scorer can grep. Every arm set
   includes the fabrication control (`clean` — a finding there kills the
   variant) and a **default-pass arm on the new fixture**: a variant must add
   recall over the baseline, not merely score on the fixture built for it.
   Angle-B died on exactly this arm.

3. **Run the real pipeline.** Bench through `scripts/review.sh` — prompt,
   audit, engine, and exit contract together, never the model in isolation.
   At least 2 runs per small-case arm. Distinct label, append-only
   `results.tsv`, never rewrite rows. Before labeling an arm, verify what is
   actually being served (`curl :8080/v1/models` — the readiness probe only
   proves a port answers).

4. **Score composition, not counts.** Which defects were hit (markers, bug
   ids from `score_bigdiff.py`'s last column), never the total — a variant
   can trade one catch for another while the total stays flat. Non-default
   arms are scored by hand against a pre-written expected map; eyeball the
   logs for near-miss quotes the marker can't see (the `removedguard`
   two-anchor caveat).

5. **Research when results disappoint.** Before iterating the prompt on
   intuition, search for published evidence and prior art — the v4
   taxonomy-list failure was confirmed by external results, which is what
   justified removing it rather than tuning it. A second hypothesis re-enters
   the loop at step 1 with its own pre-registered rule; it does not amend the
   first one mid-flight.

6. **Ship or revert per the rule — keep everything either way.** The doc is
   updated with measured results and the verdict, the fixture and bench rows
   stay (the experiment must remain replayable), and the wiring is reverted
   if the answer was no. The ship path is: README + `skill/SKILL.md` + tests
   updated together, `review.sh` ported byte-identical to the abe-skills
   mirror, and the doc's status line flipped to shipped.

## Standing constraints any experiment inherits

- The default system prompt's anti-fabrication scaffold (rules 1 and 2) is
  never weakened in place. A variant that needs different rules runs as a
  **separate opt-in pass** with its own prompt — measured twice (v4, and the
  published equivalent) that merging classes into one prompt costs precision.
- An angle pass suppresses the v7 Method line (purpose framing is its own
  measured variable; see the angle-B caveat).
- One model, one lock: there is no parallel fan-out locally. An angle is a
  second sequential run, opt-in, never default.
