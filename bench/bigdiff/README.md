# bigdiff — the validation that settled the default (2026-08-18)

An 18.3 KB working-tree diff over seven files: apply `case.patch` to a repo
built from `base/` (git init, add, commit, then `git apply case.patch` plus
`git add -N validators.py journal.py` for the two new files). Three seeded
bugs — a cache cap that evicts the NEWEST entry (`cache.py`, `max(...ts)`),
a v1→v2 migration whose return value is discarded (`serialize.py`), an
export error path that returns 0 (`cli.py`) — plus, by accident, two real
ones: the `import` command registered after the `__main__` guard, and
export writing only the default namespace.

Results (default settings, two runs per model; verdicts in `*-r*.txt`):

- `qwen38-gguf-nothink`: exit 4 both runs, 556 s and 881 s. Findings all
  real, zero fabrications; caught the migration and export bugs plus the
  accidental ones; missed the cache eviction both runs. The historical
  thinking-mode 19 KB stall did not reproduce.
- `qwen3coder-gguf`: exit 0 both runs, ~20 s — "No findings." A false
  clean at exactly the scale where review matters; this is why it lost the
  default despite the speed.
