# Bench row hardening — consensus specification

Resolves GitHub issues #1–#5 as **one workstream**, not five. Produced by a
five-perspective requirements debate (2026-08-19) with cross-examination;
every ruling below is grounded in code read that session. Dissents are
recorded at the end and are not to be deleted.

The issues collide: #4 and #5 both append columns "at the END" of the same
headers, #3 computes the checksum #5 wants as a column, and #1's resume key
must be read from whatever schema #4 and #5 land. Shipped separately they
produce three row widths in one file and two cross-era boundaries.

## The invariant everything else follows from

The five issues never state whether a results row is a log of an **attempt**
or a table of **observations**. They assume opposite answers, which is what
creates the #1-vs-#2 contradiction (a `LOCKED` row recorded once and then
skipped forever, so the arm can never complete).

> **A results row exists if and only if the run reached the model.**
> An attempt refused before dispatch is not a row.

This dissolves the contradiction with no special-case logic: resume's
predicate is plain key-existence, because the rows that would have poisoned a
key are never written in the first place. `status` is then a **scoring**
concern, never a resume concern — a clean separation neither issue found.

The second invariant is scientific, and it is the one that must not be traded
away for convenience:

> **A run that reached the model is never re-run.**
> Selectively resampling failures converts a failure rate into a success rate.

This is not hypothetical. `docs/rounds-experiment.md:49` counts one exit-3
no-verdict run inside the r6 arm's composition, and that datum is load-bearing
in the shipped FAIL verdict. A resume that retried failures would have
overwritten it and shipped the opposite answer.

## Canonical schema

One migration, one commit, one era boundary per file. New columns append at
the END only — never insert, because `bench/rescore_bigdiff.py:33-34` maps
header names to positions and an insert silently shifts every stored score.

Shared tail, same names in the same order in all three files:

    status  date  sha  vsurv  vtotal

`status` leads because it gates whether any other field in the row means
anything; a reader that reaches `found` before `status` has already been
misled. `date` and `sha` are universal provenance. `vsurv`/`vtotal` are
conditional and go last.

| file | header |
|---|---|
| `results.tsv` | `label case run exit expected secs nfind found found_any status date sha vsurv vtotal` |
| `results-bigdiff.tsv` | `label run exit secs nfind hits other bugs status date sha vsurv vtotal` |
| `results-verify.tsv` | `label item run verdict truth gating secs agree status date sha` |

**`results-verify.tsv` omits `vsurv`/`vtotal` deliberately.** It *is* the
verifier probe — its existing `verdict` column already carries the survivor
signal those columns exist to add elsewhere. A permanently-empty column trains
readers to skim past emptiness, and then a genuine parse failure in a verify
arm reads as normal.

Column semantics:

- **`status`** — empty on a normal run. Non-empty means the row is not a clean
  measurement. Vocabulary below.
- **`date`** — `date +%F`, written **per row at append time**, not captured at
  batch start. A batch starting 23:50 and running four hours would otherwise
  stamp every row with the previous day, reintroducing the misattribution #5
  exists to fix.
- **`sha`** — first 12 hex chars, computed **once per batch**, from the
  snapshot copy that actually executed (never from the source file, so the
  recorded version and the run version cannot disagree). For
  `run_verify.sh`, which never invokes `review.sh`, it is that runner's own
  checksum.
- **`vsurv`/`vtotal`** — **empty**, not `0`, when verification did not run.
  `scripts/review.sh` emits the line only when verify is on *and* the audit
  found defects, so a `--verify` run that was genuinely clean emits nothing.
  Empty-vs-zero is what makes #4's acceptance criterion satisfiable at all:
  an all-refuted run is `exit=0` with `vtotal=N`; a clean run is `exit=0` with
  `vtotal` empty. Specifying these as integers defaulting to 0 destroys
  exactly the distinction #4 was filed to create.

### Empty cells are the empty string

Not `-`. `bench/score_bigdiff.py:122` already emits `-` meaning "zero known
bugs matched", and the token is live in the data:

    qwen38-nothink-anglSC-big-b  1  4  767  2  0  2  -

Reusing it gives one token two meanings in one file, two columns apart. `NA`
is also rejected: it is one careless edit from a numeric column, and there are
three unguarded `int()` casts waiting for it.

