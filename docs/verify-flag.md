# --verify wiring — MEASURED, SHIPPED

Status: registered 2026-08-19 before any bench run; benched and SHIPPED the
same night per the pre-registered rule. Follow-up of the graduated capability
probe (`docs/verifier-pass.md`). Nothing between here and "Measured results"
was edited after the first run.

## Hypothesis

Wiring the measured verifier prompt into review.sh as an opt-in `--verify`
flag — one adversarial pi call per validated finding, refuted findings
dropped from the verdict — loses zero true findings end-to-end while
preserving every exit-contract guarantee.

## Design (pre-registered)

- `--verify` is opt-in and composes with the default pass, `--intent`, and
  `--angle` (verification is downstream of findings).
- The audit exports each VALIDATED finding block to
  `$LOCAL_REVIEW_FINDINGS_DIR` (set by review.sh only on `--verify`, only
  consumed when the audit's verdict is 4). Audit behaviour is otherwise
  byte-identical; without the env var nothing changes.
- Per finding: one pi call with the probe's verifier system prompt verbatim
  (it is the measured artifact), 3-round budget, verdict parsed portably
  (no sed alternation). Verdict `none` (no parseable verdict) counts as
  REAL — fail-open on retention, per probe rule 4.
- Output: after the review, a verification section lists each finding's FILE
  line, verdict, and the verifier's REASON. Refuted findings stay visible —
  dropped from the verdict, never from the evidence.
- Exit: >=1 survivor → 4 unchanged. All findings refuted → exit 0 with a loud
  note. The audit's 0/1/2/3 paths are untouched; a 3 never reaches
  verification.

## Bench arms

| arm | label | runs |
|---|---|---|
| default + --verify: offbyone, boolean, swallow, clean | `qwen38-nothink-vfy` | ×2 |
| angle + --verify: stalecomment | `qwen38-nothink-vfy-sc` | ×2 |

## Decision rule (pre-registered)

SHIP iff ALL of:
1. Zero refutations of any finding whose QUOTE contains the case marker
   (no true catch lost end-to-end). A run where the reviewer itself misses
   (audit 0 findings — swallow is historically flaky) is not a verify
   failure and does not count.
2. `clean` exits 0 in both runs.
3. Suite green including the new tests (flag parsing, audit export
   behaviour, verifier prompt pinned).

Otherwise revert the flag, keep everything, research before iterating.

## Measured results (2026-08-19, qwen38-gguf-nothink @ 49152, llama-server)

| arm | result |
|---|---|
| default + --verify: offbyone, boolean, swallow ×2 (`qwen38-nothink-vfy`) | 6/6 exit 4, marker found, verify 1/1 survived every run — zero catches lost. swallow (historically flaky) caught and retained both runs |
| default + --verify: clean ×2 | 0 findings both runs, exit 0 |
| angle + --verify: stalecomment ×2 (`qwen38-nothink-vfy-sc`) | 2/2 exit 4, marker found, verify 1/1 survived |

The verifier's REASON lines show constructed evidence, including live probes
(e.g. running `Store(path)` on corrupt bytes to confirm the UnicodeDecodeError
claim before retaining it). Decision rule conditions 1–3 all met → shipped.

Known bound, stated at ship: the bench exercised single-finding verdicts; the
export/loop handles N findings (finding-N.txt, pinned by an export test), but
a multi-finding end-to-end run was not part of the pre-registered arms. A
post-ship bigdiff + --verify integration run is recorded below when done.

## Post-ship hardening (same night, before first commit of the flag)

The high-effort code review of the wiring found and fixed, pre-commit:
- The verifier's event parser now carries the audit's truncation gate
  (stopReason must be "stop", no isError) — a reply cut off after
  "VERDICT: refuted" no longer counts as a refutation.
- Retention-safe verdict reduction: ANY "VERDICT: real" line wins; only an
  unambiguous refuted refutes; anything else fails open to real. (The prompt's
  own format reminder ends with "VERDICT: refuted", so the old tail -1 parse
  was refute-biased. The recorded probe outputs were clean two-liners, so the
  14/14 · 8/8 numbers are unaffected by the parse change; re-confirmed by the
  post-fix arm below.)
- The export moved inside the audit's exit-4 branch (a truncated exit-3 run
  can no longer export), takes the dir as argv[3] instead of an exported env
  var (no leak into pi's unsandboxed children), and is OSError-guarded (a full
  disk cannot eat an already-produced review).
- The verification section routes to stderr under --json, keeping the raw
  event stream pure JSONL; VRAW lives inside the trap-owned FDIR; the
  all-refuted path sets AUDIT=0 and falls through the single exit dispatcher.
- New tests: both exit paths end-to-end through a stubbed pi (all-refuted → 0,
  survivor → 4), real negative-export assertions (empty argv, truncated run),
  and a byte-parity check between the shipped and bench verifier prompts.

## Post-fix confirmation and the multi-finding run (2026-08-19, labels `qwen38-nothink-vfy-b2`, `-sc-b2`, `-big-b2`)

| arm | result |
|---|---|
| default + --verify: offbyone ×1 | caught, verify 1/1 survived, exit 4 |
| default + --verify: clean ×1 | 0 findings, exit 0 |
| angle + --verify: stalecomment ×1 | caught, verify 1/1 survived, exit 4 |
| bigdiff + --verify ×1 | **4 planted bugs found and all 4 retained** (migrate_discard, import_after_guard, cache_evict, export_exit0), zero fabrications, every verdict backed by a live probe; 1011s |

The bigdiff run is the first multi-finding verification end-to-end and the
best bigdiff catch recorded for this model — including `cache_evict`, the
frontier-gap bug with exactly one prior local catch ever. n=1: treat the
cache_evict catch as variance until repeated, per the context-tier analysis.

Two voided runs kept for the record: `qwen38-nothink-vfy-b` /
`-sc-b` rows (exit 1, 0s) were lock-refusals while the first bigdiff-verify
attempt held the model, and `qwen38-nothink-vfy-big` (exit 127) died because
review.sh was edited while that run's bash was still reading it — bash splices
mid-word on a changed file offset. The process rule adopted at the time — never
edit review.sh while a bench run is in flight — is now a historical note: each
bench batch copies `scripts/review.sh` once at batch start and runs the copy, so
editing the live file mid-batch can no longer reach a running review. **The
protection covers `review.sh` only.** The runners themselves are still read
incrementally by bash, so editing `bench/run_eval.sh`, `bench/run_bigdiff.sh` or
`bench/run_ctx_tiers.sh` mid-batch splices them exactly as this run was spliced.

Future work (filed, not shipped): a verify-aware bench scorer — run_eval's
columns predate verification and mis-read refuted-catch runs (see
bench/README's scoring caveat).
