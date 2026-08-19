# bench — the measurement instrument for the reviewer

Everything in `docs/model-choice.md` is reproducible from here. This directory
is how a claim about the reviewer becomes a number: seed a known defect, replay
it through the real `scripts/review.sh`, and score whether the tool caught it.
Nothing here tests the model in isolation — every run includes the prompt, the
audit, the engine, and the exit contract, because those are what actually ship.

## The two suites

**Small cases** (`cases/`, seven of them) measure whether a specific defect class
is found when the diff is small enough that nothing can hide. Five plant one bug
each; `clean` is a genuinely clean refactor that measures fabrication; and
`stalecomment` plants no code bug at all — its defect is a stale docstring over
a correct, intended change. The default run covers the original five;
`removedguard` and `stalecomment` run via the `LOCAL_REVIEW_EVAL_CASES`
override below (`removedguard` added 2026-08-18 for the angle-B experiment —
`docs/angle-removed-behavior.md`; `stalecomment` added the same day for the
stale-comment angle that SHIPPED — `docs/angle-stale-comment.md`).

| case | file | the defect | why it is here |
|---|---|---|---|
| `offbyone` | store.py | `keys[-n - 1:-1]` in a "n most recent keys" helper — returns n keys but ends one position early, dropping the newest | the plausible-looking slice; the zero-guard above it is correct, which sells it |
| `swallow` | store.py | constructor swallows `OSError` on load, so a transient read failure starts the store empty and the next `_flush()` overwrites the real file | **the discriminator.** Silent data loss, and the comment above it states the intent so the code matches its own description |
| `boolean` | parser.py | `[k for k in required if k in config and config[k]]` — inverted, so the validator raises on healthy keys and passes when a required key is missing | a validator that fails open, worse than none |
| `leak` | store.py | `fh = open(path, "w")` with no close and no context manager | usually works under CPython refcounting, which is what makes it real |
| `clean` | parser.py | nothing — `startswith("#")` becomes `line[0] in "#;"`, docstring updated to match | **the control.** Built to look dangerous (`line[0]` on an empty string) while being safe (`if not line` short-circuits first). Any finding here is a false positive |
| `removedguard` | parser.py | a tidy `partition()` consolidation silently deletes the `if not key: raise` guard, so `"=value"` yields `{"": "value"}` instead of raising | the refactor-disguised removed guard; not in the default case list — run via `LOCAL_REVIEW_EVAL_CASES="removedguard"` |
| `stalecomment` | parser.py | no code bug: duplicate keys switch from last-wins to first-wins (correct, intended), while the docstring still says "later duplicates win" | the stale-doc case. Scores only under `LOCAL_REVIEW_EVAL_CASES="stalecomment" LOCAL_REVIEW_EVAL_ARGS="--angle stalecomment"`; its meta `expected_exit=0` is calibrated for the DEFAULT pass (rule 2 bans the finding; measured 2/2, v7 instead misattributes the contradiction onto the correct code). The angle arm's success signature is exit 4 + `found=1`, scored by hand per docs/angle-stale-comment.md |

**Scoring caveat for `--verify` arms** (`qwen38-nothink-vfy*` rows): run_eval's
columns predate verification. `nfind` is scraped from the audit's stderr line,
which reports the PRE-refutation count, and `found` requires exit 4 — so a run
whose true catch was wrongly refuted records `exit=0 nfind=1 found=0
found_any=1`, indistinguishable in the TSV from a formatting miss. Score
verify arms from the logs (the `verify: N/M` stderr line and the VERDICT
lines), never from the TSV alone. A verify-aware scorer is filed future work
in docs/verify-flag.md.

**Cross-era scoring note (2026-08-19):** the scorer gained the sixth bug and
stopped parsing --verify echo sections on 2026-08-19, and `rescore_bigdiff.py`
rebuilt every row with a usable log. Six early rows have no usable log and
remain scored under the old five-bug rule (`qwen38-nothink-r6` r2 [pre-v7],
`-purpose` r1, `-purpose-b` r3, `-anglSC-big` r1, `-vfy-big` r1, `-r6-b` r1) —
their `hits`/`other` are not comparable across that boundary.

