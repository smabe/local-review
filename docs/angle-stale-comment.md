# Stale-comment angle pass — MEASURED, SHIPPED

Status: hypothesis and decision rule registered 2026-08-18 before any bench
run, per `docs/experiment-loop.md`; benched the same night; every condition of
the pre-registered rule met; `--angle stalecomment` SHIPPED as an opt-in pass.
Nothing between here and "Measured results" was edited after the first run.

## The gap

The default reviewer is *forbidden* to report stale comments: system rule 2
("Never report that documentation, comments, prose, or a README 'should' say
or enforce something") is a measured anti-fabrication guard and stays. The
cost surfaced 2026-08-18 on a real diff: the local pass exited clean while
the frontier review found two stale-documentation defects (a DTO field
contract and a test assertion message still describing a removed validation
rule) — exactly the comments a future session would follow back into a bug.
Stale comments also poison the v7 purpose method, which derives a function's
purpose partly from its comments.

Unlike angle-B (which lost because the default pass already caught its
class), this angle cannot be redundant by construction — the default pass is
banned from the class. The only open question is precision: does a
comment-focused pass fabricate contradictions?

## Hypothesis

A separate opt-in pass (`--angle stalecomment`) with its own narrow system
prompt — rule 2 inverted into "the ONLY reportable defect is a comment the
nearby code contradicts" — catches seeded stale-comment defects with the
comment line quoted verbatim, while staying silent on accurate comments,
in-class-consistent comments (`swallow`'s comment matches its code), and the
18KB big diff.

## The fixture: `bench/cases/stalecomment`

An intended behaviour change with the docstring left stale: duplicate keys in
`parse_config` switch from last-wins to first-wins (`if key in result:
continue` — correct, guards intact, verified by running it), while the
docstring's first line still says "later duplicates win." No code bug is
planted; the contradiction is the only defect. The stale line is ~10 lines
above the hunk, outside default diff context — the pass must read the file,
as the real healthdata case would have required.

`meta`: `expected_exit=0` (calibrated for the DEFAULT pass: correct code,
rule 2 bans the comment finding), `marker=later duplicates win` (scores the
angle arm: `found=1` = marker quoted + exit 4).

## Prompt design

System prompt: a full variant, not an edit to the shared scaffold (the
default prompt is never weakened in place). Keeps the quote gate, the
unsure-omit rule, the read-the-whole-function rule, and the discard-if-agree
rule verbatim in spirit; replaces rule 2 with the comment-only defect class;
scopes judgment to comments describing changed code; states that vague or
incomplete comments and code defects are out of scope for the pass. The
format example quotes a comment line, since the shared example's code quote
would model the wrong anchor.

User prompt: angle-B's shape — OPENING names the one class and the method
(read each changed function's docstring and nearby comments, check each
claim against the code as it now stands); METHOD is empty (the v7 purpose
line trusts comments — this pass interrogates them; the combination is
unmeasured and contradictory). HARD BUDGET, untracked note, finding format,
and final reminder stay byte-identical.

`--angle` is mutually exclusive with `--intent` (angle-B precedent: an intent
frame declares changes correct by definition, which would blanket-excuse the
code side of every contradiction).

## Arms (model: qwen38-gguf-nothink @ 49152, llama-server, served model
verified via /v1/models before labeling)

| arm | label | runs |
|---|---|---|
| angle pass, all 6 small cases | `qwen38-nothink-anglSC` | ×2 |
| default pass, `stalecomment` only | `qwen38-nothink-sc-default` | ×2 |
| angle pass, 18KB bigdiff | `qwen38-nothink-anglSC-big` | ×1 |

Expected map for the angle arm, written before running:

| case | expectation |
|---|---|
| stalecomment | 4, marker line quoted — the point of the exercise |
| clean | 0 — its diff updates the docstring to match; any finding is a fabrication |
| swallow | 0 — its comment ("starts empty rather than crashing") matches its buggy code; flagging it means the pass judges code, not comments |
| offbyone, boolean, leak | 0 — no comment/code contradiction exists; hand-check any finding |
| bigdiff | hand-judge every finding; only a genuine comment/code contradiction is acceptable |

Default-pass arm on `stalecomment`: 0 expected (rule 2). A 4 here is
informative either way: quoting the docstring violates rule 2; quoting the
new code means the v7 purpose method turned a stale docstring into a false
positive on correct code — worth recording, but it does not gate this ship
decision.

## Decision rule (pre-registered)

SHIP the flag iff ALL of:
1. `stalecomment`: 2/2 runs exit 4 with the marker in a QUOTE line.
2. `clean`: 0 findings in both runs.
3. `swallow`, `offbyone`, `boolean`, `leak`: exit 0 in both runs, OR any
   finding is hand-verified as a genuine comment/code contradiction already
   present in the fixture (then the fixture is at fault, noted, and the run
   does not count against the variant).
4. bigdiff: zero findings that are not genuine comment/code contradictions.

Anything less: REVERT the flag, keep the fixture, this doc, and the bench
rows; research online for prior art on comment-consistency prompting before
any second hypothesis, which re-enters the loop at step 1.

## Measured results (2026-08-18/19, qwen38-gguf-nothink @ 49152, llama-server)

Mid-experiment the llama-server died during the first batch's `offbyone` run
(first observed mid-generation death of this engine here); 11 runs recorded as
instant exit-1 junk under `qwen38-nothink-anglSC` / `qwen38-nothink-sc-default`
are server-outage artifacts, not model results. The server was restarted (served
model re-verified) and every invalidated run redone under `-b` labels with a
between-arm liveness guard. Valid runs only, both batches:

| case | angle pass | expectation | met |
|---|---|---|---|
| stalecomment | exit 4 + marker quoted, 2/2 | catch 2/2 | yes |
| clean | 0 findings, 2/2 | silent | yes |
| swallow | 0 findings, 2/2 | silent (comment matches code) | yes |
| leak | 0 findings, 2/2 | silent | yes |
| offbyone | 1 finding, 3/3 (incl. the truncated pre-crash run): quotes the `recent_keys` docstring the planted slice bug contradicts | hand-verify | genuine |
| boolean | 1 finding, 2/2: quotes the validator docstring the planted inversion contradicts | hand-verify | genuine |
| bigdiff ×1 | 2 findings, both the planted `migrate_discard` bug via the module and function docstrings whose migrate-forward promise it breaks; zero fabrications at 18KB | hand-judge | genuine |

Default pass on `stalecomment` ×2: exit 4 both runs, quoting the NEW code
(`if key in result:`) — the v7 purpose method takes the stale docstring as
ground truth and reports the correct, intended line as a defect. The
pre-registered map's second branch: the default pass is not blind to a
contradiction-by-added-line, it MISATTRIBUTES it (and rule 2 forces the blame
onto code). The angle pass reports the same contradiction anchored on the
comment.

Fabrications across all valid runs, every arm: zero. Decision rule conditions
1-4 all met → shipped.

## What the measurement actually established, beyond the rule

- **Contradiction detection is symmetric, and that is a feature.** On fixtures
  where the planted CODE bug violates a documented contract (offbyone, boolean,
  bigdiff's migrate_discard), the angle pass re-finds the bug through its
  comment, deterministically. The pass is not "docs-only" — it is a
  contract-vs-implementation checker whose finding is the disagreement itself;
  which side is wrong is the reviewer's call, which is the honest shape (intent
  is not knowable locally).
- **Stale comments poison the default pass in the misattribution direction.**
  Measured 2/2: v7's purpose method turns a stale docstring over correct code
  into a confident false positive against the code. The angle pass is the
  attribution-correcting counterpart.
- **Limit, untested here: removal-shaped staleness.** This fixture has an added
  line that directly contradicts the docstring. The motivating real-world miss
  (healthdata) was a comment describing REMOVED behaviour with no contradicting
  added line. That shape is the next experiment
  (`docs/angle-stale-removal.md`), pre-registered separately.

## Follow-ups (each enters the loop at step 1 with its own doc)

- **Removal-shaped stale-comment fixture** — see above.
- **Local verifier pass** (operator-requested 2026-08-18): port code-review's
  verifier role — a second local run per finding, prompted to refute it against
  the actual file, audit gating on the verifier verdict. Open question is
  whether a 27B model refutes its own findings at a useful rate; benching it
  needs a seeded FALSE-finding corpus, which zero-fabrication runs do not
  provide.
