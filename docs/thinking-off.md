# Thinking genuinely off — is the `nothink` arm better without it?

Status: registered 2026-08-21 BEFORE any run, per `docs/experiment-loop.md`.
Nothing above "Measured results" may be edited after the first run.

## The gap

`docs/sampling-noise-floor.md` found that `--reasoning-budget 0`, which
`scripts/llama_server.sh:42` bakes in for every Qwen3.8, is **inert** on build
`b10450-ece963f41`. The arm named `qwen38-gguf-nothink` has been thinking for
its whole measured history: 26 preserved pi event streams carry thinking
blocks, mean 6.7 blocks and 4,695 characters per run.

So a genuinely thinking-off configuration has never been benched here, and the
repo's central model-choice claim — that no-think Qwen3.8 is the accuracy pick
— was measured against something that was thinking.

## Mechanism (probed, not assumed)

`llama-server` offers three controls. Probed against the running server, same
prompt, `reasoning_content` length as the readout:

| control | reasoning emitted |
|---|---|
| `--reasoning-budget 0` (what the repo ships) | 744 chars — INERT |
| request-level `chat_template_kwargs: {enable_thinking: false}` | 0 |
| request-level `reasoning_effort: "none"` | 0 |
| **server-level `-rea off`** | **0** |

pi sends neither request-level control (`supportsReasoningEffort: false` in the
llamaserver compat block), so the fix has to be server-side. `-rea off`
verified: 0 reasoning chars, normal content, server started as
`scripts/llama_server.sh -rea off`.

## Hypothesis

With thinking genuinely off, detection composition on the seeded cases and the
bigdiff is no worse than the same configuration with thinking on, at lower
latency.

Directional intuition is deliberately absent: `evict-gap.md` found thinking
reached `cache_evict` where no-think did not, which argues thinking HELPS —
but that comparison was budget -1 against budget 0, and budget 0 was thinking.
Nobody knows which way this goes.

## Design

Every arm has an exact matched counterpart already on disk from
`sampling-noise-floor.md`: same fixtures, same temperature 0, same script sha
`40cf4941b7dc`. Only reasoning changes. Served config recorded per step 3 —
alias `qwen38-gguf-nothink`, GGUF `Qwen3.8-27B-Q6_K.gguf`, `-rea off` probe-
confirmed before labeling.

| arm | label | baseline it is compared against | runs |
|---|---|---|---|
| small cases, thinking off | `qwen38-t0-nothink-det` | `qwen38-t0-det` | ×2 |
| bigdiff `--rounds 3`, thinking off | `qwen38-t0-nothink-r3` | `qwen38-t0-r3` | ×2 |
| bigdiff `--rounds 6`, thinking off | `qwen38-t0-nothink-r6` | `qwen38-t0-r6` | ×2 |

Cases: `swallow leak offbyone clean`. `clean` is the fabrication control.

Two runs per arm, not one: the shipped one-run standard licenses a single run
only where determinism is already established for that CONFIGURATION, and it is
not established with reasoning off. The second run tests determinism; it does
not add a sample. If the two disagree, that is itself the finding and the
comparison below is void.

## Decision rule (pre-registered)

SHIP (`-rea off` becomes the default in `scripts/llama_server.sh`, with README,
`skill/SKILL.md` and CLAUDE.md corrected) iff ALL of:

1. `clean` reports 0 findings in every run.
2. Both runs of every arm agree (determinism holds with reasoning off).
3. Small cases: `found` is >= baseline on every case — offbyone 1, leak 1,
   swallow 0. No catch lost.
4. bigdiff: per-bug composition is a superset-or-equal of baseline at BOTH
   rounds settings — r3 >= {import_after_guard, migrate_discard, export_exit0},
   r6 >= {those three, cache_evict, export_default_ns} — with zero unmatched
   findings in either.
5. Both test gates green.

Otherwise: no ship, `-rea off` stays out of the default, and the doc records
which bugs were lost. Either way the rows and this doc stay.

Note on clause 4's shape. This is the same conjunctive "A >= B on every bug"
rule that `sampling-noise-floor.md` showed rejects a genuinely-equal variant
62% of the time at n=3. It is safe HERE and only here because both sides are
deterministic: with zero sampling noise the false-reject rate from noise is
zero. The rule shape is licensed by clause 2, and if clause 2 fails the rule
is void along with it.

Secondary, recorded but NOT part of the rule: wall-clock per run against the
matched baseline. Reasoning tokens cost time, and the baseline runtimes are
known exactly (offbyone 60s, leak 180s, swallow 146s, clean 44s, bigdiff
~755s r3 / ~780s r6).