**Big diff** (`bigdiff/`, 18.3 KB over seven files) measures whether attention
survives volume — whether three real bugs still get found inside a plausible
refactor, or whether the model pattern-matches "competent work" and returns
clean. This is the suite that settled the default reviewer: Qwen3-Coder answers
"No findings." on it twice in ~20 s.

Six known bugs: three planted, two discovered during validation and adopted, and a sixth discovered 2026-08-19 by the bold-finder arm (verified by live probe) and adopted:

| id | file | the defect |
|---|---|---|
| `cache_evict` | cache.py | `victim = max(self._entries, key=...ts)` evicts the NEWEST entry; a cap must evict the oldest (`min`). The cache pins its oldest entries forever and thrashes on everything current |
| `migrate_discard` | serialize.py | `_migrate_v1(payload["data"])` return value thrown away; the function returns a new dict rather than mutating, so v1 data flows out unmigrated |
| `export_exit0` | cli.py | `cmd_export`'s `except OSError` returns 0. The sibling `cmd_import` returns 1 for the same case, which is the tell |
| `rename_prefix` | store.py | `rename_namespace` validates the `:` separator only in `new`; an `old` containing `:` prefix-matches a sibling namespace's keys and silently moves them out | the discovered-not-planted bug; proof more real bugs can exist in the fixture |
| `import_after_guard` | cli.py | `COMMANDS["import"] = cmd_import` sits below `if __name__ == "__main__"`, so the process exits before registration — the whole import command is dead code |
| `export_default_ns` | cli.py | `store.keys()` with no namespace, defaulting to `"default"`, while the docstring promises every record. `cmd_keys` directly above it passes the namespace correctly |

## Running it

Serve the model first (`scripts/llama_server.sh`); the runners do not manage
llama-server lifecycle.

```bash
bench/run_eval.sh    llamaserver qwen38-gguf-nothink 2 my-arm-label   # default 5 cases x2
LOCAL_REVIEW_EVAL_CASES="removedguard" LOCAL_REVIEW_EVAL_ARGS="--rounds 5" \
bench/run_eval.sh    llamaserver qwen38-gguf-nothink 2 my-arm-label   # custom case list / extra single-word flags
bench/run_bigdiff.sh llamaserver qwen38-gguf-nothink 2 my-arm-label   # big diff x2
bench/run_ctx_tiers.sh 65536 2 qwen38-nothink-ctx64k                  # a whole context-tier arm

python3 bench/watch_ctx_tiers.py            # live view of a running arm; --once for a snapshot
python3 bench/summarize_ctx_tiers.py        # the cross-arm tables
python3 bench/score_bigdiff.py <log>        # score one saved verdict
python3 bench/rescore_bigdiff.py [--check]  # rebuild stored rows from the saved verdicts
```

`run_ctx_tiers.sh` is the only one that touches shared state: it rewrites
`contextWindow` in `~/.pi/agent/models.json`, serves at a matching `LLAMA_CTX`,
asserts the served `n_ctx_slot` is what was asked for, samples wired memory
throughout, and restores `models.json` from an EXIT trap. Set
`LOCAL_REVIEW_ARM_SUITES=bigdiff` (or `eval`) to complete an arm that only got
half-finished, rather than re-running the half that already produced valid rows.

Both fixture repos (`eval-repo/`, `bigdiff-repo/`) are gitignored and bootstrap
on first use. Both runners skip that bootstrap if the repo already exists.

### The reviewed script is frozen per batch

Each batch copies `scripts/review.sh` once, into `logs/<label>.review.sh.<rand>`,
and every run in that batch executes the copy. The batch announces it on stderr
before dispatching anything:

```
run_eval.sh: snapshot /…/bench/logs/my-arm.review.sh.a1B2c3 (sha256 4f9c1e02ab77) of /…/scripts/review.sh
```

One copy per **batch**, never per run: an experiment measures one script
version, and a per-run copy would let a mid-batch edit change the measured
artifact silently — which is worse than crashing, because nothing in the results
would show it. The name is never derived from the label alone, or a second batch
under one label would re-measure the first batch's script.

`run_ctx_tiers.sh` takes **one** snapshot and exports `LOCAL_REVIEW_SH` over it,
so both suites in an arm measure the same copy. It keys that copy on the label
and **reuses it** when it is already there, so finishing a half-done arm with
`LOCAL_REVIEW_ARM_SUITES` measures the script the arm started with rather than
today's — it says so on stderr when it does.

Setting `LOCAL_REVIEW_SH` yourself pins any other script: a batch that finds it
already set uses that path as-is, takes no snapshot, and does not own its
lifetime. **A pinned script is therefore not frozen.** Nothing stops an edit to
it from reaching a run in flight, which is the whole failure this section
otherwise removes — so if you are benching a script you are still editing, copy
it yourself and pin the copy.

The checksum is truncated to 12 hex chars, via `shasum -a 256` falling back to
`sha256sum` (neither is universal — the first is perl, the second coreutils),
and it is taken from the **copy**, so the reported version is the bytes that
actually ran. A batch that can find neither tool **refuses to run** rather than
record a blank version.

A batch refused *before it dispatches anything* — unknown case name, unreadable
script, no checksum tool — leaves no copy behind, so a snapshot on disk means
that batch reached dispatch. The per-run fixture guards that fire later
(`run_bigdiff.sh`'s `git apply` check, `run_eval.sh`'s marker-drift check) can
leave one; it is inert, and nothing but its own `logs/` neighbours name it.

**Snapshots are kept, and are deleted only together with the transcripts that
reference them — never before.** `bash <snapshot>` makes that path the one bash
names in an error, so `logs/<label>-<case>-r<n>.txt.err` can read
`…/logs/my-arm.review.sh.a1B2c3: line 408: ll: command not found` and mean
nothing at all once the copy is gone. This is a real trade: the path in an
`.err` used to name a tracked file whose history survived `rm -rf bench/logs`,
and now names a gitignored copy that does not. The durability guarantee became
a convention, and this paragraph is the convention.

## Reading the results

`results.tsv` — one row per small-case run:
`label case run exit expected secs nfind found found_any`

`results-bigdiff.tsv` — one row per big-diff run:
`label run exit secs nfind hits other bugs`

- **exit** is `review.sh`'s own exit code: `0` clean · `1` error · `2` usage ·
  `3` the verdict cannot be trusted · `4` defects reported. `124` is the
  watchdog. **Only 0 means clean, and a 3 is not a pass.**
- **nfind** is the audit's own validated finding count, parsed from its stderr
  footer — not something this harness counts independently.
- **found** is the catch: the planted line was quoted in a `QUOTE:` line AND the
  run exited 4. **found_any** drops the exit requirement, so the gap between
  them is "correct finding inside a verdict the tool could not trust".
- **hits / other / bugs** are big-diff only. `other` counts finding blocks
  matching no known bug — a fabrication *candidate*, not a fabrication, because
  the fixture is real code and a sixth real bug is possible. Read the log in
  `logs/` before calling one a fabrication.

Verdict transcripts in `logs/` are the durable evidence; the TSVs are a derived
cache. `rescore_bigdiff.py` rebuilds them, which is what makes a mid-run scoring
correction safe.

Arm labels in `results.tsv` follow `<model>-<engine>-<promptversion>` for the
bake-off arms and `qwen38-nothink-ctx<size>` for the context-tier arms.
`results-v1-ambiguous-prompt.tsv` is the before-arm of the `FILE:LINE` template
fix, kept because it is the evidence for the single biggest prompt gain.

