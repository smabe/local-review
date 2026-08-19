# bench-row-hardening — make bench rows trustworthy evidence (closes #1 #2 #3 #4 #5)

Five filed issues (#1–#5) that cannot ship separately. They collide on one
line: #4 and #5 both append columns "at the END" of the same three TSV
headers, #3 computes the checksum #5 wants as a column, and #1's resume key
must be read from whatever schema #4 and #5 land. Shipped as five PRs they
produce three row widths in one file and two cross-era boundaries in
`bench/README.md`.

The full design is settled in `docs/bench-hardening-spec.md` — the output of a
five-perspective requirements debate with cross-examination, every ruling
grounded in code. **That spec is the contract. Do not re-litigate it.** Where
it records a dissent, the dissent is already overridden and is preserved as
history, not as an open question.

Ordering is forced by the spec's own logic, not by preference. The snapshot
(p1) must exist before rows carry a checksum. The schema migration (p2) is
**one commit** landing all five columns across all three files. The status
column must be meaningful (p3, p4) before resume can rely on the invariant
that a row exists iff the run reached the model (p5). The scoring filter (p6)
depends on that same invariant, so it lands last.

## Diagnosis

Every phase here fixes a cause already established by measurement, not a
suspected one. Three claims were re-tested this session before this plan was
drafted:

- **Hypothesis:** widening a TSV header over narrow historical rows breaks the
  name-keyed readers.
  **Falsifiable test:** zip a 13-name header against a 9-field row in a repl.
  **Result:** DISPROVED as stated — `zip` truncates front-aligned, so all nine
  original keys resolve correctly and only the new names are absent. The real
  hazard is the opposite direction (a stale narrow header silently DROPS new
  fields). This inverted the migration decision; see spec, "Migration".
- **Hypothesis:** infrastructure rows are counted as model misses in the
  detection score.
  **Falsifiable test:** read `bench/summarize_ctx_tiers.py:54-55` and check for
  an exit filter.
  **Result:** CONFIRMED — `catches = sum(int(r["found"]) for r in defects)`
  over `len(defects)`, no exit filter, while `:65-66` immediately below DOES
  filter exits 1/3/124 out of the fabrication column. Latent only because
  `ARMS` (`:15-19`) is hardcoded to three clean ctx tiers. Phase 6.
- **Hypothesis:** the runners can be exercised in tests without a model.
  **Falsifiable test:** copy a runner to a temp dir, symlink its fixtures,
  point `LOCAL_REVIEW_SH` at a stub, run a batch.
  **Result:** CONFIRMED — every output path derives from `EVAL_DIR`
  (`run_eval.sh:10-13`, `run_bigdiff.sh:19-23`, `run_verify.sh:7-9`), so a
  relocated runner writes everything into the temp dir. No new seam needed.

## Locked design decisions

All of these are settled in `docs/bench-hardening-spec.md`; this section is the
worker-facing summary. Read the spec for the reasoning and the rejected
alternatives.

### Cross-cutting invariants (every phase)

- **A *dispatchable* results row exists if and only if the run reached the
  model.** An attempt refused before dispatch is not a row. This is what
  dissolves the #1-vs-#2 contradiction with no special-case logic.
- **The one row that is not a measurement is reconciled by SHAPE, not by
  exception.** When a batch stops on infrastructure it writes a single terminal
  abort row, carrying a reserved non-numeric `run` value (`abort`) and an empty
  `case`/`item`. It is therefore not a dispatchable key, and resume's
  numeric-key scan can never match it — which is what keeps resume free of any
  status inspection. Get this shape wrong and an aborted batch poisons the key
  it failed on forever, reintroducing the exact deadlock this workstream exists
  to dissolve.
- **A run that reached the model is never re-run.** Selectively resampling
  failures converts a failure rate into a success rate.
- **`status` is a scoring concern, never a resume concern.** Resume's predicate
  is plain key-existence.
- Portability is hard: bash 3.2, macOS + Linux, `mktemp` with an explicit
  `.XXXXXX` template, BSD+GNU `sed` only (no `\|` alternation), every EXIT-trap
  branch a full `if` (see `CLAUDE.md`).
- **Do not touch `scripts/review.sh` or `tests/test_local_review_audit.sh`.**
  They are byte-identical with `~/projects/abe-skills/skills/local-review/`. No
  phase here should need to; if one appears to, that is a signal to re-check
  the approach, and any such change must be ported verbatim.

### Phase 1 — snapshot (#3)

- **One copy per batch, never per run.** An experiment measures one script
  version; a per-run copy lets a mid-batch edit change the measured artifact
  silently.
- **Location `bench/logs/`, keyed uniquely per batch, and KEPT.** Not `/tmp`,
  not deleted. `bash "$SNAPSHOT"` sets the script's reported path to the
  snapshot, so the `line 408: ll: command not found` error class this fixes is
  reported against that path — it must still exist when someone reads the
  `.err`. Never derive the name from the label alone: a reused path silently
  re-measures the previous batch's script.
- **Honour `LOCAL_REVIEW_SH`:** set means the caller already pinned a script —
  use as-is, do not re-snapshot, do not delete. Unset means snapshot and own it.
- **`run_ctx_tiers.sh` takes ONE snapshot and pins it across both suites.**
  Otherwise one tier arm measures two separately-taken snapshots — #5's
  cross-session misattribution reproduced inside one label.
- **Checksum needs a `shasum` / `sha256sum` two-way fallback.** `shasum` is
  perl (macOS yes, minimal Linux no); `sha256sum` is coreutils (the reverse).
  The repo has no existing checksum idiom to copy.
- Verified safe: `review.sh` never references its own location after startup
  and cds to the reviewed repo's toplevel (`scripts/review.sh:143`).
- **#3's third acceptance bullet is overstated and is NOT adopted.** The
  "never edit mid-bench" rule is narrowed to review.sh, not retired — bash
  reads the runners incrementally too, and the snapshot does not protect them.

### Phase 2 — schema (#4, #5)

- **One commit, all five columns, all three files.** Shared tail in this exact
  order: `status date sha vsurv vtotal`.
- `results-verify.tsv` gets `status date sha` **only**. It *is* the verifier
  probe — its `verdict` column already carries the survivor signal, and a
  permanently-empty column trains readers to skim past emptiness.
- **Widen line 1 by hand in the migration commit. Do NOT backfill.** No reader
  requires uniform width; backfilling asserts "no verify data" for runs whose
  data still exists in `bench/logs/*.err`. The invariant to assert is
  `NF <= header NF`, not equality.
- **Empty cells are the empty string.** Not `-` (already live in bigdiff's
  `bugs` column meaning "zero known bugs matched", `bench/score_bigdiff.py:122`),
  not `NA` (one edit from a numeric column with three unguarded `int()` casts).
- **`vsurv`/`vtotal` are EMPTY, not `0`, when verification did not run.**
  Specifying them as integers defaulting to 0 destroys the exact distinction #4
  was filed to create: an all-refuted run is `exit=0` with `vtotal=N`; a clean
  run is `exit=0` with `vtotal` empty.
- **The parse target in #4 is mis-stated.** `review.sh:679` emits through a
  helper that prefixes `local-review: `, so a sed anchored `^verify:` matches
  nothing on every run. Copy the leading `.*` idiom already used by the `nfind`
  scrape at `run_eval.sh:96`.
- `date` is `date +%F` written **per row at append time**. `sha` is computed
  **once per batch**, from the snapshot that actually executed.
- Bundled here: the atomic-write fix for `bench/rescore_bigdiff.py:97`
  (`write_text` with no temp+rename), because this phase already edits that
  file.

### Phase 3 — infra-status (#2)

- **Allowlist, not blocklist.** The audit footer (`scripts/review.sh:556-557`)
  is emitted before all five audit exit paths, so *footer present ⇔ a
  measurement happened*. #2's two-signature grep would still have missed the
  third failure from the same night (the exit-127 splice).
- **Classifier precedence, and the order is load-bearing:** `rc == 124` FIRST
  (status empty — the watchdog kills review.sh *before* its audit block, so a
  timed-out run has no footer and a naive footer rule misclassifies it), then
  footer present (status empty), then anchored `^local-review: ` grep of the
  `.err` for the reachability (`review.sh:165`) or lock (`review.sh:214`)
  signature → terminal row + abort, else `SUSPECT`.
- **Anchor the grep.** Model-derived free text reaches stderr (verdict reasons
  under `--json`, a single-word flag reachable through the runners' arg
  passthrough), and a reviewed diff could contain the phrase literally.
- **Never retype the signatures.** Extract them from `review.sh` in a drift
  test, mirroring the verifier-prompt parity check at
  `tests/test_local_review_audit.sh:305-318`.
- **A pre-dispatch refusal writes NO per-run row.** The batch writes exactly
  ONE terminal row whose `status` is the cause (`SERVER-DOWN` or `LOCKED`), and
  aborts with a distinct exit code meaning "infrastructure, nothing recorded,
  re-run the identical command" — separate from the existing exit 2, which
  means "fixture invalid, do not resume".
- `SUSPECT` is the open bucket and is **not optional**: OOM, pi crash,
  model-unload race and disk-full all land as a plain `rc != 0`, and a blank
  `status` a reader trusts is worse than an explicit unknown.
- The probe proves a port answers, **nothing more**. Probe only between runs,
  and retry before declaring down — a single-shot short-timeout probe against a
  loaded machine mid-prefill can kill a healthy 40-minute arm.
- Migrate `EMPTY-LOG` / `SCORE-ERROR` out of `bugs` into `status` for new rows;
  historical rows keep theirs and are covered by the cross-era note.
- **Any new env override must be added to `run_ctx_tiers.sh:25-26`'s unset
  list** in the same phase, with a test — that list is how a tier arm
  guarantees it measured the default configuration, and it has no test today.

### Phase 4 — verify-runner (#2 for the third runner)

- `run_verify.sh:51-54` invokes `pi` synchronously with **no `&`, no rc
  capture, and no watchdog** — unlike both other runners. A dead server there
  yields `verdict=none`, `agree=0` (`:78-79`): recorded as the verifier
  *disagreeing with ground truth*, a wrong answer rather than a missing one.
- It needs an rc and a watchdog **before** infrastructure marking can mean
  anything. Mirror the watchdog shape from `run_eval.sh:67-94` verbatim
  (deepest-descendant TERM, marker-file timeout keying, 30s grace).
- **No review-script snapshot and no verify columns here** — it never invokes
  `review.sh`, so there is nothing to snapshot and no `verify:` line to parse.
  Its `sha` is its own checksum.
- Do not add a second variable whose name ends in `SYSTEM_PROMPT='` above
  `:12`: `tests/test_local_review_audit.sh:306-316` locates the verifier prompt
  by first occurrence, and anything above it silently redirects that assertion.

### Phase 5 — resume (#1)

- **`RUNS` means "ensure N rows exist for this key"**, not "dispatch N runs".
- **Skip predicate is key-existence, nothing more.** Rows only exist for
  attempts that reached the model (p3/p4), so no status inspection is needed.
- **Nothing is ever auto-retried.** `EMPTY-LOG`, `SCORE-ERROR`, `SUSPECT`, exit
  3 and exit 124 are all terminal. `SCORE-ERROR` is repaired by
  `rescore_bigdiff.py` from the saved transcript.
- **No renumbering.** `watch_ctx_tiers.py:122` iterates `range(1, RUNS+1)`, so a
  retry parked past that range is invisible; and both
  `watch_ctx_tiers.py:117` and `rescore_bigdiff.py:48-50` already resolve
  duplicates last-wins deliberately.
- **The key check is the FIRST thing in the loop body** — before
  `run_bigdiff.sh:66`'s log rotation, which otherwise orphans the transcript
  for every row it skips.
- Report `label: N of M already recorded, dispatching K` every invocation, and
  warn when recorded > requested.
- A final line with fewer fields than the header is **corruption, not a
  completed key**: skip, warn, start the next append on a fresh line.
- **Provenance guard:** before dispatching, compare recorded `sha` for the
  label against this batch's; on a **present and differing** value, abort and
  say why. A **missing** `sha` never triggers it — without that carve-out the
  guard bricks resume on all 385 historical rows the day it ships.
- **Results-file lock**, same directory-based pattern `review.sh` already uses
  (`scripts/review.sh:~203-214`), keyed on the results file.

### Phase 6 — scoring (adjacent fix, operator-approved)

- Exclude non-empty `status` and exit-1 rows from both numerator and
  denominator of the detection score in `bench/summarize_ctx_tiers.py:54-55`.
- **Keep exit 3 and 124 counted as detection misses.** "Did it catch this" is
  answerable as no; "did it fabricate" is not answerable without a verdict.
  That asymmetry with the fabrication column at `:65-66` is deliberate —
  document it in a comment, because it reads like a bug otherwise.

## Non-goals

- **No changes to `scripts/review.sh`.** Every signature and stderr line this
  workstream parses already exists there. Touching it would force a verbatim
  port to the private mirror for no gain. *(Asymmetry rationale: review.sh is
  the product; bench/ is the instrument. Hardening the instrument does not
  require changing the thing it measures.)*
- **No changes to `tests/test_local_review_audit.sh`.** Same byte-identity
  reason; the new bench tests live in their own public-only file. *(Asymmetry
  rationale: that suite tests review.sh, which this workstream does not
  change.)*
- **No backfill of the 385 historical rows.** Settled in the spec.
- **No unified results file across the three runners.** Their primary keys are
  `(label,case,run)`, `(label,run)` and `(label,item,run)`; merging makes the
  key nullable and forces synthetic values onto every existing row. A shared
  column SUFFIX is the reachable common ground: `label`, `run` and `secs` recur
  by name across the three headers, but only `label` sits at the same position
  in all three (`run` is at index 2, 1 and 2), so no common PREFIX is reachable
  without rewriting all 385 rows.
- **No config-fingerprint column.** `sha` pins the script and, because the
  prompts are embedded in it, the prompt version — but not the model id, the
  context tier, or `models.json`'s `contextWindow`. Document the limit; a
  broader fingerprint has no second caller. *(Asymmetry rationale: the ctx-tier
  arms are the only place where two rows with identical `sha` are genuinely
  incomparable, and `run_ctx_tiers.sh:130-138` already asserts the served
  context for exactly that reason.)*
- **Not retiring the "never edit mid-bench" rule**, only narrowing it to
  review.sh. #3's third acceptance bullet overstates the fix.
- **No `bench/incidents.tsv`.** Rejected in the spec on the repo's own
  precedent: `bench/results-v1-ambiguous-prompt.tsv` exists, is committed, and
  no tool reads it.

## Files touched

- `bench/run_eval.sh` — P1, P2, P3, P5 modified — snapshot, five columns, classifier + abort, resume. API hotspot: TSV row shape; the `LOCAL_REVIEW_*` env contract.
- `bench/run_bigdiff.sh` — P1, P2, P3, P5 modified — same four changes. API hotspot: TSV row shape.
- `bench/run_verify.sh` — P2, P4, P5 modified — three columns, rc + watchdog + classifier, resume. **Do not add any `SYSTEM_PROMPT='`-suffixed variable above line 12** (breaks the parity extraction in the byte-identical suite).
- `bench/run_ctx_tiers.sh` — P1, P3 modified (P4 evaluates it and deliberately leaves it alone) — one snapshot pinned across both suites; new env knobs added to the unset list at `:25-26`.
- `bench/rescore_bigdiff.py` — P2 modified — `.get()` for new names, index-stability assertion, atomic temp+rename write.
- `bench/summarize_ctx_tiers.py` — P2, P6 modified — `.get()` for new names; detection-score filter. API hotspot: `ARMS` is hardcoded at `:15-19`.
- `bench/watch_ctx_tiers.py` — P2 modified, P6 conditionally — `.get()` for new names; P6 applies the detection filter here too only if the same hole exists, and records the answer either way.
- `bench/score_bigdiff.py` — P3 modified — `EMPTY-LOG` routed to `status` instead of `bugs`.
- `bench/results.tsv` — P2 modified — header line only, 9 → 14 columns.
- `bench/results-bigdiff.tsv` — P2 modified — header line only, 8 → 13 columns.
- `bench/results-verify.tsv` — P2 modified — header line only, 8 → 11 columns.
- `bench/README.md` — P1, P2, P3, P4, P5, P6 modified — column docs, the cross-era note, marker vocabulary, resume behaviour, the runner exit table.
- `tests/test_bench_runners.sh` — P1 NEW, P2–P6 modified — the second gate. Public-repo only.
- `CLAUDE.md` — P1 modified — add the second gate to the Commands block.
- `docs/verify-flag.md` — P1 modified — narrow the "never edit mid-bench" rule to a historical note scoped to review.sh.
- `docs/bench-hardening-spec.md` — **currently untracked; it is committed in
  the same commit as these plan files, before `clu init`.** Every phase reads
  it, and worktree workers branch off HEAD — if it is not committed first, all
  six phases lose their contract. Read-only for every phase thereafter.

## Per-phase done checklist

- TDD: failing tests first, in `tests/test_bench_runners.sh`.
- `/code-review` after if diff >1 file or ~30 lines.
- **Both gates green before commit:** `bash tests/test_local_review_audit.sh`
  and `bash tests/test_bench_runners.sh`. The invariant is `fail=0` with no
  DECREASE in `pass` against the same command before your change. **Do not
  hard-code a pass count**: the pass/skipped split is checkout-dependent —
  `pass=98 fail=0 skipped=2` from the main checkout with no mirror configured
  (the two drift checks skip because the default mirror path resolves to that
  same checkout), and `pass=100 fail=0 skipped=0` from a git worktree, where
  those same two checks pass. **clu workers run in worktrees.** Measured both
  ways 2026-08-19. Report both footers in the commit body.
- Structured commit format (Title / Why / What's new / Under the hood / Tests /
  `Co-Authored-By:` trailer).
- Stage explicit paths (no `git add -A`). **Never `git add` inside a bench
  fixture repo.**
- **You are in a worktree.** `$WORKTREE_ROOT` is where git ops and edits happen;
  `$PROJECT_ROOT` (the canonical checkout on `main`) is where clu's state lives,
  which is why every `clu` callback below carries `--project "$PROJECT_ROOT"`.
  Never `cd $PROJECT_ROOT` to commit — that lands the commit on `main` and the
  next phase dispatches off a stale branch tip.
- **Stamp attestations AFTER the commit** (the gate compares stamp SHA against
  HEAD):
  - `clu verify --project "$PROJECT_ROOT" --plan bench-row-hardening --phase <id> --token <T>`
  - `clu attest --simplify --project "$PROJECT_ROOT" --plan bench-row-hardening --phase <id> --token <T>`
- `clu complete --project "$PROJECT_ROOT" --plan bench-row-hardening --phase <id> --token <T>`.

## Sessions index

| Session | Plan file | Scope | Effort |
|---|---|---|---|
| snapshot | `bench-row-hardening-snapshot.md` | Batch-start review.sh snapshot + checksum; new test gate scaffolding (#3) | 2h |
| schema | `bench-row-hardening-schema.md` | One-commit header migration, all five columns, three TSVs, four readers (#4 #5) | 3h |
| infra-status | `bench-row-hardening-infra-status.md` | Footer allowlist classifier, fail-fast probe, terminal abort row (#2) | 3h |
| verify-runner | `bench-row-hardening-verify-runner.md` | rc capture + watchdog for run_verify.sh, then its classifier (#2) | 2h |
| resume | `bench-row-hardening-resume.md` | Resume in all three runners, provenance guard, results-file lock (#1) | 3h |
| scoring | `bench-row-hardening-scoring.md` | Detection-score filter excludes runs that never reached the model | 1h |

## Verification record

Pre-ship adversarial pass, 2026-08-19. Three read-only auditors over the drafts
plus one worktree prober that built phase `snapshot` for real.

- grounding: 70 claims checked, 1 fixed (the "headers align only on `label`"
  Non-goal overclaimed — `run` and `secs` recur by name), 0 promoted, 0 refuted;
  4 uncheckable (spec sub-section bodies, one historical anecdote, two
  loosely-bundled comment-range citations)
- executability: 26 acceptance items across 6 sub-plans, 53 Read-first pointers
  and 16 Files-touched entries checked; 2 fixed (the spec was untracked while
  the master called it committed; `schema` told the worker to stage "four
  Python tools" and named three), 0 promoted. Ordering chain verified as a true
  dependency chain, not an asserted one.
- coherence: 14 stated rules walked against their mechanisms, 14 cross-file
  restatements, 3 contradictions fixed — the terminal abort row contradicted
  the headline invariant and would have let resume skip a failed key forever;
  `infra-status`'s unset-list completeness test was scoped to fail
  `verify-runner`; two conditional file touches were missing from Files touched.
- prober (snapshot): files LISTED 7 / MISSING 0; both gates green (35 new
  assertions). Three SKETCH fixes applied — the prescribed `mktemp` template put
  the X's mid-name, which on BSD `mktemp` creates a literal filename and makes
  every later batch fail "File exists" (reproduced independently before
  accepting); two placement instructions named lines before their variables
  exist; and the `cleanup()` instruction was a no-op. One MEASURED fix: the
  test-gate acceptance number was unreachable in a worktree, which is where
  every clu worker runs. One workaround declared and accepted (a `PATH` shim to
  reach the checksum fallback, in preference to adding a production knob whose
  only caller is a test). Two behaviour losses recorded into the phase rather
  than left implicit.

## Findings log

- **2026-08-19 (snapshot).** A clu worker **cannot run
  `bash tests/test_local_review_audit.sh` from its own Bash tool.** That suite's
  `mktemp -d` at `:23` has no template, and macOS resolves the no-template form
  through `_CS_DARWIN_USER_TEMP_DIR` (`/var/folders/…`) while ignoring `TMPDIR`
  entirely — a path the worker's tool sandbox denies, so the suite dies at line 37
  before a single assertion. **`clu verify` is NOT affected** (measured: it
  verified this phase's commit, running the same suite, from the same worker), so
  the gate itself is sound and this is only about a worker's own interactive runs.
  Workaround if you need the footer in-session: a `PATH` shim redirecting the
  no-template `mktemp -d` into `$TMPDIR`, which yields
  `pass=100 fail=0 skipped=0`. The one-line real fix is the idiom
  `scripts/review.sh:400` already uses (`mktemp -d "${TMPDIR:-/tmp}/….XXXXXX"`),
  but that suite is byte-identical with the private mirror and is a **stated
  Non-goal** here, so no phase may make it. `tests/test_bench_runners.sh` uses the
  TMPDIR-honouring form and runs natively either way.
- **2026-08-19 (snapshot).** `review_sha()` is now hand-duplicated in all three
  runners, and it **drifted between the first and second review round of this very
  phase** (the `rm -f`-on-refusal cleanup landed in `run_eval.sh` and
  `run_bigdiff.sh` but was missed in `run_ctx_tiers.sh`, leaving an orphan copy
  that the resume branch would then adopt). That is the rule-of-three threshold
  with the failure already demonstrated rather than predicted. Not extracted here:
  a shared `bench/` library is cross-cutting — it changes the relocation contract
  in `tests/test_bench_runners.sh` that phases 2–6 build their own tests on — and
  the plan's Files-touched list does not carry it. **Scope for whoever takes it:
  extract the snapshot/checksum block into one sourced `bench/` helper, add it to
  the test harness's per-runner fixture list, and do it in a phase that already
  edits all three runners (2, 3 or 5).**
- **2026-08-19 (snapshot).** Two behaviours the old shape provided that this one
  does not, per the sub-plan's instruction to state them rather than let a later
  phase rediscover them. (1) `REVIEW` used to be the single name for "the script
  under test"; it is now split into `REVIEW_SRC` (the tracked source) and
  `REVIEW_RUN` (the frozen copy that actually executes). The old name is gone
  from all three runners on purpose — a stale `$REVIEW` grep now finds nothing
  rather than the wrong one. (2) The path named in a run's `.err` used to be a
  tracked file whose history survived `rm -rf bench/logs`; it now names a
  gitignored copy. A durability guarantee became a convention, written down in
  `bench/README.md`: snapshots are deleted only together with the transcripts
  that reference them, never before.
- **2026-08-19 (snapshot).** `run_ctx_tiers.sh` keys its snapshot on the label
  (`logs/$LABEL-review.sh`) and **reuses it when present**, which reads like a
  violation of "never derive the snapshot name from the label alone" but is the
  opposite case. `LOCAL_REVIEW_ARM_SUITES` exists to finish a half-done arm in a
  *second invocation*; a fresh snapshot there would make one label's eval rows and
  bigdiff rows measure two different scripts — this workstream's own failure mode,
  surviving inside the one workflow built for resuming. Reuse is announced on
  stderr, never silent. The two batch runners keep random `mktemp` names, where the
  locked rule applies unchanged. **Phase 5 (resume) should treat this as prior
  art**, and phase 2's `sha` column will make a same-label re-run visible in the
  rows for the first time.
- **2026-08-19 (snapshot).** A batch that cannot checksum its script exits **2**,
  reusing the existing "refused before dispatch, nothing recorded" code rather
  than inventing one. Phase 3 introduces a distinct infrastructure exit code and
  should decide then whether a missing `shasum`/`sha256sum` belongs there instead
  — it is an environment fault, not the fixture fault exit 2 otherwise means.
