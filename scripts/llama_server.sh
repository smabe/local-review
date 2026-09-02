#!/bin/bash
# Serve the local review model via llama-server (stability pick over LM Studio's
# MLX engine, which leaks Metal buffer descriptors under long generations —
# see lmstudio-ai/mlx-engine#264).
#
# Usage: scripts/llama_server.sh [path-to-gguf] [extra llama-server flags...]
# Default model: DEFAULT_MODEL below, named outright. A Qwen3.8 is served with
# --reasoning-budget 0 (inert on the measured build, so it thinks -- see below
# and docs/thinking-off.md) and f16 KV, exactly the measured arm; any explicitly passed
# model gets q8_0 KV like the other measured arms. Pass a path plus your own
# flags to serve anything else.
set -euo pipefail

# The measured reviewer, named rather than discovered. Two Qwen3.8 Q6_K quants
# on one machine (Unsloth's imatrix build in ~/models, lmstudio-community's
# here) share a filename, so the old `find ... | head -1` picked one by the
# order its roots happened to be listed in -- a coin flip deciding which model
# every bench row describes. Discovery survives only as the fresh-install
# fallback below.
DEFAULT_MODEL="$HOME/.lmstudio/models/lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q6_K.gguf"

MODEL="${1:-}"
if [[ "$MODEL" == -* ]]; then MODEL=""; else if [[ $# -gt 0 ]]; then shift; fi; fi
if [[ -z "$MODEL" ]]; then
  if [[ -f "$DEFAULT_MODEL" ]]; then
    MODEL="$DEFAULT_MODEL"
  else
    # Fresh install: README step 1 downloads exactly one GGUF, so one match is
    # the expected case.
    FOUND=$(find ~/models ~/.lmstudio/models -iname "*qwen3.8*.gguf" ! -iname "*mmproj*" 2>/dev/null || true)
    N=$(printf '%s\n' "$FOUND" | grep -c . || true)
    # No silent substitute: serving a different model under the default alias
    # would masquerade as the measured reviewer end to end. Another model is
    # always one explicit path away -- which is also the answer to an ambiguous
    # match, since quants of one model differ in measured accuracy.
    if [[ "$N" -eq 0 ]]; then
      echo "No Qwen3.8 GGUF found under ~/models or ~/.lmstudio/models — download it (see README step 1) or pass a path: scripts/llama_server.sh <model.gguf>" >&2
      exit 1
    fi
    if [[ "$N" -gt 1 ]]; then
      echo "Several Qwen3.8 GGUFs found, and none at the default path ($DEFAULT_MODEL). Quants of one model differ in measured accuracy, so this is not guessed at — pass the one you want: scripts/llama_server.sh <model.gguf>" >&2
      printf '%s\n' "$FOUND" | sed 's/^/  /' >&2
      exit 1
    fi
    MODEL="$FOUND"
  fi
fi
[[ -f "$MODEL" ]] || { echo "Not a file: $MODEL" >&2; exit 1; }

# Match the measured arms exactly: Qwen3.8 runs with f16 KV (its hybrid cache
# is small); anything else gets the q8_0 KV the other arms used.
#
# --reasoning-budget 0 does NOT disable thinking on this build (b10450): the
# model reasons anyway, ~6 blocks / 4.7K chars per review run, and every
# accuracy number in this repo was measured that way. DO NOT "fix" it to
# `-rea off`, which genuinely works and destroys the reviewer: benched
# 2026-08-21, the model re-issued ONE byte-identical bash command 15 times
# (7 distinct calls out of 21), emitted no verdict at all, and lost every catch
# it makes with reasoning on. The flag stays inert on purpose. Evidence and the
# full arm table: docs/thinking-off.md.
# Case-insensitive on the filename -- quantizers vary the casing.
REASONING_FLAGS=()
CACHE_FLAGS=(--cache-type-k q8_0 --cache-type-v q8_0)
case "$(basename "$MODEL" | tr '[:upper:]' '[:lower:]')" in
  *qwen3.8*)
    REASONING_FLAGS=(--reasoning-format deepseek --reasoning-budget 0)
    CACHE_FLAGS=()
    ;;
esac

echo "Serving: $MODEL"
exec llama-server \
  -m "$MODEL" \
  --alias "${LLAMA_ALIAS:-qwen38-gguf-nothink}" \
  --port 8080 \
  --jinja \
  --ctx-size "${LLAMA_CTX:-49152}" \
  --parallel 1 \
  --flash-attn on \
  ${CACHE_FLAGS[@]+"${CACHE_FLAGS[@]}"} \
  ${REASONING_FLAGS[@]+"${REASONING_FLAGS[@]}"} \
  "$@"
# --jinja: required for the Qwen chat templates + tool-call parsing.
# --ctx-size: 49152 default — the size every accuracy number was measured at.
#   LLAMA_CTX=98304 is measured SAFE on llama-server+Qwen3.8 (31.5 GB wired on
#   a 48 GB machine, 2026-08-18; the old 96K kernel panic was MLX/LM Studio) but
#   accuracy above 49152 is unmeasured, and pi's contextWindow in models.json
#   must be raised to match or the extra room goes unused.
# --parallel 1: pi is a single client; parallel N splits ctx into N slots.
# --cache-type-k q8_0: halves K-cache memory; community-standard for agent work.