## Traps that cost real runs

Each of these was paid for once. They are listed because none of them is
visible from reading the code.

**Never edit a shell script while it is executing.** Bash reads scripts lazily
from a byte offset, so a running process resumes into shifted content and dies
on a syntax error. This killed a context-tier arm after its small cases and cost
its entire big-diff half. `review.sh` is now covered — each batch runs a frozen
copy of it — but **the runners themselves are not**: `run_eval.sh`,
`run_bigdiff.sh` and `run_ctx_tiers.sh` are still read incrementally by the bash
executing them, so editing one mid-batch splices it exactly as before.

**A real catch can be quoted from either end of a two-line defect.** The
import-after-guard bug was reported once against the registration line and once
against the `__main__` guard above it. A signature list naming one anchor scores
the other as an unmatched finding — a genuine catch that looks like a
fabrication. `score_bigdiff.py` takes a list of anchors per bug for this reason.

**An empty transcript is not a clean review.** `review.sh` writes its verdict at
the end, so an in-flight or crashed run has an empty log. Scoring that as zero
findings makes it read identically to a clean review, which is the one confusion
this fixture exists to catch. `score_bigdiff.py` reports `EMPTY-LOG` instead.

**A port answering is not your server answering.** llama-server exits
immediately when the port is already bound, so a foreign server — the operator's
own, or the previous arm still tearing down — satisfies a bare curl probe while
this arm's server is already dead. The arm then runs to completion and appends a
full set of rows labeled with a context size it never served. `run_ctx_tiers.sh`
checks liveness before reachability *and* asserts the served `n_ctx_slot`,
because the probe order was the symptom and trusting the flag was the cause.

**Fabrication is a count of findings, not of non-zero exits.** Exit 3 and 124
mean there is no usable verdict at all, which is a different failure. Scoring
them as fabrications invents ones that never happened and double-reports the
same run.

**The commit gate blocks the runners' bootstrap commits.** It cannot resolve a
repo whose path comes from a shell variable, which is exactly how both runners
reach their fixture repo. The repos therefore have to exist before the runners
run. They do; recreating them from scratch needs operator approval for the gate.

`git clean` will not remove the big diff's two new files between runs — `git
add -N` puts them in the index, so `git apply` then refuses to overwrite them.
`run_bigdiff.sh` uses `reset --hard` before each run.

## What has been measured

Full write-up and reasoning in `docs/model-choice.md`. In short:

- **Model choice.** Qwen3.8-27B no-think is the default; it scored 31/32 on the
  small cases across four prompt versions with zero fabrications, and completes
  the big diff with all-real findings. Qwen3-Coder is the small-diff fast tier
  and false-cleans the big diff.
- **Context tiers (49152 / 65536 / 98304).** Flat. Identical detection at every
  tier across 36 runs, no untrusted verdict or timeout anywhere. Every big-diff
  run peaked at 13.9–16.6K tokens — about a third of the smallest window — so
  nothing could have changed. Keep 49152; check the audit's "N tokens peak"
  before ever raising it.
- **Frontier baseline.** Four Claude agents on the big diff, verbatim prompts,
  all four scored 4/5 in ~50 s (`bigdiff/frontier-r*.txt`). They all catch
  `cache_evict`, which local under the v6 prompt caught once in eight runs.
  That gap was real headroom, not a capability ceiling — and prompt v7's
  purpose-anchored method then claimed part of it: `cache_evict` 2/5 with the
  reliable trio intact and clean still at zero findings (docs/evict-gap.md;
  labels `qwen38-nothink-purpose2*` in results-bigdiff.tsv).

**On reading single runs.** Per-arm n is 2, and the same case has ranged 45–585
seconds within one arm. Single-run differences here are noise, and this bench
invites over-reading them: during the context-tier work the same claim about one
bug was asserted, retracted, and re-asserted on the strength of one run each
time. Only patterns that repeat across arms or versions should be acted on.