### Migration: widen line 1, do not backfill

Rewrite the header by hand in the migration commit. Historical rows keep their
current width; the file is legitimately mixed-width from that commit forward.

Backfilling was proposed by two perspectives and is **wrong**. No reader
requires uniform width — `dict(zip(header, fields))` truncates to the shorter
side, so a widened header over a narrow row maps every existing key correctly
and merely omits the new names. And backfilling causes a concrete harm:
writing an empty `vsurv` onto the older verify rows asserts "no verify data"
for runs whose verify data still exists in `bench/logs/*.err`, freezing a
recoverable gap as a permanent blank. A *missing* field says "this row
predates the column", which is the true fact.

The invariant to assert is therefore `NF <= header NF`, not equality.

Rewriting line 1 does not violate the repo's append-only rule.
`docs/experiment-loop.md:29-30` says "never rewrite **rows**", and
`bench/rescore_bigdiff.py:97` already rewrites the whole file — commit
`a9b2844` landed exactly that on real evidence. Byte-level append-only is
already false; the header is metadata and rewriting it destroys no
observation.

**Rejected alternatives.** *Leave the header stale*: the only option that
loses data — a narrow header over wide rows silently **drops** the new fields
on read, with no error, forever. *New-era files*: the precedent exists
(`bench/results-v1-ambiguous-prompt.tsv`, 30 rows, committed) and its outcome
is that **no tool reads it**; a fork amputates 385 rows from every consumer.

### Reader changes, required in the same commit

- `.get(name, "")` for new names only, in `bench/summarize_ctx_tiers.py:28`,
  `bench/watch_ctx_tiers.py:43`, `bench/rescore_bigdiff.py:34`.
- An assertion in `rescore_bigdiff.py` that every pre-existing column name
  still resolves to the index it had, so a future insert fails loudly instead
  of silently shifting `hits`.

## Infrastructure failures

A shared `status` column, not per-runner column reuse. Reuse is not a style
choice — it is **unavailable**: `bench/summarize_ctx_tiers.py:55` does
`sum(int(r["found"]))`, so a token there is a `ValueError`, and `run_eval.sh`
has no free-text column at all. Reuse is also already demonstrably broken
where it exists: `watch_ctx_tiers.py`'s bigdiff verdict never reads `bugs`, so
the exit-127 bash-splice row — the very incident behind #3 — renders today as
`0 known bugs`, i.e. as a model result.

Vocabulary:

| value | meaning | row written? | counts toward RUNS? |
|---|---|---|---|
| *(empty)* | clean measurement | yes | yes |
| `SERVER-DOWN` | probe failed; nothing dispatched | **terminal row only** | no |
| `LOCKED` | another review holds the model | **terminal row only** | no |
| `EMPTY-LOG` | real run, elapsed > 0, empty transcript | yes | yes |
| `SCORE-ERROR` | transcript exists, scorer crashed | yes | yes |
| `SUSPECT` | rc≠0, no footer, no known signature | yes | yes |

`SUSPECT` is the open bucket and is **not optional**. A closed vocabulary
encodes the assumption that the two signatures observed on one night cover the
infrastructure failure space. They do not — an OOM, a pi crash, a model-unload
race, or a disk-full all land as a plain `rc != 0` row. Without an explicit
unknown, a reader trusts that a blank `status` means the model really was the
problem, which makes unknown failures *more* invisible than they are today.

### Classifier, in this precedence order

1. `rc == 124` → `status` **empty**. A timeout is a real observation; the
   `exit` column already records it and both readers already render it. This
   ordering is load-bearing: the watchdog kills `review.sh` **before** its
   audit block runs, so a timed-out run has no footer, and a naive
   "footer absent ⇒ infrastructure" rule would misclassify it. No Round-1
   perspective stated this ordering correctly.
2. Audit footer present → `status` **empty**. The footer is emitted
   unconditionally before all five audit exit paths, so *footer present ⇔ a
   measurement happened*. This is an **allowlist**, and it is strictly better
   than #2's two-signature blocklist, which would still have missed the third
   failure from the same night (the exit-127 splice).
3. Footer absent, anchored `^local-review: ` grep of the `.err` matches the
   reachability or lock signature → terminal row, abort the batch.
4. Otherwise → `SUSPECT`.

