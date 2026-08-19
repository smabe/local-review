# bench-row-hardening-resume — re-running the identical command finishes the arm (#1)

You are phase `resume` of the `bench-row-hardening` plan. You make all three
runners skip work already recorded, so an interrupted batch is completed by
re-running the exact same command — no invented continuation label, no
duplicate keys, no hand reconciliation of two or three labels at scoring time.

This phase lands last among the behavioural changes because its correctness
rests on an invariant the earlier phases establish: **a row exists iff the run
reached the model.** Do not start it until `status` carries values and the
fail-fast abort is in place.

## Locked decisions (do NOT re-litigate)

See `plans/bench-row-hardening.md` and `docs/bench-hardening-spec.md`. Summary:

- **`RUNS` means "ensure N rows exist for this key"**, not "dispatch N runs".
- **The skip predicate is key-existence, nothing more.** Because refusals write
  no per-run row, resume never needs to inspect `status`. This is what
  dissolves the #1-vs-#2 contradiction — do not reintroduce status-based skip
  logic.
- **The terminal abort row is not a key and must never be treated as one.**
  Phase `infra-status` writes it with a reserved non-numeric `run` value
  (`abort`) and an empty `case`/`item`. Build dispatch keys only from rows whose
  `run` is numeric; a terminal row then cannot match, with no status check. If
  you find yourself special-casing `status` here, the earlier phase got the
  terminal-row shape wrong — fix it there, not here.
- **Nothing is ever auto-retried.** `EMPTY-LOG`, `SCORE-ERROR`, `SUSPECT`,
  exit 3 and exit 124 are all terminal. Selectively resampling failures
  converts a failure rate into a success rate — and this is not hypothetical:
  `docs/rounds-experiment.md:49` counts one exit-3 no-verdict run inside the r6
  arm's composition, load-bearing in a shipped FAIL verdict.
- **No renumbering.** Run numbers are not monotone attempt ids.
  `bench/watch_ctx_tiers.py:122` iterates a fixed `range(1, RUNS+1)`, so a
  retry parked past that range is invisible to the watcher; and
  `watch_ctx_tiers.py:118` and `rescore_bigdiff.py:47-50` already resolve
  duplicates last-wins deliberately.
- **The key check is the FIRST thing in the loop body** — before
  `bench/run_bigdiff.sh:66`'s log rotation, which otherwise moves the
  transcript aside for every row it then skips, and `rescore_bigdiff.py` would
  report "no usable log" for the whole resumed arm.
- **Provenance guard:** compare recorded `sha` for the label against this
  batch's; abort on a **present and differing** value. A **missing** `sha`
  never triggers it — without that carve-out the guard bricks resume on all 385
  historical rows the day it ships.
- **Results-file lock**, same directory-based pattern `review.sh` uses, keyed
  on the results file.
- Report `label: N of M already recorded, dispatching K` on every invocation,
  and warn when recorded > requested.
- A short final line is **corruption, not a completed key**: skip it, warn, and
  start the next append on a fresh line.

## Read first

- `plans/bench-row-hardening.md` `## Findings log` — three phases of findings.
- `docs/bench-hardening-spec.md` "Resume" — the full rule set.
- `docs/rounds-experiment.md` "Run-provenance notes" and the r6 arm's
  composition — the incident that makes never-retry non-negotiable.
- `docs/bold-finder-experiment.md` — the label sprawl this phase removes.
- `bench/run_eval.sh:42-43` — the run/case loop; the key is
  `(label, case, run)`. `:52-53` — the checkout/apply that must not run for a
  skipped key.
- `bench/run_bigdiff.sh:45-49` — the run loop; the key is `(label, run)`;
  `:62-67` — the log rotation your check must precede.
- `bench/run_verify.sh:34-43` — the run/item loop; the key is
  `(label, item, run)`.
- `bench/rescore_bigdiff.py:38-59` — the deliberate last-wins owner map and the
  comment recording that first-wins got it backwards. Read this before deciding
  anything about duplicates.
- `bench/watch_ctx_tiers.py:114-122` — `total_steps`, hardcoded `RUNS = 2` at
  `:28`, and the fixed `range(1, RUNS+1)` that forbids renumbering.
- `scripts/review.sh:~200-215` — the `mkdir`-based lock and the rule that
  nothing reclaims a lock it did not create. **Read only; do not edit.**
- `bench/run_ctx_tiers.sh:141-153` — `LOCAL_REVIEW_ARM_SUITES`, the existing
  coarse per-suite resume knob, and the comment explaining it.

## Produce

