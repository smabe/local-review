# bench-row-hardening-verify-runner — give the verifier probe an exit code (#2)

You are phase `verify-runner` of the `bench-row-hardening` plan. `run_verify.sh`
is the only runner that never captures an exit status and has no watchdog, so
today a dead server there is recorded as the verifier *disagreeing with ground
truth* — a wrong answer rather than a missing one, biasing the arm
pessimistically with nothing in the row to catch it. You build the missing
pieces, then apply the phase `infra-status` classifier.

## Locked decisions (do NOT re-litigate)

See `plans/bench-row-hardening.md` and `docs/bench-hardening-spec.md`. Summary:

- **`run_verify.sh` never invokes `review.sh`** — it drives `pi` directly at
  `:51-54`. So: **no review-script snapshot** and **no `vsurv`/`vtotal`
  columns** here. Both exclusions are deliberate and already justified; its
  `sha` is its own checksum, added in phase `schema`.
- **rc and watchdog first, classifier second.** Infrastructure marking cannot
  mean anything until the runner can tell that a run failed.
- **Mirror the watchdog from `run_eval.sh:67-94` verbatim in shape:** background
  the run, TERM the deepest descendant first (pi is a node process and does not
  respond to its own name), 30-second grace, then TERM the wrapper. Key `rc=124`
  on a **marker file**, never on elapsed wall clock — `date +%s` advances across
  a lid-close while `sleep` does not, so elapsed seconds alone rewrite a genuine
  verdict into a timeout after any suspend.
- **The footer allowlist does not apply here.** There is no `review.sh` audit
  footer; `run_verify.sh` parses `pi`'s event stream itself at `:58-71`. The
  measurement signal is an extracted verdict: a run that produced a parseable
  `VERDICT:` line reached the model.
- **`verdict=none` must stop being ambiguous.** Today it means both "the model
  answered something unparseable" and "nothing ran at all". After this phase
  the second case carries a non-empty `status` and the first does not.
- **Do not add any variable whose name ends in `SYSTEM_PROMPT='` above line 12.**
  `tests/test_local_review_audit.sh:306-316` locates the verifier prompt by
  first occurrence of that marker and would silently begin comparing the wrong
  literal — while staying green. That check is the only thing keeping the bench
  verifier numbers quotable.

## Read first

- `plans/bench-row-hardening.md` `## Findings log` — phases `snapshot`,
  `schema` and `infra-status` will have recorded things you need.
- `docs/bench-hardening-spec.md` "Scope rulings" — why this runner is in scope
  and what is excluded from it.
- `bench/run_verify.sh` in full (84 lines). Specifically `:34-40` (the run/item
  loops and meta parsing), `:49-54` (the synchronous `pi` invocation with no
  `&`, no rc, no watchdog — the defect), `:58-71` (the embedded Python that
  extracts the last assistant text block), `:75-79` (verdict reduction and the
  `agree` computation), `:80-81` (the row append).
- `bench/run_eval.sh:63-94` — the watchdog to mirror, including the comments at
  `:68-70` and `:72-78` explaining why it TERMs the deepest descendant and why
  the timeout is marker-keyed rather than clock-keyed.
- `bench/run_verify.sh:12-24` — the system prompt literal. Note its position;
  keep anything you add below it.
- `tests/test_local_review_audit.sh:303-318` — the parity check that depends on
  that position, and the `skip` pattern.
- Whatever phase `infra-status` implemented in `run_eval.sh` — reuse its
  classifier and probe rather than writing a second one.

## Produce

1. **Failing tests first** — extend `tests/test_bench_runners.sh`.

   The seam here is `PATH`, not `LOCAL_REVIEW_SH`: `run_verify.sh` calls `pi`
   directly, so a stub `pi` on `PATH` is the injection point — exactly as
   `tests/test_local_review_audit.sh:490-511` already does.

   - **rc is captured.** A stub `pi` that exits non-zero → the row records it;
     assert the run is not silently scored as a disagreement.
   - **Watchdog fires.** A stub `pi` that sleeps past a short timeout override →
     `rc=124` behaviour, marker-keyed, and the batch continues rather than
     hanging.
   - **Dead server is not a disagreement.** A stub that produces no output and
     fails → a non-empty `status`, and the row is **not** counted as
     `agree=0` against ground truth. This is the specific misreading the phase
     exists to remove.
   - **A genuine unparseable answer still reads as `verdict=none` with empty
     `status`** — the model answered, it just did not answer in the required
     shape. Assert the two cases are now distinguishable in the row.
   - **Lock refusal and server-down** behave as in phase `infra-status`: one
     terminal row, batch aborts, new exit code.
   - **Parity guard.** Assert `tests/test_local_review_audit.sh`'s verifier
     parity check still passes after your edits — run the suite and confirm
     `fail=0` with no drop in `pass` (see the gate invariant in Acceptance;
     do not hard-code a count). If you added anything above line 12 this
     will still be green while comparing the wrong literal, so **also** assert
     directly that the first occurrence of `SYSTEM_PROMPT='` in
     `run_verify.sh` is the verifier prompt.

