# Rounds budget on the big diff — MEASURED: no ship, the cap stands

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

## Measured results (2026-08-19, qwen38-gguf-nothink @ 49152, llama-server)

Run-provenance notes, in the append-only spirit: two `qwen38-nothink-r6` rows
dated 2026-08-18 13:26/13:36 in results-bigdiff.tsv are the PRIOR session's
pre-v7 runs (their logs were rotated to `.prev` by tonight's collision) —
excluded as incomparable. Tonight's first baseline run was killed mid-flight
(log empty, no row) — excluded. Background-task kills forced label
continuations (`-b` suffixes); every counted run below is a complete log.

| arm | runs | per-bug composition |
|---|---|---|
| rounds 3 (`r3-base-b` ×3) | 3 | import_after_guard 3/3 · migrate_discard 3/3 · export_exit0 3/3 · export_default_ns 3/3 · cache_evict 1/3 · unmatched: 1 (one run) |
| rounds 6 (`r6` ×1 + `r6-b` ×2) | 3 | import_after_guard 2/3 · migrate_discard 2/3 · export_exit0 2/3 · export_default_ns 0/3 · cache_evict 1/3 · one run exited 3 with NO VERDICT (empty response after 2 tool calls, 14,979 tokens peak) |

Decision rule outcome: FAIL on both clauses — r6 is not >= baseline on every
bug (export_default_ns 0/3 vs 3/3) and the no-verdict run shows the failure
mode the cap exists to prevent occurs on llama-server too, not only MLX: more
rounds means more reading, and the verdict can starve. The 3-round default
stands ON MERIT for this model; the docs' MLX-history framing understates it.

Observation recorded, no claim: cache_evict was caught twice tonight (once
per arm here, once in the --verify bigdiff run) after exactly one catch in
all prior history — all tonight's runs are prompt v7. Possibly v7's purpose
anchoring, possibly variance; a dedicated arm would be needed to say.
