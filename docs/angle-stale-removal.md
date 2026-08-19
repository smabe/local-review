# Removal-shaped stale comments — MEASURED: covered by the shipped pass

Status: registered 2026-08-19 before any run, benched the same night. The
shipped `--angle stalecomment` pass covers the removal shape 3/3 with no
prompt change; nothing between here and "Measured results" was edited after
the first run.

## The gap being measured

`--angle stalecomment` shipped on a fixture whose stale docstring is
contradicted by an ADDED line (`if key in result: continue` vs "later
duplicates win"). The motivating real-world miss (the healthdata diff) had the
harder shape: a comment describing REMOVED behaviour, with no added line that
contradicts it — the claim is falsified by an absence. The shipped experiment's
doc flags this explicitly as untested. Detecting it requires reading a deleted
"-" line's obligation and noticing nothing re-establishes it, which is also the
class the default pass measurably struggles with (angle-B's `swallow`
analysis).

## Hypothesis

The shipped angle pass, unchanged, catches a docstring claim whose
implementing code the diff removed ("Raises ValueError on malformed lines"
after the raise becomes a tolerant `continue`), quoting the docstring line.

## The fixture: `bench/cases/staleremoval`

In `parse_config`, the malformed-line `raise` is replaced by
`continue  # tolerate junk lines from hand-edited configs` — an intended
loosening, correct in itself, with an ACCURATE new inline comment. The
function docstring still claims "Raises ValueError on malformed lines." (the
empty-key raise remains, so the claim is now false only for the separator
case — a partial staleness, like real ones). No code bug is planted.
`meta`: `expected_exit=0` (default-pass calibration), `marker=Raises
ValueError on malformed lines`.

## Arms (qwen38-gguf-nothink @ 49152, llama-server, served model verified)

| arm | label | runs |
|---|---|---|
| angle pass on `staleremoval` | `qwen38-nothink-anglSC-rm` | ×3 |
| default pass on `staleremoval` | `qwen38-nothink-rm-default` | ×2 (informative, non-gating) |

## Decision rule (pre-registered)

- Angle catches ≥2/3 (exit 4, marker in QUOTE): record the shape as covered in
  docs/angle-stale-comment.md; nothing ships (the pass already shipped).
- 0–1/3: the shape is NOT covered. Per the loop, research prior art online on
  prompting for removed-behaviour/doc-consistency before any prompt iteration;
  any iteration is a NEW pre-registered experiment and must re-pass the full
  original conditions (stalecomment 2/2, clean 0/2, bigdiff fabrication-free)
  plus improvement here.
- Any fabricated finding on these runs (a quoted line that is not genuinely
  contradicted): record it prominently — precision on this shape becomes its
  own follow-up.

## Measured results (2026-08-19, qwen38-gguf-nothink @ 49152, llama-server)

| arm | result |
|---|---|
| angle pass ×3 (`qwen38-nothink-anglSC-rm`) | 3/3 exit 4, the exact docstring line ("Raises ValueError on malformed lines.") quoted every run, one finding per run, zero fabrications |
| default pass ×2 (`qwen38-nothink-rm-default`) | run 1: exit 0, fully clean — the healthdata miss reproduced exactly; run 2: exit 4 quoting the new `continue` line — the misattribution mode again |

Decision rule branch taken: ≥2/3 → the shape is covered; nothing ships. The
default-pass arm is the sharpest measurement yet of why the angle exists: on
the same removal-shaped staleness the default pass either sees nothing (its
documented weakness on removed behaviour) or blames the correct code, while
the angle pass anchored on the stale comment 3/3.
