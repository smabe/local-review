# The cache-eviction gap — probes, then (maybe) a prompt variant

Target, from docs/model-choice.md "The frontier gap, located": the bigdiff
`cache_evict` bug (`victim = max(...ts)` in `_remember` evicts the NEWEST
entry) — frontier 4/4, local 1/8 (variance). The one measured local miss that
is large, consistent, and one-directional.

## Step 1 — config probes before prompt design (running 2026-08-18)

Two cheaper explanations get eliminated (or crowned) before any prompt work,
2 bigdiff runs each:

| arm | question |
|---|---|
| `qwen38-nothink-r6` (`--rounds 6`) | Is the 3-round budget binding on an 18KB diff? The cap is documented as an MLX stability guard; llama-server doesn't need it, and the benchmark session flagged (as an untested hypothesis) that it may be inherited from an engine we stopped using. |
| `qwen38-think-bigdiff` (`--reasoning-budget -1`, alias `qwen38-gguf-think`) | Does reasoning close the gap? Frontier catches this bug via reasoning, not via different instructions — same system and user prompts. Thinking mode has never run the big diff (small cases only, in the bake-off). Thinking is VERIFIED by a probe request (`reasoning_content` present) before the arm runs, since llama_server.sh bakes `--reasoning-budget 0` for Qwen3.8 and the arm relies on a trailing-flag override. |

