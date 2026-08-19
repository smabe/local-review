# bench-row-hardening-snapshot — measure a frozen copy of review.sh (#3)

You are phase `snapshot` of the `bench-row-hardening` plan. You make each bench
batch execute a frozen copy of the reviewed script instead of the live file, so
editing `scripts/review.sh` mid-batch cannot splice a running bash. You also
create `tests/test_bench_runners.sh`, the second test gate every later phase
adds to.

## Locked decisions (do NOT re-litigate)

See `plans/bench-row-hardening.md` and `docs/bench-hardening-spec.md`. Summary:

- **One copy per batch, never per run.** A per-run copy would let a mid-batch
  edit change the measured artifact silently, which is worse than crashing.
- **Location `bench/logs/`, uniquely named per batch, and KEPT — not deleted,
  not `/tmp`.** `bash "$SNAPSHOT"` makes the snapshot path the script's
  reported path, so the `line 408: ll: command not found` error class this
  fixes names that file; it must still exist when someone reads the `.err`.
- **Never derive the snapshot name from the label alone.** A reused path
  silently re-measures the previous batch's script while the row is stamped
  with today's checksum.
- **Honour `LOCAL_REVIEW_SH`:** set → the caller pinned a script, use as-is,
  do not re-snapshot, do not delete. Unset → snapshot and own it.
- **`run_ctx_tiers.sh` takes ONE snapshot** and pins it across both suites.
- **Checksum needs a `shasum` / `sha256sum` two-way fallback** — `shasum` is
  perl (macOS yes, minimal Linux no), `sha256sum` is coreutils (the reverse).
- This phase writes the checksum to the **driver log only**. The `sha` column
  arrives in phase `schema`.
- The "never edit mid-bench" rule is **narrowed to review.sh, not retired** —
  bash reads the runners incrementally too.

## Read first

- `plans/bench-row-hardening.md` `## Findings log` — empty; you are first.
- `docs/bench-hardening-spec.md` "Script snapshot" — the full reasoning.
- `bench/run_eval.sh:10-13` — `EVAL_DIR` / `REVIEW` / `RESULTS` definitions;
  the snapshot goes right after `REVIEW`.
- `bench/run_eval.sh:65-66` — the invocation site,
  `( cd "$REPO" && bash "$REVIEW" ... ) > "$log" 2> "$log.err" &`.
- `bench/run_bigdiff.sh:19-23` and `:70-71` — the same two sites.
- `bench/run_ctx_tiers.sh:25-26` — the `unset` list, which currently drops
  `LOCAL_REVIEW_SH`; `:40-58` — `cleanup()` and its EXIT trap, the pattern to
  mirror; `:148-153` — the two suite dispatches that must share one snapshot.
- `scripts/review.sh:143` — `cd "$(git rev-parse --show-toplevel)"`, which is
  why running a copy from another directory is safe. **Read only; do not edit
  this file.**
- `tests/test_local_review_audit.sh:14-35` — the house test shape: `ROOT`,
  `TMP`, the EXIT trap, `pass/fail/skipped` counters, `ok` / `bad` / `skip`.
- `tests/test_local_review_audit.sh:629` — the footer line to mirror.
- `CLAUDE.md` "Commands" block — where the second gate is documented.

## Produce

