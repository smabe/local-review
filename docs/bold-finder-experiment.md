# Bold finder under --verify — pre-registered, results pending

Status: registered 2026-08-19 BEFORE any run, per `docs/experiment-loop.md`.
Wiring waits until the rounds bench (docs/rounds-experiment.md) releases the
model — review.sh is never edited while a bench run is in flight.

## Research grounding (loop step 5, done before this registration)

- G-Research's production code-review tool reports the load-bearing pattern is
  splitting recall and precision into two prompts: a first pass that captures
  everything, a second that filters. That is the architecture --verify just
  shipped; this experiment completes it by letting the finder actually lean on
  the filter. https://www.gresearch.com/news/building-a-code-review-tool-the-llm-patterns-that-actually-work/
- A 2026 Automated Software Engineering study finds more detailed prompt
  designs raise misjudgment rates in LLM code review — external confirmation
  of this repo's measured v4 taxonomy failure. The variant below therefore
  changes CONFIDENCE handling only; it adds no defect categories.
  https://link.springer.com/article/10.1007/s10515-026-00638-5

## Hypothesis

Rule 5 ("If you are unsure, omit it") is what suppresses the reviewer's
low-confidence catches — the measured recall ceiling on bigdiff's
`cache_evict` (frontier 4/4, local ~1/lifetime before tonight). With the
verifier measured at 8/8 on provably-false findings, a finder that reports
unsure findings at `confidence: low` — ONLY when --verify will filter them —
recovers recall without shipping the false positives.

## Wiring (experiment-only, revert per rule)

When BOTH --verify is on and LOCAL_REVIEW_FINDER=bold is set (env, not a
flag — undocumented until measured), the default system prompt's rule 5 is
replaced by: "If you are unsure, report it with confidence: low and keep the
quote exact — every finding will be adversarially verified in a second pass."
Everything else byte-identical. Never active without --verify.

## Arms

| arm | label | runs |
|---|---|---|
| bigdiff, bold finder + --verify | `qwen38-nothink-bold-big` | ×5 |
| small cases clean + swallow + offbyone + boolean, bold + --verify | `qwen38-nothink-bold` | ×2 |
| baseline | the same-night `qwen38-nothink-r3-base` ×5 (rounds experiment) | reused |

## Decision rule (pre-registered)

SHIP (rule-5 swap active when --verify is on, documented) iff ALL of:
1. clean: exit 0 in both runs END-TO-END (post-verification).
2. Small-case catches (swallow, offbyone, boolean): retained through
   verification in every run where the finder caught them, and no
   verified-surviving fabrication on any small case.
3. bigdiff per-bug composition (post-verification survivors) >= the r3-base
   arm on every bug, and at least one previously-sub-50% bug (cache_evict or
   export_exit0's sibling class) appears in >=2/5 runs with a genuine quote.
4. Zero verified-surviving unmatched findings on bigdiff (a bold finder may
   EMIT more; nothing false may SURVIVE).

Otherwise revert the wiring, keep everything, and record which stage failed
(finder emitted nothing new vs verifier failed to filter) — the two failure
modes point at different next hypotheses.

## Measured results

(pending)
