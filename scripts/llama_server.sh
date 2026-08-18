#!/bin/bash
# Serve the local review model via llama-server (stability pick over LM Studio's
# MLX engine, which leaks Metal buffer descriptors under long generations —
# see lmstudio-ai/mlx-engine#264).
#
# Usage: scripts/llama_server.sh [path-to-gguf] [extra llama-server flags...]
# Default model: the first Qwen3.8 GGUF found under ~/models or
# ~/.lmstudio/models (the measured default reviewer) -- no silent fallback to
# another model. A Qwen3.8 is served thinking-off with f16 KV, exactly the
# measured arm; any explicitly passed model gets q8_0 KV like the other
# measured arms. Pass a path plus your own flags to serve anything else.
set -euo pipefail

MODEL="${1:-}"
if [[ "$MODEL" == -* ]]; then MODEL=""; else if [[ $# -gt 0 ]]; then shift; fi; fi
if [[ -z "$MODEL" ]]; then
  MODEL=$(find ~/models ~/.lmstudio/models -iname "*qwen3.8*.gguf" ! -iname "*mmproj*" 2>/dev/null | head -1 || true)
  # No silent substitute: serving a different model under the default alias
  # would masquerade as the measured reviewer end to end. Another model is
  # always one explicit path away.
  [[ -n "$MODEL" ]] || { echo "No Qwen3.8 GGUF found under ~/models or ~/.lmstudio/models — download it (see README step 1) or pass a path: scripts/llama_server.sh <model.gguf>" >&2; exit 1; }
fi
[[ -f "$MODEL" ]] || { echo "Not a file: $MODEL" >&2; exit 1; }

# Match the measured arms exactly: Qwen3.8 runs thinking-off with f16 KV (its
# hybrid cache is small); anything else gets the q8_0 KV the other arms used.
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