## Measured results (2026-08-21, Qwen3.8-27B Q6_K @ 49152, llama-server `-rea off`)

### Verdict: NO SHIP. Thinking is load-bearing for this pipeline.

Small cases, 2 runs each, against the matched thinking-on baseline
(`qwen38-t0-det`, same fixtures, same temperature 0, same script sha):

| case | thinking ON (baseline) | thinking OFF run 1 | thinking OFF run 2 |
|---|---|---|---|
| `offbyone` | exit 4, found, 60s | **exit 124 — watchdog, 900s** | **exit 124 — watchdog, 901s** |
| `leak` | exit 4, found, 180s | **exit 124 — watchdog, 901s** | **exit 124 — watchdog, 900s** |
| `swallow` | exit 4, 1 finding, 146s | exit 0, "No findings.", 29s | **exit 124 — watchdog, 900s** |
| `clean` | exit 0, 44s | exit 0, 24s | exit 0, 24s |

Decision rule: **FAILS clause 2** (determinism — `swallow` gave a 29-second
false clean on one run and a 900-second watchdog kill on the next) and **FAILS
clause 3** (both `offbyone` and `leak` lost catches the baseline made 4/4).
Clause 1 passes, but only trivially: `clean` is the one case where producing
nothing is the right answer.

### Replication with a corrected instrument (2026-08-21)

The arm above disables thinking with the server flag `-rea off`. Since
`--reasoning-budget 0` turned out to misbehave, a server flag is a suspect
instrument, so the same decision rule was re-run through a completely different
control: pi's `samplingParams` is documented as "a free-form object merged
verbatim into every request body ... its keys win"
(pi `docs/models.md`), and only OpenAI-compatible APIs apply it — which
`llamaserver` is. So thinking can be disabled per REQUEST, leaving the server
in its shipped configuration:

    "id": "qwen38-gguf-truly-nothink",
    "samplingParams": {
      "temperature": 0,
      "chat_template_kwargs": { "enable_thinking": false }
    }

