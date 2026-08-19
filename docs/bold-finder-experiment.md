# Bold finder under --verify — MEASURED: no ship (a trade, not a gain)

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

## Measured results (2026-08-19, qwen38-gguf-nothink @ 49152, llama-server)

Small cases (bold + --verify, ×2): every condition met — clean 0/2 end-to-end,
swallow/offbyone/boolean caught AND retained 2/2 each (swallow, historically
flaky, went 2/2).

Bigdiff, 5 runs per arm (labels split by `-b`/`-c` continuations after
repeated external background-task kills; every counted run is a complete log):

| bug | baseline (rounds-3, no verify) | bold + --verify |
|---|---|---|
| migrate_discard | 5/5 | 5/5 |
| import_after_guard | 5/5 | 5/5 |
| export_exit0 | 5/5 | 5/5 |
| export_default_ns | 4/5 | 3/5 |
| cache_evict | 2/5 | 3/5 |
| unmatched survivors | n/a (no verifier) | 1 — hand-verified GENUINE (see below) |

Two bold runs caught ALL FIVE planted bugs — unprecedented in the recorded
history. And the bold finder DISCOVERED a sixth, unplanted, genuine bug:
`rename_namespace` validates the separator only in `new`, so an `old`
containing SEP prefix-matches a sibling namespace's keys and moves them
(verified twice by live execution — by the verifier pass in-run and by hand
during scoring). Adopted into `score_bigdiff.py` as `rename_prefix`.

(TSV note: the `other` values first recorded for --verify rows were inflated
by review.sh's verification echo — fixed in the scorer and rebuilt by
`rescore_bigdiff.py` the same night; the rebuilt rows show other=0 across the
bold arm except the genuine rename discovery, which now scores as a HIT under
the adopted `rename_prefix` signature.)

Decision rule outcome: FAIL on condition 3 — bold is not >= baseline on every
bug (export_default_ns 3/5 vs 4/5), it traded that bug for cache_evict
(3/5 vs 2/5). The rule refuses trades by design. Wiring REVERTED; the doc,
labels, logs, and the adopted bug stay.

What the failure actually looks like: not "finder found nothing new" and not
"verifier failed to filter" (zero false survivors) — an attention trade at a
fixed reading budget. A future hypothesis with its own registration could
test bold at a higher generation budget, or a two-pass compose (default pass
∪ bold pass) — composition of two full runs was angle-B's model and sidesteps
the trade, at 2× cost.