2. **Implementation.**

   - `bench/run_verify.sh`: background the `pi` invocation at `:51-54`, capture
     `rc` via `wait`, and add the watchdog from `run_eval.sh:67-94` with a
     `LOCAL_REVIEW_VERIFY_TIMEOUT` override (default matched to the runner's
     typical item cost, not to the 900 s small-case default — verifier items
     are single findings and are much faster).
   - Add the pre-dispatch probe and the classifier from phase `infra-status`,
     with the footer step replaced by "a `VERDICT:` line was extracted".
   - Make `verdict=none` set a non-empty `status` only when nothing ran;
     leave it empty when the model answered unparseably.
   - Do **not** add the new timeout knob to `bench/run_ctx_tiers.sh`'s unset
     list. That orchestrator dispatches only `run_eval.sh` and `run_bigdiff.sh`
     (`:148-153`), so a `run_verify.sh`-only knob would be a dead entry, and
     phase `infra-status`'s completeness test is scoped to the dispatched
     runners precisely so this is not a violation. Leave a one-line comment in
     `run_verify.sh` recording why.
   - `bench/README.md`: document the verifier runner's exit and status
     behaviour, and state the two deliberate exclusions (no snapshot, no verify
     columns) with their one-line reasons so the asymmetry is not read as an
     oversight.

3. **Acceptance.**
   - Both gates green. **Gate invariant:** `fail=0`, and `pass` must not DECREASE against the same
     command run before this phase's changes. **Do not hard-code a pass count.**
     The pass/skipped split is checkout-dependent: from the main checkout with no
     mirror configured it reads `pass=98 fail=0 skipped=2` (the two drift checks
     skip because the default mirror path resolves to this same checkout), while
     from a git worktree the same two checks PASS and it reads
     `pass=100 fail=0 skipped=0`. **clu workers run in worktrees**, so asserting
     the 98/2 pair fails the gate through no fault of the change.
   - A dead server during a verify batch produces a terminal row and an abort,
     never a full set of `agree=0` rows.
   - `bench/results-verify.tsv`'s existing 26 rows are untouched.
   - The first `SYSTEM_PROMPT='` occurrence in `run_verify.sh` is still the
     verifier prompt.

4. **Commit + attest + complete.**
   - Append any cross-phase finding to `## Findings log`.
   - Commit: `bench: give run_verify.sh an exit code, a watchdog, and
     infrastructure status (#2)`.
   - Stage: `bench/run_verify.sh`, `bench/README.md`,
     `tests/test_bench_runners.sh`, and `bench/run_ctx_tiers.sh` only if you
     actually changed it.
   - After the commit: `clu verify` then `clu attest --simplify`, both with
     `--plan bench-row-hardening --phase verify-runner --token <T>`.
   - `clu complete --plan bench-row-hardening --phase verify-runner --token <T>`.

## Failure modes to watch

- **Adding a variable above line 12 whose name ends in `SYSTEM_PROMPT='`.** The
  byte-identical suite's parity extraction takes the FIRST occurrence. The
  failure is silent and green, and it invalidates every quoted verifier number.
- **Keying the timeout on elapsed seconds instead of a marker file.**
  `run_eval.sh:72-78` documents why: `date +%s` advances across a suspend while
  `sleep` does not, so a lid-close rewrites a genuine verdict into a timeout.
- **A machine-wide `pkill`.** The existing watchdogs deliberately TERM the
  deepest descendant of this run only, and never `KILL`, because a `KILL` can
  orphan the model lock.
- **Collapsing "unparseable answer" and "nothing ran" into one `status`.** They
  are opposite facts: the first is a model result worth keeping, the second is
  infrastructure. The whole point of the phase is telling them apart.
- **Reaching for `review.sh`'s audit footer here.** There is none — this runner
  parses `pi`'s stream itself.