1. **Failing tests first** — create `tests/test_bench_runners.sh`.

   Mirror the house shape exactly: `set -u`, `ROOT="$(cd "$(dirname
   "$0")/.." && pwd)"`, `TMP="$(mktemp -d)"` with `trap 'rm -rf "$TMP"' EXIT`,
   `pass=0; fail=0; skipped=0`, the `ok` / `bad` / `skip` helpers, and a
   closing `echo "pass=$pass fail=$fail skipped=$skipped"` plus a non-zero exit
   when `fail` is non-zero.

   Add a relocation helper the later phases reuse — it copies a runner into
   `$TMP/bench/`, symlinks the fixtures it needs beside it, and returns the new
   path. This works because every output path in all three runners derives from
   `EVAL_DIR` (`run_eval.sh:10-13`), so a relocated runner writes its results
   file, logs and fixture repo inside `$TMP`.

   Guard the whole file on `[ -d "$ROOT/bench" ]`, `skip`-ing with a clear
   message otherwise, so the file is harmless if it is ever copied to a
   checkout without `bench/`.

   **Set a git identity for the relocated runners.** They bootstrap their
   fixture repo with `git commit` (`bench/run_eval.sh:32-38`). Export
   `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_NAME` /
   `GIT_COMMITTER_EMAIL` in the harness rather than relying on global config.

   Assertions for this phase:
   - **The self-mutating stub.** Write a stub review script that appends `V1`
     to a marker file and, on its first invocation, overwrites its own source
     path with a v2 body that appends `V2`. Run a relocated `run_eval.sh` with
     `RUNS=3` and one case. Assert the marker file reads `V1 V1 V1`. This is
     deterministic — the mutation is sequenced by the runner's own loop, so
     there is no race. It pins BOTH "the batch measured one script version" and
     "one copy per batch, not per run" (a per-run copy yields `V1 V2 V2`, which
     is what today's code produces).
   - **The snapshot survives the batch.** After a batch, assert exactly one
     snapshot file exists under the relocated `logs/` and that its contents are
     byte-identical to the stub as it was at batch start.
   - **`LOCAL_REVIEW_SH` is not re-snapshotted.** With it set to a stub path,
     assert that stub path is what executed and that no new snapshot file was
     created.
   - **Checksum fallback.** Run the batch under a `PATH` containing neither
     `shasum` nor `sha256sum`, then under one with only `sha256sum`, and assert
     the driver log carries a non-empty checksum in the second case and fails
     loudly rather than silently empty in the first.
   - **Unique naming.** Run two batches under the same label and assert two
     distinct snapshot files exist.

2. **Implementation.**

   - `bench/run_eval.sh`: place the snapshot block **immediately after the
     existing `mkdir -p "$EVAL_DIR/logs"` at `:31`** — NOT after the `REVIEW=`
     line at `:11`. `$LABEL` is not assigned until `:15` and `logs/` does not
     exist until `:31`, so a snapshot at `:11` aborts the runner under `set -u`.
     If `LOCAL_REVIEW_SH` is set, use it unchanged and record that this batch
     does not own it. Otherwise
     `mktemp "$EVAL_DIR/logs/$LABEL.review.sh.XXXXXX"` — **the X's must be
     TRAILING**. Measured on macOS this session: BSD `mktemp` substitutes only
     trailing X's, so a `...-XXXXXX.review.sh` template creates a file named
     literally `-XXXXXX.review.sh` and every later batch dies with
     `mkstemp failed: File exists` — silently violating this phase's own rule
     that a snapshot path is never reused. Copy `$REVIEW` to it, point the
     invocation at the copy, and echo the resolved checksum and snapshot path
     to stderr once at batch start.
   - Checksum helper: try `shasum -a 256` then `sha256sum`, take the first
     field, truncate to 12 chars. If neither exists, fail the batch loudly
     rather than recording an empty value. **Run this guard BEFORE taking the
     snapshot**, and place the snapshot after `run_eval.sh`'s existing
     fail-closed case check at `:26-29`: a batch refused for any reason must
     leave no copy behind, because a snapshot on disk implies a measurement was
     attempted. (Found by probe — the natural ordering leaves an orphan.)
     Note both tools exist on current macOS (`/usr/bin/shasum` and
     `/sbin/sha256sum`), so the fallback branch is reachable only under a
     `PATH` shim — which is how the test must exercise it.
   - `bench/run_bigdiff.sh`: the same change at `:20` and `:70`.
   - `bench/run_ctx_tiers.sh`: keep the `unset` at `:25-26` as-is — its
     documented purpose (drop a stray override from a variant arm) is still
     correct. Take one snapshot of `$REPO_ROOT/scripts/review.sh` and
     `export LOCAL_REVIEW_SH` over it, so both suite dispatches at `:149` and
     `:152` measure the same copy. Place it **after `:36`'s `mkdir -p logs`** —
     `$EVAL_DIR` and `$REPO_ROOT` are not defined until `:28-29`, so an earlier
     placement aborts under `set -u`. **Keep the file**; do not delete it in
     `cleanup()`, and do not add an unset there either — unsetting an exported
     variable in the EXIT trap of an exiting process has no observable effect
     (confirmed by probe). The real hazard in `cleanup()` at `:40-57` is the
     trap rewriting the exit status: if you touch it, every branch is a full
     `if`, never a `&&` chain, and it still ends with `return 0`.
   - `bench/README.md`: document the snapshot behaviour and where the copies
     live.
   - `docs/verify-flag.md`: narrow the "never edit review.sh while a bench run
     is in flight" rule to a historical note, and say plainly that the
     protection covers `review.sh` only — the runners themselves are still read
     incrementally by bash.
   - `CLAUDE.md`: add `bash tests/test_bench_runners.sh` to the Commands block
     as the second gate, with a one-line note that it needs `bench/`.

3. **Acceptance.**
   - `bash tests/test_bench_runners.sh` green, with the self-mutating-stub
     assertion demonstrably failing if you revert the snapshot change.
   - `bash tests/test_local_review_audit.sh` — **Gate invariant:** `fail=0`, and `pass` must not DECREASE against the same
     command run before this phase's changes. **Do not hard-code a pass count.**
     The pass/skipped split is checkout-dependent: from the main checkout with no
     mirror configured it reads `pass=98 fail=0 skipped=2` (the two drift checks
     skip because the default mirror path resolves to this same checkout), while
     from a git worktree the same two checks PASS and it reads
     `pass=100 fail=0 skipped=0`. **clu workers run in worktrees**, so asserting
     the 98/2 pair fails the gate through no fault of the change.
   - `git status --porcelain bench/` is empty after the new tests run — the
     relocated runners must not write into the real `bench/`.
   - `bash bench/run_eval.sh` with a bad provider still fails the way it did
     before; the snapshot must not swallow the existing fail-closed paths at
     `:26-29` and `:58-61`.

4. **Commit + attest + complete.**
   - Append any cross-phase finding to `## Findings log` in
     `plans/bench-row-hardening.md`.
   - Commit: `bench: snapshot review.sh per batch so mid-bench edits cannot
     splice a running run (#3)`.
   - Stage: `bench/run_eval.sh`, `bench/run_bigdiff.sh`,
     `bench/run_ctx_tiers.sh`, `bench/README.md`, `docs/verify-flag.md`,
     `CLAUDE.md`, `tests/test_bench_runners.sh` (+ the master if you logged a
     finding).
   - After the commit: `clu verify --plan bench-row-hardening --phase snapshot
     --token <T>` then `clu attest --simplify --plan bench-row-hardening
     --phase snapshot --token <T>`.
   - `clu complete --plan bench-row-hardening --phase snapshot --token <T>`.

## Failure modes to watch

- **`mktemp` with fewer than three X's** fails on GNU coreutils and passes on
  BSD. The bench has already lost a Linux run to exactly this.
- **The EXIT trap rewriting the exit status.** bash adopts the trap's last
  command status. `run_ctx_tiers.sh`'s `cleanup()` ends with `return 0` at
  `:56` for this reason — keep it, and make every branch you add a full `if`.
- **Hoisting the `mkdir -p logs`** above the fixture bootstrap in
  `run_eval.sh:31-38` — check you have not changed the order in which the
  fixture repo is created, since the bootstrap is guarded on `.git` absence.
- **The relocated-runner harness writing into the real `bench/`.** If a symlink
  points the wrong way, a test run appends junk rows to committed evidence.
  Assert `git status --porcelain bench/` is clean as part of the test file
  itself, not just at review time.
- **`run_ctx_tiers.sh` exports `LOCAL_REVIEW_SH` after unsetting it** — that
  ordering is deliberate and the comment at `:19-24` explains why the unset
  exists. Do not delete the unset; export after it. Place the snapshot after
  `:36`'s `mkdir -p logs`, since `$EVAL_DIR` and `$REPO_ROOT` are not defined
  until `:28-29`.
- **Two things the old shape provided that this one does not.** Say both in the
  findings log rather than discovering them later. (1) `REVIEW` used to be the
  single name for "the script under test"; once a separate variable holds the
  executed copy, anyone grepping `$REVIEW` to learn what a batch ran lands on
  the wrong one — name the new variable so that is obvious, and consider
  renaming `REVIEW` to `REVIEW_SRC` if it stays cheap. (2) The path named in an
  `.err` used to be a tracked file with git history that survived
  `rm -rf bench/logs`; it now names a gitignored copy. That is the intended
  trade, but it turns a durability guarantee into a convention — document in
  `bench/README.md` that snapshots are deleted only together with the
  transcripts that reference them, never before.
