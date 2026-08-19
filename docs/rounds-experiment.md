# Rounds budget on the big diff — pre-registered, results pending

Status: registered 2026-08-19 BEFORE any run, per `docs/experiment-loop.md`.
Nothing above "Measured results" may be edited after the first run.

## The hypothesis (from the recorded "untested rounds hypothesis")

The 3-round tool budget is documented as an MLX stability guard, but MLX is no
longer the default engine (llama-server is), and on the 18KB bigdiff the model
must read seven files inside 3 rounds. Hypothesis: `--rounds 6` raises
finding depth on large diffs — specifically the per-bug composition — without
raising fabrications.

## Arms (qwen38-gguf-nothink @ 49152, llama-server, served model verified)

| arm | label | runs |
|---|---|---|
| bigdiff, default prompt, --rounds 3 (baseline re-measure, same night) | `qwen38-nothink-r3-base` | ×5 |
| bigdiff, default prompt, --rounds 6 | `qwen38-nothink-r6` | ×5 |

A same-night baseline arm is run rather than only comparing to historical rows
because the fleet of recorded bigdiff runs spans prompt v6/v7 and context
tiers; five fresh pairs on the shipped config is the honest comparison. The
historical per-bug table remains context.

## Decision rule (pre-registered)

- Score per-bug composition (`score_bigdiff.py` bug ids), never totals.
- SHIP (as a README/SKILL guidance change recommending `--rounds 6` for large
  diffs, NOT as a default change) iff: the r6 arm's per-bug catch count is >=
  the r3 arm's on EVERY bug, strictly greater on at least one bug, and the r6
  arm has zero unmatched (fabrication-candidate) findings across all 5 runs.
- Anything less: record, no change ships. cache_evict specifically: note its
  count in both arms; 1-in-5 either side is variance, per the context-tier
  analysis.

## Measured results

(pending)
