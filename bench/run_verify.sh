#!/usr/bin/env bash
# run_verify.sh PROVIDER MODEL RUNS LABEL — verifier capability probe over
# bench/verify/items (docs/verifier-pass.md). Appends TSV rows to
# bench/results-verify.tsv: label item run verdict truth gating secs agree
set -uo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$EVAL_DIR/eval-repo"
RESULTS="$EVAL_DIR/results-verify.tsv"
PROVIDER="$1"; MODEL="$2"; RUNS="${3:-1}"; LABEL="${4:?label required}"

SYSTEM_PROMPT='You are a review verifier. You do not write or fix code. You are given ONE finding from an earlier automated review of this repository, and your entire job is to decide whether it survives adversarial checking.
Rules you must obey:
1. First read the named file. If the quoted line does not appear in it, the finding is refuted -- a finding that cannot be located is not a finding.
2. Re-derive the DEFECT claim from the code alone. Actively look for the guard, type, short-circuit, or call pattern that would make the claimed FAILURE impossible.
3. Verdict "refuted" requires constructible evidence: name the exact line, guard, or language rule that defeats the claim. Plausible doubt is not evidence.
4. If you cannot construct such a refutation, the verdict is "real" -- this pass exists to kill provably false findings, not to second-guess plausible ones.
5. Judge only the finding you were given. Never report new defects.
Your entire output is exactly two lines:
VERDICT: real
REASON: <one line>
or
VERDICT: refuted
REASON: <one line>'

mkdir -p "$EVAL_DIR/logs"
if [ ! -d "$REPO/.git" ]; then
  mkdir -p "$REPO"; cp "$EVAL_DIR"/base/*.py "$REPO/"
  git -C "$REPO" init -q; git -C "$REPO" add -A
  git -C "$REPO" commit -qm "base: store + parser"
fi
[ -f "$RESULTS" ] || printf 'label\titem\trun\tverdict\ttruth\tgating\tsecs\tagree\n' > "$RESULTS"

for run in $(seq 1 "$RUNS"); do
  for dir in "$EVAL_DIR"/verify/items/*/; do
    item="$(basename "$dir")"
    fixture=""; truth=""; gating=""
    while IFS='=' read -r k v; do
      case "$k" in fixture) fixture="$v";; truth) truth="$v";; gating) gating="$v";; esac
    done < "$dir/meta"

    git -C "$REPO" checkout -q -- .
    git -C "$REPO" apply "$EVAL_DIR/cases/$fixture/case.patch"

    PROMPT="An automated reviewer of the uncommitted changes in this repository reported the finding below. Adversarially check it against the actual files.
HARD BUDGET: at most 3 rounds of tool calls, then give your verdict.
$(cat "$dir/finding.txt")"

    log="$EVAL_DIR/logs/$LABEL-$item-r$run.txt"
    t0=$(date +%s)
    ( cd "$REPO" && pi --provider "$PROVIDER" --model "$MODEL" \
        --no-session -nc -ns --exclude-tools edit,write \
        --system-prompt "$SYSTEM_PROMPT" --mode json -p "$PROMPT" </dev/null ) \
      > "$log.raw" 2> "$log.err"
    secs=$(( $(date +%s) - t0 ))

    # Last assistant text block only -- tool results also arrive as message_end.
    python3 - "$log.raw" <<'PY' > "$log"
import json, sys
txt = ""
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    m = e.get("message") or {}
    if e.get("type") == "message_end" and m.get("role") == "assistant":
        t = "".join(c.get("text", "") for c in m.get("content", []) if c.get("type") == "text")
        if t.strip(): txt = t
print(txt)
PY
    # No sed alternation: BSD sed has no \| in basic regex. Strip + normalise,
    # then whitelist.
    verdict=$(sed -n 's/^VERDICT:[[:space:]]*//p' "$log" | tail -1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$verdict" in real|refuted) ;; *) verdict=none ;; esac
    agree=0; [ "$verdict" = "$truth" ] && agree=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$LABEL" "$item" "$run" "$verdict" "$truth" "$gating" "$secs" "$agree" | tee -a "$RESULTS"
  done
done
git -C "$REPO" checkout -q -- .
