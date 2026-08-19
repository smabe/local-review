# bench-row-hardening-scoring — stop counting runs that never reached the model as misses

You are phase `scoring` of the `bench-row-hardening` plan, and the last one.
`bench/summarize_ctx_tiers.py` computes the detection score with no exit filter,
so a run that never reached the model counts as a model miss. It is latent
today only because the tool's arm list happens to be three clean context tiers.
You close it, using the `status` column the earlier phases made meaningful.

This is an adjacent fix — no filed issue covers it. It was found during the
requirements debate and the operator approved fixing it here rather than
deferring, because this workstream already edits the file and automating that
manual exclusion is the point of the whole effort.

## Locked decisions (do NOT re-litigate)

See `plans/bench-row-hardening.md` and `docs/bench-hardening-spec.md`. Summary:

- **Exclude non-empty `status` and `exit == 1` rows** from BOTH the numerator
  and the denominator of the detection score.
- **Keep exit 3 and exit 124 counted as detection misses.** "Did it catch this
  defect" is answerable as no; "did it fabricate" is not answerable without a
  verdict. That asymmetry with the fabrication column is deliberate — it reads
  like a bug otherwise, so it needs a comment saying so.
- This is a **scoring** change. It does not touch a single row of recorded
  evidence, and it must not.

## Read first

- `plans/bench-row-hardening.md` `## Findings log` — four phases of findings.
- `bench/summarize_ctx_tiers.py:46-58` — the detection block.
  `catches = sum(int(r["found"]) for r in defects)` over `len(defects)`, with
  no exit filter. `:15-19` — the hardcoded `ARMS` list, which is why this is
  latent. `:20` — `DEFECT_CASES`.
- `bench/summarize_ctx_tiers.py:59-72` — the fabrication block immediately
  below, which DOES filter `exit in ("1","3","124")` and carries a comment
  explaining the reasoning. Read that comment: it reasons carefully about the
  fabrication column and simply never applies the same thought to detection.
  Your change completes it; your comment should say why the two columns
  legitimately differ.
- `bench/watch_ctx_tiers.py:77-106` — the live watcher's per-row verdicts.
  Check whether it needs the same treatment; if it does, fix it here, and if it
  does not, say why in the commit body.
- `docs/angle-stale-comment.md` "Measured results" — the operator's manual
  exclusion of 11 junk runs during the 2026-08-19 outage. That is the labour
  this phase automates; reference it in the README note.
- `bench/results.tsv` — the 8 `qwen38-nothink-anglSC` rows with `exit=1
  secs=0`. They are the concrete case, and they are NOT in `ARMS`, which is why
  no published number is wrong today.

## Produce

1. **Failing tests first** — extend `tests/test_bench_runners.sh`.

   - **Infrastructure rows leave the denominator.** Build a fixture arm with 4
     defect rows, 2 of them carrying a non-empty `status`. Assert the reported
     detection is `catches / 2`, not `catches / 4`.
   - **`exit == 1` rows leave the denominator** even with an empty `status`
     (the historical rows have no status at all — this is what makes the fix
     work retroactively on the existing corpus).
   - **Exit 3 and 124 STAY in the denominator.** A fixture with one exit-3
     defect row asserts it still counts as a miss. This pins the deliberate
     asymmetry so a later reader does not "fix" it.
   - **An arm reduced to zero scorable rows** reports something honest — not a
     `ZeroDivisionError`, and not a silent `0/0` that reads as a total miss.
     Decide the display and assert it.
   - **The fabrication column is unchanged.** Assert its existing behaviour
     still holds, so this change cannot have leaked across.

2. **Implementation.**

   - `bench/summarize_ctx_tiers.py`: filter `defects` to rows with an empty (or
     absent) `status` and `exit != "1"` before computing `catches` and the
     denominator. Use `.get("status", "")` — historical rows have no such
     column, and phase `schema` deliberately did not backfill them.
   - Add a comment beside it explaining why detection and fabrication filter
     different exit sets, referencing the reasoning in the block below. Without
     it the asymmetry looks like the very bug you just fixed.
   - Report the excluded count in the arm's output line, so an arm scored on 2
     of 4 rows says so rather than quietly reporting a rate over a smaller base.
   - `bench/watch_ctx_tiers.py`: apply the same treatment if its verdicts have
     the same hole; if not, leave it and say why in the commit body.
   - `bench/README.md`: document what the detection score now excludes, and
     note that pre-boundary rows are covered via the `exit == 1` clause since
     they have no `status`. Point at `docs/angle-stale-comment.md` as the
     incident this automates.

3. **Acceptance.**
   - Both gates green. **Gate invariant:** `fail=0`, and `pass` must not DECREASE against the same
     command run before this phase's changes. **Do not hard-code a pass count.**
     The pass/skipped split is checkout-dependent: from the main checkout with no
     mirror configured it reads `pass=98 fail=0 skipped=2` (the two drift checks
     skip because the default mirror path resolves to this same checkout), while
     from a git worktree the same two checks PASS and it reads
     `pass=100 fail=0 skipped=0`. **clu workers run in worktrees**, so asserting
     the 98/2 pair fails the gate through no fault of the change.
   - `python3 bench/summarize_ctx_tiers.py` runs against the real files and its
     three ctx-tier arms report **identical numbers to before this change** —
     all 30 of those rows exit 0 or 4, so a correct fix moves nothing. Capture
     the before/after output and diff it; any change means the filter is too
     broad.
   - Scoring a deliberately dirty arm by hand (point `ARMS` at
     `qwen38-nothink-anglSC` in a scratch copy) now excludes the 8 dead rows.
   - No `.tsv` file is modified by this phase.

4. **Commit + attest + complete.**
   - Append any cross-phase finding to `## Findings log`.
   - Commit: `bench: exclude runs that never reached the model from the
     detection score`.
   - Stage: `bench/summarize_ctx_tiers.py`, `bench/README.md`,
     `tests/test_bench_runners.sh`, and `bench/watch_ctx_tiers.py` only if you
     changed it.
   - After the commit: `clu verify` then `clu attest --simplify`, both with
     `--plan bench-row-hardening --phase scoring --token <T>`.
   - `clu complete --plan bench-row-hardening --phase scoring --token <T>`.

## Failure modes to watch

- **Filtering exit 3 and 124 out of detection too.** It looks symmetric with
  the fabrication column and it is wrong: a run that produced no usable verdict
  genuinely did not catch the defect. Removing those rows silently improves
  every arm that ever timed out.
- **Requiring the `status` column.** Historical rows do not have it; phase
  `schema` deliberately did not backfill. `.get("status", "")` plus the
  `exit == 1` clause is what makes the fix work on the existing corpus.
- **Changing a published tier number.** The three arms in `ARMS` are clean, so
  a correct fix moves nothing. If the before/after diff is non-empty, the
  filter is catching rows it should not.
- **Editing a `.tsv`.** This is a scoring change. No evidence row is touched.
- **Silently dividing by zero** when an arm has no scorable rows left, or
  printing `0/0` in a way that reads as a total miss.