Decision: if either arm catches `cache_evict` 2/2 without new misses or
fabrications, the "variant" is a documented config recommendation (e.g. "use
thinking mode for large diffs"), and prompt work stops. Cost is the only
downside measured so far for thinking (~40% slower); rounds cost nothing on
llama-server.

### Probe results (2026-08-18)

| arm | run | hits | bugs | fabrications |
|---|---|---|---|---|
| `qwen38-nothink-r6` | 1 | 4 | import_after_guard, migrate_discard, export_exit0, export_default_ns | 0 |
| `qwen38-nothink-r6` | 2 | 3 | import_after_guard, migrate_discard, export_exit0 | 0 |
| `qwen38-think-bigdiff` | 1 | 3 | migrate_discard, **cache_evict**, export_exit0 | 0 |
| `qwen38-think-bigdiff` | 2 | 3 | migrate_discard, import_after_guard, export_exit0 | 0 |

Neither meets the 2/2 bar. Rounds are NOT the constraint (two extra rounds
changed nothing on the target bug), which also retires the benchmark session's
inherited-cap hypothesis for recall purposes. Thinking reached the bug once in
two runs (vs 1/8 historic no-think) — suggestive that reasoning is the missing
ingredient, not conclusive at n=2, and its catching run dropped
import_after_guard (composition shuffles under thinking). Thinking-mode
runtimes were comparable to no-think here (571–690 s), not the ~40% slower the
small cases measured.

## Step 2 — prompt variant (triggered: both probes failed the bar)

Design constraints, all measured: no category lists (v4 fabricated on clean);
shape-of-ask beats content-of-instructions; the finding format and audit stay
untouched.

Sketch (purpose-anchored review): during the reading rounds — not in the
verdict — the reviewer writes one line per changed function stating what the
function is supposed to do, derived from its name, docstring, comments, and
callers. It then judges each changed line against that stated purpose; a line
that contradicts the function's own stated purpose is a defect. The verdict
format is unchanged; purpose notes live in intermediate turns, which the audit
already ignores (only the LAST assistant message is the verdict).

Why this shape might reach the eviction bug: `_remember` + a bounded cache
implies "make room by dropping the stalest entry" — stating that first turns
`max(...ts)` into a visible contradiction rather than a plausible-looking
line. Known risks to bench for: rule 3 tension (purpose statements drifting
into "confirms the change works"), and the intent-frame lesson (a stated
purpose can make matching code unfalsifiable — here the purpose is
self-derived, so a wrong derivation hides the bug it was meant to catch).
Bench exactly like angle-B: small cases + clean ×2, bigdiff ×2, per-bug
composition against the default arm, pre-registered kill criteria.

### Purpose-variant results so far (2026-08-18; extension interrupted mid-run)

Implemented for the bench as a `LOCAL_REVIEW_PROMPT_VARIANT=purpose` env hook
in `review.sh` — since REMOVED (the method shipped unconditionally as v7; see
the shipped note at the end). Labels `qwen38-nothink-purpose` (+`-b`).

Bigdiff, runs that produced a verdict:

| run | hits | cache_evict | unmatched |
|---|---|---|---|
| purpose 1 | **5/5** | ✓ | 0 |
| purpose 2 | 3/3 | — | 0 |
| purpose-b 1 | 4 | — | 1 — adjudicated REAL (see below) |
| purpose-b 2 | **5/5** | ✓ | 0 |
| purpose-b 3 | — | — | exit 3: 9/9 tool calls ok, 23K tokens peak, then NO verdict |

Against the default arm's baseline: `cache_evict` 2/4 vs 1/10 recorded;
mean known-bug hits ≈4.4/run vs 3.3; `export_default_ns` 2/4 vs 2/8; zero
fabrications. The two 5/5 runs are the only local 5/5s ever recorded. Costs
measured: one run in five burned 23K tokens across 9 tool calls and emitted no
final verdict (audit exited 3 — an honest re-run, not a false clean), and
verdict runs trend longer (665–1243 s vs 584–725 baseline).

The purpose-b 1 unmatched finding is a REAL unseeded defect, verified against
the fixture source: `rename_namespace(old, new)` validates `new` for `SEP`
but not `old`, so a malformed `old` ("a:b") silently moves records out of
namespace "a" instead of raising as `qualify()` would (case.patch, store.py
hunk). The model's projected key ("z:c") is off — `split_key` yields "b:c",
so the record lands at "z:b:c" — but the mechanism and the asymmetry are
correct. Not a fabrication; the variant's fabrication ledger stays clean.

Small cases across all purpose runs so far: 12/13 defect catches (one `leak`
miss, inside the default arms' own variance band — they miss one of
swallow/leak per arm), `clean` 0 findings in 2/2 completed runs,
`removedguard` 2/2. The interrupted extension owes: the rest of small-case
rounds 3–4 (leak, clean, removedguard ×2 — `clean` at n=2 is the thinnest
number here) and ideally 1–2 more bigdiff runs. Resume with the same
`qwen38-nothink-purpose-b` label for the missing small cases only via
`LOCAL_REVIEW_EVAL_CASES`, and a fresh `-c` label for any further bigdiff
runs.

Open question before promoting to default (v7): none of the numbers argue
against it yet — the decision needs the completed `clean` runs and an
operator call on the no-verdict cost tail (exit 3 forces a manual re-run
roughly one time in five on very large diffs).

## The iteration loop and where it ended (2026-08-18)

The bench then ran as a diagnose-fix-rerun loop. Two fixes came out of it:

1. **The no-verdict tail was diagnosed and eliminated.** A captured `--json`
   run showed the mechanism: "write purpose notes in your working turns"
   routed the entire analysis into the model's thinking channel, and the
   final turn hit the 8192-token generation cap still thinking
   (`stopReason=length`, no text block) — so no verdict ever arrived. The
   phrasing was replaced by a silent reading directive with a brevity guard
   ("determine each function's purpose as you read, then judge its lines
   against it; keep deliberation brief") — **prompt `purpose2`**, the text
   now in review.sh's METHOD block.
2. **The scorer gained a third `import_after_guard` anchor**
   (`def cmd_import(store, args):`) after a real catch scored as unmatched;
   stored rows rescored via `rescore_bigdiff.py`, all arms under one rule set.

### Final numbers — purpose2 vs the default prompt

| | default (v6) | purpose2 |
|---|---|---|
| bigdiff `cache_evict` | 1/10 runs | **2/5 runs** |
| bigdiff mean known-bug hits | ~3.3 | **3.8** (4,3,4,4,4) |
| bigdiff reliable trio | 6/6 | 5/5 |
| bigdiff no-verdict runs | 0 | 0 (purpose1 had 1/7; cause fixed) |
| bigdiff unmatched findings | 0 | 0 |
| small defect cases | 7/8 per arm (one swallow/leak miss per arm) | 8/10 (same pattern: one swallow miss, one leak miss) |
| clean diffs | 0 findings | **4/4 at 0 findings** (variant family 10/10) |
| run time (bigdiff) | 550–725 s | 588–784 s |

The purpose1 arms additionally caught a REAL unseeded defect
(`rename_namespace` old-namespace validation asymmetry, adjudicated above) —
zero fabrications anywhere in the family, across 12 bigdiff runs and 26
small-case runs.

### Loop exit and recommendation

Exit criteria met: clean ≥4 runs at zero findings, `cache_evict` at the 2/5
bar with the reliable trio intact, the no-verdict tail explained and gone,
small cases inside the baseline variance band. **Recommendation: promote the
purpose2 METHOD text into the default prompt (v7)** — always-on, dropping the
`LOCAL_REVIEW_PROMPT_VARIANT` scaffolding — and take the README/SKILL.md/tests
through the normal shipping cycle.

**SHIPPED as v7, 2026-08-18.** The env-var hook no longer exists anywhere in
either repo: the Method line is unconditional in `review.sh` on the default
path, and deliberately ABSENT on the `--intent` path — the intent frame and
the purpose method carry two competing definitions of "correct", and the
combination was never benched. Reproduction notes for the historical arms:
the v6 (pre-Method) prompt is the `review.sh` at any commit before this
shipment — labels in `bench/results.tsv` encode the prompt arm
(`-v6`, `-purpose`, `-purpose2`), and re-running an old arm means checking
out the commit that carried its prompt, not flipping a flag.