1. **Failing tests first** — extend `tests/test_bench_runners.sh`.

   - **Fills exactly the gap.** Seed a results file with 2 of 4 keys, run with
     `RUNS` covering all 4, count stub invocations = 2 and final row count = 4.
   - **Idempotent.** Re-run the identical command against a complete arm →
     zero stub invocations, zero new rows, and a clear "already recorded"
     message.
   - **Smaller `RUNS` warns.** `RUNS=2` against a 3-row arm does nothing but
     says so loudly rather than printing success.
   - **Nothing is retried.** Seed rows carrying `status=EMPTY-LOG`,
     `status=SCORE-ERROR`, `status=SUSPECT` and `exit=124` → assert the stub is
     NOT invoked for any of those keys.
   - **End to end.** Stub signals its parent on run 2 to simulate an external
     kill, then re-run the identical command: exactly the missing runs execute,
     and `python3 bench/rescore_bigdiff.py --check` reports zero changes.
   - **Log rotation ordering.** For `run_bigdiff.sh`, seed a key plus its
     transcript, re-run, and assert the transcript was NOT rotated to `.prev`.
     This is the assertion that pins the check's position in the loop.
   - **Torn final line.** A results file whose last line is short → that key is
     re-run, a warning is printed, and the file afterwards contains no
     glued-together row.
   - **Provenance guard.** Seed rows with a `sha` differing from the current
     batch's → non-zero exit, zero rows appended, and a message naming both
     values. Then seed rows with an EMPTY `sha` (the historical case) → resume
     proceeds normally. Both directions matter; the second is what keeps the
     385 existing rows usable.
   - **Results-file lock.** Two concurrent invocations against the same results
     file → the second refuses cleanly rather than dispatching the same missing
     set.

2. **Implementation.**

   - A shared key-scan approach across the three runners: read the results
     file, map header names to indices (do **not** hardcode positions), build
     the set of existing keys, and skip any run whose key is present. Ignore —
     with a warning — any line whose field count differs from the header's.
     Read by name so the phase-`schema` tail cannot shift the key columns.
   - `bench/run_eval.sh`: key `(LABEL, case, run)`, checked at the very top of
     the `for c in $CASES` body at `:43`, before the checkout/apply at `:52-53`.
   - `bench/run_bigdiff.sh`: key `(LABEL, run)`, checked at the very top of the
     loop body at `:46`, **before** the reset/clean at `:49-50` and before the
     log rotation at `:62-67`.
   - `bench/run_verify.sh`: key `(LABEL, item, run)`, checked at the top of the
     item loop at `:36`.
   - Provenance guard: before the loops, compare the `sha` of existing rows for
     this label against the batch `sha` from phase `snapshot`. Abort on a
     present-and-differing value; treat empty or absent as no signal.
   - Results-file lock: mirror `review.sh`'s `mkdir`-based pattern, keyed on the
     results file path, released from an EXIT trap in which **every branch is a
     full `if`** and which never reclaims a lock it did not create.
   - `bench/README.md`: document resume, the meaning shift in `RUNS`, the
     never-retry rule and why, the provenance guard, and the relationship to
     `LOCAL_REVIEW_ARM_SUITES` — state explicitly which one an operator should
     reach for now, since row-level resume subsumes the coarse per-suite knob
     and leaving both undocumented invites re-running half an arm.

3. **Acceptance.**
   - Both gates green. **Gate invariant:** `fail=0`, and `pass` must not DECREASE against the same
     command run before this phase's changes. **Do not hard-code a pass count.**
     The pass/skipped split is checkout-dependent: from the main checkout with no
     mirror configured it reads `pass=98 fail=0 skipped=2` (the two drift checks
     skip because the default mirror path resolves to this same checkout), while
     from a git worktree the same two checks PASS and it reads
     `pass=100 fail=0 skipped=0`. **clu workers run in worktrees**, so asserting
     the 98/2 pair fails the gate through no fault of the change.
   - Re-running an interrupted command completes exactly the missing runs, adds
     no duplicate key, and needs no new label.
   - `python3 bench/rescore_bigdiff.py --check` clean afterwards.
   - `python3 bench/watch_ctx_tiers.py` still renders a resumed arm correctly —
     run numbers stayed within `range(1, RUNS+1)`.
   - A resumed arm's rows all share one `sha`.

4. **Commit + attest + complete.**
   - Append any cross-phase finding to `## Findings log`.
   - Commit: `bench: resume — re-running the identical command completes an
     interrupted arm (#1)`.
   - Stage: the three runners, `bench/README.md`,
     `tests/test_bench_runners.sh`.
   - After the commit: `clu verify` then `clu attest --simplify`, both with
     `--plan bench-row-hardening --phase resume --token <T>`.
   - `clu complete --project "$PROJECT_ROOT" --plan bench-row-hardening --phase resume --token <T>`.

## Failure modes to watch

- **Placing the key check after the log rotation** in `run_bigdiff.sh`. It
  moves the transcript to `.prev` for every key it then skips, and
  `rescore_bigdiff.py` reports "no usable log" for the whole resumed arm — you
  would destroy the durable evidence while adding a feature meant to protect it.
- **Renumbering from max+1.** `watch_ctx_tiers.py` iterates a fixed range with
  `RUNS` hardcoded to 2; a run numbered 3 in a two-run arm is invisible to the
  watcher and inflates the summarizer's per-arm counts.
- **Resuming off log-file existence instead of rows.** Cheaper and wrong twice:
  an interrupted run's orphan log makes that run permanently unrepeatable, and
  it destroys the log-without-row asymmetry the watcher uses to show which step
  is in flight — the only live-progress signal the bench has.
- **Retrying anything.** Every marker is terminal. The temptation is strongest
  for `EMPTY-LOG`; note the marker currently covers two unrelated events (a real
  21-minute run and a run where the server was down), and after phase
  `infra-status` only the first can produce a row at all.
- **The provenance guard firing on historical rows.** 385 rows have no `sha`. A
  missing value must never trigger the abort, or resume is bricked on the whole
  corpus the day it ships.
- **Hardcoding key column positions.** Phase `schema` widened every header; read
  by name.
