# Local verifier pass — capability probe: GRADUATED, perfect gating score

Status: registered 2026-08-19 before any run; probe complete the same night.
Both gating thresholds cleared at ceiling (14/14 retention, 8/8 refutation),
so the concept GRADUATES to a wiring experiment (`docs/verify-flag.md`).
Operator-requested 2026-08-18: port code-review's verifier role to the local
model. Nothing between here and "Measured results" was edited after the
first run.

## What is being measured, and what is not

This experiment measures CAPABILITY only: can qwen38-nothink, given one
finding and repo access, retain true findings and refute false ones? No
review.sh wiring ships from this experiment. If the capability clears the
bar, WIRING a `--verify` flag becomes its own pre-registered follow-up.

The known risk is self-verification: the same model re-reading a claim tends
to reproduce the reasoning that produced it. The corpus is built to expose
exactly that — every true finding and both misattributed findings were
produced by this same model tonight.

## Corpus (`bench/verify/items/`, 13 items)

- **7 true** (`t1`–`t7`), verbatim from tonight's measured runs: the two
  stale-doc catches, the two doc-contradiction findings on planted code bugs,
  the two direct code-bug findings, and the swallow UnicodeDecodeError
  finding. A verifier that kills these is worse than no verifier.
- **4 provably false, gating** (`f3`–`f6`): the echoed template (its FILE
  does not exist), the clean case's deliberate IndexError trap (short-circuit
  makes it safe), a wrong claim about the `n <= 0` guard, and a wrong claim
  that an except-tuple swallows KeyboardInterrupt. Each refutation is
  constructible from a single quoted line.
- **2 real misattributions, NON-gating** (`f1`, `f2`): the default pass
  blaming correct code under a stale docstring. Refuting these requires
  knowing the change's intent, which the verifier does not have; they are
  recorded to measure the ceiling, not to gate.

## Mechanism

`bench/run_verify.sh` applies the item's fixture to the eval repo, then runs
pi directly (same flags as review.sh: no session, edit/write excluded, JSON
events) with a verifier system prompt: quote-anchored, at most 3 tool rounds,
verdict format `VERDICT: real|refuted` + `REASON:`. Refuted requires a
constructible refutation (a quoted line, type, or guard that makes the claimed
failure impossible); unsure defaults to real — the pass exists to kill
provably-false findings, not to second-guess plausible ones.

## Decision rule (pre-registered; 2 runs per item)

GRADUATE to a wiring experiment iff, over gating items:
1. True retention ≥ 12/14 runs verdict `real`.
2. False refutation ≥ 6/8 runs verdict `refuted` on `f3`–`f6`.
3. No-verdict runs count as failures for their side.

Otherwise: record the capability gap, research prior art online
(chain-of-verification, self-refutation prompting) before any second
hypothesis. `f1`/`f2` results are recorded either way and gate nothing.

## Measured results (2026-08-19, qwen38-gguf-nothink @ 49152, llama-server, label `qwen38-nothink-verify1`)

| metric | result | threshold |
|---|---|---|
| true retention (t1–t7 ×2) | **14/14** verdict real | ≥12/14 |
| gating-false refutation (f3–f6 ×2) | **8/8** verdict refuted | ≥6/8 |
| non-gating misattributions (f1–f2 ×2) | 0/4 refuted | none — records the ceiling |

Every refutation came with a correctly constructed reason (spot-checked: the
echoed template was refuted because its file does not exist in the repo; the
clean-case trap because `not line` short-circuits before `line[0]`). The
self-verification worry did not materialize on this corpus: the model refuted
its own fabrication-shaped findings while retaining every finding it had
correctly produced. The misattribution class (correct code blamed under a
stale comment) is confirmed unrefutable without intent, as predicted — a
verifier pass will not fix attribution, only fabrication.

Decision rule branch taken: GRADUATE. The wiring experiment (a `--verify`
flag on review.sh) is pre-registered separately in `docs/verify-flag.md`.
