# Swapping the default quant: lmstudio-community over Unsloth

Status: registered 2026-08-21 BEFORE any run, per `docs/experiment-loop.md`.
Nothing above "Measured results" may be edited after the first run.

Ordering note, stated plainly: the operator chose to make the new quant the
default first and bench it after, so the wiring change in
`scripts/llama_server.sh` landed before this file's arms were run. The loop's
integrity requirement — that the decision rule is fixed before anyone sees a
number — is intact, and the revert path below is exact.

## The gap

Two Qwen3.8-27B Q6_K GGUFs now sit on this machine under the same filename:

| | path | quantizer | size | chat template |
|---|---|---|---|---|
| baseline | `~/models/Qwen3.8-27B-Q6_K.gguf` | Unsloth, imatrix (496 entries, 45 chunks) | 22,884,408,288 | patched: merged system messages, developer role, stricter tool-call arg checks |
| candidate | `~/.lmstudio/models/lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q6_K.gguf` | lmstudio-community, no imatrix | 22,430,999,776 | stock Qwen |

Read from the GGUF headers directly (`general.quantized_by`,
`quantize.imatrix.entries_count`, `tokenizer.chat_template`), not from the
filenames, which are identical.

Every accuracy number in `bench/` was measured on the Unsloth build. Until
this file's arms run, nothing is known about the candidate — including whether
it is deterministic at temperature 0, which `docs/sampling-noise-floor.md`
measured on the Unsloth build only.

Two differences are load-bearing enough to name in advance:

- **No imatrix.** The baseline's Q6_K was calibrated against an activation
  importance matrix; the candidate's was not. At 6 bits the expected gap is
  small, which is exactly why it needs measuring rather than asserting.
- **Stock chat template.** The Unsloth build's template merges consecutive
  leading system messages and raises on tool-call arguments passed as a JSON
  string; the stock one raises `'No user query found in messages.'` on a
  `multi_step_tool` path the Unsloth build deleted. Both matter to an agent
  loop that replays tool calls, and neither is exercised by a single-turn probe.

One difference is ruled out already: both templates gate reasoning on
`enable_thinking` alone, with no budget path, so the swap cannot change the
`--reasoning-budget 0` finding in `docs/thinking-off.md`.

## Hypothesis

The lmstudio-community Q6_K detects the same defects as the Unsloth Q6_K on the
seeded cases and the bigdiff, with no fabrication on the control.

No directional intuition is offered. Absent calibration data argues the
candidate is worse; a 6-bit quant is where imatrix gains are smallest; and the
template differences cut in an unrelated direction.

## Design

`scripts/review.sh` is untouched, so every arm runs at the same script sha as
its baseline, `40cf4941b7dc`. The quant file is the only variable.

| arm | label | baseline it is compared against | runs |
|---|---|---|---|
| small cases | `qwen38-t0-lmsq-det` | `qwen38-t0-det` | ×2 |
| bigdiff `--rounds 3` | `qwen38-t0-lmsq-r3` | `qwen38-t0-r3` | ×2 |

Cases: `swallow leak offbyone clean`, matching the baseline's list exactly.
`clean` is the fabrication control. Model id `qwen38-gguf-nothink-t0`
(temperature 0), provider `llamaserver`.

Two runs per arm, not one. Temperature 0 bought one-run-is-a-measurement in
`docs/sampling-noise-floor.md`, but that determinism was measured on the
Unsloth build; the second run is what establishes it for this one. Two
byte-identical runs, and a single run suffices for any later arm on this quant.

**Verifying what is served, before labeling.** `curl :8080/v1/models` cannot
distinguish these two — both serve under alias `qwen38-gguf-nothink`, which is
precisely the masquerade `scripts/llama_server.sh` guards against. The
discriminator is the model path in the llama-server startup log, which must
read `.lmstudio/models/lmstudio-community/`. Record it in the arm's log before
the first row is appended.

## Ship/revert rule

Baseline composition to beat or match, from `bench/results.tsv` and
`bench/results-bigdiff.tsv` at sha `40cf4941b7dc` (4 and 3 identical runs
respectively):

- small: `leak` quoted, `offbyone` quoted, `swallow` NOT quoted (exit 4 with a
  finding, but never the planted line), `clean` exit 0 with zero findings.
- bigdiff `--rounds 3`: all three of `import_after_guard`, `migrate_discard`,
  `export_exit0`, with zero non-bug findings.

**KEEP the lmstudio-community build as the default** only if all three hold
across both runs of each arm:

1. `clean` returns exit 0 with zero findings in every run.
2. Both `leak` and `offbyone` are quoted in every run.
3. All three bigdiff bug ids are hit in every run.

**REVERT to the Unsloth build** — repoint `DEFAULT_MODEL` in
`scripts/llama_server.sh` at `~/models/Qwen3.8-27B-Q6_K.gguf`, restore the
Unsloth URL in README step 1, port to the abe-skills mirror — if ANY of:

- a finding on `clean` in any run;
- `leak` or `offbyone` lost in any run;
- any of the three bigdiff bug ids missing in any run;
- either arm fails to produce a trustworthy verdict (exit 1, 3, or the 124
  watchdog) in any run.

**Trading catches is a loss, not a wash.** Gaining `swallow` while dropping any
baseline catch does not satisfy the keep rule; it re-enters the loop at step 1
as its own experiment with its own pre-registered rule. `swallow` is
informational here — the baseline misses it, so the candidate cannot lose it.

If the two runs of an arm disagree, the candidate is non-deterministic at
temperature 0 where the baseline was not. That is a finding in its own right,
recorded here, and it suspends the rule above rather than resolving it: the arm
grows runs until the noise floor is characterised.

## Measured results

Not yet run.
