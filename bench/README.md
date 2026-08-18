# bench — seeded-defect eval for the reviewer

Five cases against a tiny committed base repo: four working-tree diffs each
planting one bug (`offbyone`, `swallow`, `boolean`, `leak`) and one genuinely
clean refactor (`clean`) that measures fabrication. Each case ships as
`cases/<name>/case.patch` (the planted delta and nothing else) plus a `meta`
file naming the expected exit and the planted line. `run_eval.sh PROVIDER
MODEL RUNS LABEL` bootstraps `eval-repo/` and `logs/` on first run, applies
each case's patch to the working tree, replays it through `scripts/review.sh`
under a watchdog, and appends TSV rows (exit — 124 means timeout — seconds,
the audit's own validated finding count, and whether the planted line was
quoted in a `QUOTE:` line).

`swallow` (an except clause that eats OSError, so the next flush destroys the
store) is the discriminator: under the shipped prompt only Qwen3.8-27B and
the frontier baseline caught it (one mid-iteration taxonomy prompt let
Qwen3-Coder catch it too, at the cost of clean-diff fabrications). Full numbers: `results.tsv` (arms labelled
`<model>-<engine>-<promptversion>`), frontier-baseline verdicts in
`frontier/`. The v1 file is the before-arm of the FILE-template prompt fix.