The grep must be anchored on `^local-review: `. Both signatures come from
helpers that add that prefix, and model-derived free text can reach stderr —
verdict reasons are printed there under `--json`, which is a single-word flag
reachable through the runners' arg passthrough. The reviewed diff could
literally contain the phrase the blocklist looks for.

**Never retype the signature strings.** Add a drift test that extracts the
literals from `scripts/review.sh`, in the shape of the existing verifier-prompt
parity check. A test against a hand-typed fixture passes forever after
`review.sh` rewords.

### Fail-fast

Probe before dispatch, honouring the same URL override `review.sh` uses. On
failure: print loudly, write **one terminal row** carrying `SERVER-DOWN` or
`LOCKED` as its status, and abort with a distinct exit code that means
"infrastructure, nothing recorded, re-run the identical command to resume" —
separate from the existing exit 2, which means "fixture is invalid, do not
resume".

One terminal row rather than none, and rather than eleven: zero rows makes a
truncated arm indistinguishable from a deliberately short one, while the
per-run cascade is the 14-junk-rows incident itself.

The probe proves a port answers — **nothing more**. It does not prove the
right model is loaded, and the pipeline must still fail closed on the footer
allowlist as if no probe existed. Document that limit rather than engineering
around it; treating the probe as safety is the false confidence to avoid.

Probe only *between* runs, and retry before declaring down. A single-shot
short-timeout probe against a loaded machine mid-prefill is not a reliable
liveness signal, and killing a 40-minute in-flight arm on a false negative is
self-inflicted evidence loss.

## Resume

`RUNS` means **"ensure N rows exist for this key"**, not "dispatch N runs".
Re-running the identical command continues a truncated arm in place.

- Skip predicate: **the key exists**. Nothing more. Rows only exist for
  attempts that reached the model, so no status inspection is needed.
- **Nothing is ever auto-retried.** `EMPTY-LOG`, `SCORE-ERROR`, `SUSPECT`,
  exit 3, exit 124 are all terminal. `SCORE-ERROR` in particular is repaired
  by `rescore_bigdiff.py` from the saved transcript — re-running spends ~20
  GPU-minutes to fix a Python bug *and* replaces the original observation.
- **No renumbering.** Run numbers are not monotone attempt ids.
  `watch_ctx_tiers.py` iterates a fixed `range(1, RUNS+1)`, so a retry parked
  past that range is invisible to the watcher; and where a duplicate does
  arise, `watch_ctx_tiers.py` and `rescore_bigdiff.py` already resolve
  last-wins **on purpose**, with a comment recording that first-wins got it
  backwards.
- The key check is the **first** thing in the loop body — before
  `run_bigdiff.sh`'s log rotation. A check placed after it orphans the
  transcript for every row it just skipped.
- Report on every invocation: `label: N of M already recorded, dispatching K`.
  Warn when recorded > requested, so a smaller `RUNS` after a larger one
  cannot silently do nothing while printing success.
- A final line whose field count is short is **corruption, not a completed
  key**: skip it, warn, and start the next append on a fresh line. This is
  cheap defence, not the design driver — all 385 existing rows are
  width-uniform despite four external kills, because each row is one small
  `printf` to an append-mode fd. The observed failure is an *absent* row.

### Provenance guard (operator-approved; in no issue)

Resume automates continuing an arm across a gap in which the script, prompt,
model, or context size may all have changed — which is the 2026-08-19
misattribution turned into an automatic behaviour. Before dispatching, compare
the recorded `sha` of existing rows for that label against this batch's. On a
**present and differing** value, abort and say why.

A **missing** `sha` never triggers the abort. Without that carve-out the guard
bricks resume on all 385 historical rows the day it ships.

## Script snapshot

Copy the reviewed script once **per batch** — never per run, since an
experiment measures one script version and a per-run copy would let a
mid-batch edit change the measured artifact silently. Honour the existing
override: if the caller already pinned a script, use it as-is, do not
re-snapshot, do not delete it. `bench/run_ctx_tiers.sh` takes **one** snapshot
and pins it across both suites it dispatches, otherwise a single tier arm
measures two separately-taken snapshots — #5's cross-session misattribution
reproduced inside one label.

