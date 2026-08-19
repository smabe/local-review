# Resume — extract-runner-helper (briefed 2026-08-19, after bench-row-hardening)

```
bench-row-hardening is shipped — commits fa16273..41f6f20 on main, 2026-08-19,
closing issues #1-#5 as one workstream. Cleanup pass done: plan files archived to
plans/archive/bench-row-hardening/, memory rewritten as a shipped record,
follow-ups filed as GitHub issues #6-#11 (plus smabe/end-of-line#108 for a clu bug
that nearly cost the branch).

The three bench runners now snapshot the reviewed script per batch, tell
infrastructure failures apart from model failures, carry a five-column provenance
tail (status date sha vsurv vtotal), and resume an interrupted arm when you re-run
the identical command. Two test gates now: tests/test_local_review_audit.sh and
the new tests/test_bench_runners.sh (242 assertions).

Next steps available (pick one or propose your own):
- #6: extract the duplicated runner internals into a sourced bench/ helper —
  review_sha, classify_run, abort_infra, probe_server, the SIG_* set and the
  resume scan are hand-copied across three runners (checksum across four). It
  drifted once already mid-workstream. Three phases filed it; none could take it,
  because it also changes relocate() in tests/test_bench_runners.sh.
- #7: a row torn after its key columns claims that key forever — the readers were
  hardened during the workstream, the writers' resume scan was not. Unreadable and
  unrepairable at once. Correctness bug.
- #8: the results lock can advise deleting a lock that is actively held — the
  owner pid is written after mkdir, so a batch arriving in that window reads no
  pid and prints rm -rf advice. Reopens the race the lock exists to close.
- #9: two status-vocabulary gaps — a marker documented as clearable but
  unreachable, and review.sh's model-load refusal having no signature (wants a new
  status value, so it is a design call).
- #10: the audit suite's template-less mktemp blocks agent sandboxes. One-line
  fix, but that file is byte-identical with the private abe-skills mirror, so the
  same edit must land in both checkouts in one change.
- #11: one owed manual check — the probe's retry path against a live llama-server
  that answers slowly or 5xx, which no automated test can reach.

Recommended next pickup: #6. It is the largest, but #7 and #8 both want that
helper to exist — doing #6 first means their fixes land in one definition instead
of three, and the drift it prevents has already happened once. Do #6, then #7 and
#8 fall out cheaply in the same file.

Read first if continuing from this work:
- docs/bench-hardening-spec.md — the settled design and why each fork went the way
  it did. It is the contract; do not re-litigate it.
- plans/archive/bench-row-hardening/bench-row-hardening.md — the findings log. Every
  phase appended what it learned, including several corrections to the original
  issues. #6's exact scope is stated there three separate times.
- gh issue view 6
- bench/README.md — the status vocabulary and the column documentation.

Constraints that bite here:
- bash 3.2, macOS + Linux. mktemp needs TRAILING X's (a mid-name template silently
  creates a literal filename on BSD, then fails). BSD+GNU sed only.
- Every EXIT-trap branch is a full `if` — bash adopts the trap's last status.
- Do NOT touch scripts/review.sh or tests/test_local_review_audit.sh; both are
  byte-identical with ~/projects/abe-skills/skills/local-review/. #10 is the one
  exception and it must edit both copies.
- Do not hard-code a test pass count. The audit suite reads 98/2 from the main
  checkout and 100/0 from a git worktree. The invariant is fail=0 with no decrease
  in pass.

Open questions or blockers: none. #9 carries one genuine design decision (what
status token a failed model load should get).
```
