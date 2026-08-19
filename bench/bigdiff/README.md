# bigdiff — the validation that settled the default (2026-08-18)

An 18.3 KB working-tree diff over seven files: apply `case.patch` to a repo
built from `base/` (git init, add, commit, then `git apply case.patch` plus
`git add -N validators.py journal.py` for the two new files). Three seeded
bugs — a cache cap that evicts the NEWEST entry (`cache.py`, `max(...ts)`),
a v1→v2 migration whose return value is discarded (`serialize.py`), an
export error path that returns 0 (`cli.py`) — plus, by accident, two real
ones: the `import` command registered after the `__main__` guard, and
export writing only the default namespace. A sixth real bug — the
`rename_namespace` prefix match on an unvalidated `old` — was discovered
2026-08-19 by a bench arm and adopted (`rename_prefix` in the scorer).

Results (default settings, two runs per model; verdicts in `*-r*.txt`):

- `qwen38-gguf-nothink`: exit 4 both runs, 556 s and 881 s. Findings all
  real, zero fabrications; caught the migration and export bugs plus the
  accidental ones; missed the cache eviction both runs. The historical
  thinking-mode 19 KB stall did not reproduce.
- `qwen3coder-gguf`: exit 0 both runs, ~20 s — "No findings." A false
  clean at exactly the scale where review matters; this is why it lost the
  default despite the speed.

## Frontier baseline (2026-08-18, added during the context-tier bench)

Four Claude agents, same system prompt, same user prompt including the 3-round
budget, same 18349-byte diff, no knowledge that the fixture is seeded. Verdicts
in `frontier-r1.txt` … `frontier-r4.txt` (a fifth run ignored its working
directory and reviewed the harness instead; discarded — the method has a
compliance failure mode a hermetic harness does not).

All four runs: **4 of the (then) 5 known bugs, zero unmatched findings, ~50 s.** All caught
the cache eviction; all missed the default-namespace export.

Why this was run: the cache eviction (`max(...ts)` evicts the NEWEST entry) had
been missed on nearly every local run on record, and there was no way to tell
whether it was a prompt problem or a bug too hard to catch under this contract.
It is catchable — so the gap was real headroom, not a ceiling. (An earlier
"local is not a strict subset of frontier" reading of the export-bug split was
RETRACTED the same day: local 2-of-many vs frontier 0/4 is not distinguishable
from noise.) The headroom was then partly claimed: prompt v7's purpose-anchored
method (docs/evict-gap.md) lifted the cache-eviction catch to 2/5 with the
reliable trio intact and zero fabrications.