Verified end-to-end before benching — pi call with the id: 0 thinking chars;
same call on `qwen38-gguf-nothink`: 178. (`thinking: {"type":"disabled"}` was
also tried and is byte-identical to baseline — it is the Anthropic Messages
shape, and llama.cpp's OpenAI endpoint drops the unknown field silently.)

Arm `qwen38-ctk-nothink`, 4 cases x 2, watchdog lowered to 420 s because a
healthy run on these cases finishes in 44-180 s:

| case | thinking ON (baseline) | corrected thinking-off, both runs |
|---|---|---|
| `swallow` | exit 4, 1 finding, 147s | **exit 124 — watchdog, 420s** |
| `leak` | exit 4, caught, 176s | **exit 124 — watchdog, 420s** |
| `offbyone` | exit 4, caught, 60s | **exit 124 — watchdog, 420s** |
| `clean` | exit 0, 69s | exit 0, 25s / 24s |

Six of eight runs produced a ZERO-BYTE verdict. Only `clean` — the one case
where emitting nothing is the correct answer — completed. Stderr from a killed
run: `47/47 tool calls ok, 0 defect(s), 8851 tokens peak` then `empty response
after 47 tool call(s)`, the same shape as the `-rea off` arm's 95 calls at the
longer watchdog.

**The conclusion is therefore not an artifact of the flag.** Two independent
mechanisms — one at the server, one in the request body, with the server in its
shipped configuration for the second — collapse the reviewer identically.

Caveat against over-reading: `swallow` timed out on both runs here where the
`-rea off` arm gave a 29 s false clean then a hang. That looks like better
determinism and is not — a watchdog kill says the run did not finish, not that
the model would have produced identical output. Clause 2 of the decision rule
cannot be evaluated on timeout rows, in either arm.

### The mechanism: it repeats ONE computation, it does not read forever

First stated here as "the model never stopped reading". That was wrong, and the
event stream says so. A reasoning-off run was re-run with `--json` and pi's
stream parsed by tool-call id:

    thinking blocks: 0
    UNIQUE tool calls: 21    distinct payloads: 7
    assistant text blocks: 0

      x15  bash  python3 -c "
                 d={'a':1,'b':2,'c':3,'d':4,'e':5}
                 keys=list(d)
                 print('n=3:', keys[-3-1:-1])
                 print('n=1:', keys[-1-1:-1])
                 print('n=5:', keys[-5-1:-1])"
      x1   bash  git status --short && git diff HEAD
      x1   bash  git ls-files --others --exclude-standard
      x1   read  store.py
      x1   bash  cat out.json; ls

It reads the diff, the untracked files and `store.py` exactly ONCE each. It
then reaches the planted defect — `keys[-n - 1:-1]` in `recent_keys`, which is
the `offbyone` fixture's marker — writes a correct little experiment to probe
the slice, and issues that **byte-identical command 15 times**, getting the
same answer every time. Zero assistant text blocks: it never emits a single
word of output before the watchdog kills it.

So it is repetition of one computation, not exploration. The bench's
"95/95 tool calls ok" footer counts calls, not distinct ones; the distinct
count is what shows the shape.

The reading that survives the evidence: with the reasoning channel suppressed
there is nowhere to record the CONCLUSION of a computation, so the computation
is re-issued instead of being concluded. That is a description of the observed
behaviour, not a verified account of the model's internals, and it is not
proven by this run.

### Is the split-out reasoning inert? No — it is carried forward in full

`--reasoning-format deepseek` moves reasoning into `message.reasoning_content`
instead of `message.content`. That is RESPONSE SHAPING only: it changes where
the text lands for the client, not whether the model sees it.

Verified by logging the templated prompts llama-server actually builds
(`-lv 10`, one full review, four generations):

| generation | prompt chars | `<think>` | `</think>` | assistant turns |
|---|---|---|---|---|
| 1 | 5,706 | 1 | 0 | 1 |
| 2 | 6,696 | 2 | 1 | 2 |
| 3 | 8,819 | 3 | 2 | 3 |
| 4 | 12,219 | 4 | 3 | 4 |

Exactly n CLOSED `<think>...</think>` blocks for n prior assistant turns, plus
one unclosed opener for the current generation. **Every prior turn's full
reasoning trace is re-templated into the next prompt** — not merely the last
one, which is what `--reasoning-preserve`'s help text ("not just the last
assistant message") had suggested the default would be. pi reads
`reasoning_content`, keeps it as a thinking block carrying a
`thinkingSignature`, and sends it back; the server re-templates it.

So reasoning is load-bearing twice over: within a turn it is generated before
the answer in the same pass, and across turns it is the model's only record of
what it already worked out.

That makes the §mechanism finding coherent rather than merely observed. With
`-rea off` there is no such record, and the observed behaviour is a model
re-issuing one byte-identical computation 15 times. Consistent with two
independent measurements — still an explanation, not a proven causal account.

### The inert flag, explained

The same log shows what `--reasoning-budget 0` actually does here:

    srv eval_llama_c: reasoning budget: tokens=0,
        generation_prompt='<|im_start|>assistant\n<think>\n',
        start=1 toks, end=2 seqs, forced=1 toks

The budget IS registered as 0, and the server responds by force-prefilling an
OPENING `<think>` and never closing it — on all four generations. A working
budget-0 would inject a closed, empty `<think>\n\n</think>`. Opening the block
is the opposite of suppressing it.

Likely why: the same log reports `Using specialized template: Qwen3-Coder` and
`chat format: peg-native` — four times, for a **Qwen3.8-27B** model. The
embedded template is being matched to the Qwen3-Coder handler (a non-thinking
model family), and the prompt carries Qwen3-Coder's `<function=...>` inside
`<tool_call>` tool syntax. Template mis-detection is the leading candidate for
why budget 0 misbehaves; that specific link is NOT established here and would
need its own probe.

### Prior art: adjacent, not confirmatory

Searched before settling on the above. No published report matches this
configuration (llama.cpp `-rea off`, Qwen3.8, agentic tool loop). What exists:

- A vLLM/SGLang report on Qwen3.5 where the loop has the INVERSE cause —
  thinking is ON and `reasoning_content` is stripped from the assistant history,
  so "the model loses context and repeat[s] the tool call"
  ([cc-switch#2712](https://github.com/farion1231/cc-switch/issues/2712)).
  Same symptom, opposite trigger, different stack.
- General reports of Qwen endless-loop and tool-parser problems in llama.cpp,
  mostly template- and parser-shaped
  ([llama.cpp#22684](https://github.com/ggml-org/llama.cpp/issues/22684),
  [netclaw](https://netclaw.dev/troubleshooting/llama-cpp/)).
- One article that a search summary claimed explained thinking-disabled tool
  loops does NOT say that when read
  ([lyn.one](https://lyn.one/reasoning-control-flow)) — it covers tool parsing
  with thinking ON. Recorded because the summary was persuasive and wrong.

None of these is evidence for the conclusion above. They are listed so the next
person does not re-search the same ground.

The 3-round budget documented as an MLX stability guard has a second
justification either way: with reasoning suppressed this model blew past it
without producing a verdict at all.