**Location: `bench/logs/`, keyed uniquely per batch, and kept.** Not a temp
dir, and not deleted. `bash "$SNAPSHOT"` sets the script's reported path to
the snapshot, so the exact `line 408: ll: command not found` error class this
fixes is reported against that path — it must still exist when someone reads
the `.err` file. `bench/logs/` is already gitignored and is already where the
durable transcripts live. The name must never be derived from the label alone:
a reused path would silently re-measure the previous batch's script while the
row is stamped with today's `sha`.

Verified safe: `review.sh` never references its own location after startup
(no self-path resolution anywhere in it) and cds to the reviewed repo's
toplevel, so executing a copy is sound.

Checksum portability: `shasum` is present on macOS and not guaranteed on a
minimal Linux; `sha256sum` is the reverse. The repo has no existing checksum
idiom to copy, so this needs a two-way fallback and a test that runs with one
of them hidden from `PATH`.

**#3's third acceptance criterion is overstated.** The "never edit mid-bench"
rule is narrowed, not retired: bash reads the *runners* incrementally too, and
the snapshot does not protect them.

## Scope rulings

**`run_verify.sh` is fully in scope** (operator decision). It drives `pi`
directly and never invokes `review.sh`, so it takes no review-script snapshot
and no verify columns — both exclusions are stated above with their reasons.
It is, however, the only runner with **no exit-code capture and no watchdog**,
so today a dead server there is recorded as the verifier *disagreeing with
ground truth* — a wrong answer rather than a missing one, biasing the arm
pessimistically with nothing in the row to catch it. It needs an rc and a
watchdog before infrastructure marking can mean anything there.

**Any new environment override must be added to `bench/run_ctx_tiers.sh`'s
unset list** in the same change. That list exists so a tier arm measures the
default configuration; a new knob omitted from it lets a stray export silently
change what a labelled arm ran. The list has no test guarding it — add one.

## Adjacent fixes (operator-approved; in no issue)

1. **Detection-score filter.** `summarize_ctx_tiers.py` computes detection as
   `sum(found) / len(defect rows)` with no exit filter, while the code
   immediately below it *does* filter dead runs out of the fabrication column.
   Runs that never reached the model therefore count as model misses.
   Currently **latent** — the tool's arm list is hardcoded to three ctx tiers,
   all of which are clean — but it fires the first time a dirty arm is scored,
   and automating that manual exclusion is the point of this workstream.
   Exclude non-empty `status` and exit-1 rows from both numerator and
   denominator. Keep exit 3 and 124 counted as detection misses: "did it
   catch this" is answerable as no, whereas "did it fabricate" is not
   answerable without a verdict — that asymmetry is deliberate, document it.
2. **Results-file lock.** Two concurrent resumes of one label compute the same
   missing set and both dispatch it. The model lock catches the collision, so
   nothing corrupts, but the second run dies confusingly. Take the same
   directory-based lock pattern `review.sh` already uses, keyed on the results
   file.
3. **Atomic rescore write.** `rescore_bigdiff.py:97` rewrites the whole
   evidence file with no temp+rename. Killed mid-write — which happened four
   times in one night — it destroys the only evidence a fresh clone has, since
   `bench/logs/` is gitignored. Two lines.

## Tests

**A new `tests/test_bench_runners.sh`, public-repo only** (operator
decision), added to the commands block as a second gate.

`tests/test_local_review_audit.sh` is byte-compared against the private
mirror, so every line added there must be ported into a checkout where
`bench/` does not exist, purely to be skipped — and one skip line would then
hide ~20 unrun assertions, degrading the one signal the project instructions
tell a reader to check. The asymmetry already has precedent: the mirror
carries two test files this repo does not.

Baseline to hold: `pass=98 fail=0 skipped=2` bare, `pass=100 skipped=0` with
the mirror set.

**The seam already exists — no new injection points are needed.** All output
paths in all three runners derive from the runner's own directory, so copying
a runner into a temp dir, symlinking its fixtures beside it, and pointing the
script override at a stub runs a full batch in well under a second and touches
nothing tracked. This was measured, not assumed.

Where `review.sh`'s own output is being parsed, drive the **real**
`review.sh` under the existing stubbed-harness machinery rather than
asserting against a retyped fixture — that harness already produces a genuine
verify line on stderr.

Deterministic simulations available for the motivating incidents:

- *Batch killed mid-flight*: seed the TSV with rows that "already ran" and
  count stub invocations; and have the stub signal its parent on run 2, then
  re-run the identical command.
- *Server died mid-batch*: start a throwaway listener, point the URL override
  at it, kill it from the stub during run 1.
- *Server down at start*: point the URL override at a closed port.
- *Lock refusal*: stub that prints the real refusal text and fails.
- *Mid-bench edit*: a **self-mutating stub** — v1 overwrites the script under
  test with a v2 body on its first invocation. The mutation is sequenced by
  the runner's own loop, so there is no race at all. Today's code yields
  `V1 V2 V2`; a correct batch-start snapshot yields `V1 V1 V1`. The same
  three-line assertion also pins "one copy per batch, not per run".

Structural (grep-on-source) assertions are right for exactly two things,
matching existing house precedent: that the abort path precedes any row
append, so a fail-fast cannot emit a partial row; and the signature-drift
check against `review.sh`.

Two suite hazards to avoid: the existing suite exports a fake `HOME` partway
through and never restores it, so a block placed after that line runs the
runners' fixture bootstrap with no git identity and fails for unrelated
reasons; and the verifier-parity check locates a prompt by first occurrence of
a variable-name prefix, so anything added above it in `run_verify.sh` silently
redirects that assertion.

**State the limit honestly in the test comments.** All of this tests the
runners' *bookkeeping*. Nothing here proves that a real 40-minute run against
a real server produces the exit code, stderr line, or failure shape the
bookkeeping expects. The defence is keeping parsers anchored to strings
extracted from `review.sh` at test time. Where a test cannot close a claim —
"exit=1, 0 seconds really was a dead server" — write *unfalsifiable* rather
than an assertion that only restates the implementation. Likewise, the
snapshot test proves "the batch measured one script version", not "bash cannot
splice"; reproducing the lazy-offset splice itself has no cheap deterministic
form.

## Dissents

Preserved deliberately. A dissent that turns out right later is the most
valuable artifact here.

- **Security: backfill every historical row to uniform width.** Rejected
  because no reader requires uniformity and backfill overwrites a recoverable
  distinction. *Why it might be right*: a uniform file admits one flat
  field-count assertion, and if a future consumer ever indexes positionally
  from the right-hand end, mixed width breaks it silently.
- **Security: re-run timeouts.** Rejected — resampling the slow tail biases
  the latency distribution the bench exists to measure. *Why it might be
  right*: a watchdog timeout genuinely can be caused by an unrelated machine
  load spike, and forcing those into the arm makes an arm look slower than the
  configuration is. Worth revisiting if timeouts ever correlate with something
  other than the model.
- **Contracts: a separate `bench/incidents.tsv`.** Rejected on the repo's own
  precedent — it already has one forked results file that no tool reads. *Why
  it might be right*: it keeps the evidence table free of any row that is not
  a measurement, which is the cleanest possible statement of the invariant.
- **Data: `LOCKED` writes nothing at all.** Adopted for the per-run row,
  overridden for the terminal row. *Why it might be right*: the terminal row
  is the one row in the design that is not a measurement, and every future
  consumer must remember to filter it.
- **Architect: against a shared Python schema module.** Adopted for the bash
  side (the per-runner blocks are 2–4 lines each and carry comments recording
  measured incidents), but the schema knowledge itself has four consumers on
  disk and does pass the repo's own bar for a single source of truth. If the
  bash glue exceeds roughly ten lines per runner, revisit.

## Convergence note

The five perspectives genuinely disagreed — four incompatible answers on
infrastructure representation, directly opposed positions on backfill, empty
token, renumbering, and snapshot location. This was not manufactured
agreement.

Two caveats on the method, recorded so the next reader can discount
appropriately. The Round-1 prompts carried one shared hint about reader
behaviour that anchored the framing (three perspectives went past it anyway
and found the more dangerous opposite case). More seriously, three prompts
pre-loaded distinctive concerns, and those three produced the most valuable
findings — so the debate tested the framing as much as the requirement, and a
concern nobody was prompted toward could still be missing.

One error in the brief itself is worth recording: it asserted that all five
perspectives agreed timeouts were terminal. That was false when written — it
was a 3–1 split — and had it gone unchecked into consensus it would have
shipped the re-run-timeouts rule as if unanimous.
