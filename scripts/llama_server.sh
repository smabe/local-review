#!/bin/bash
# Serve the local review model via llama-server (stability pick over LM Studio's
# MLX engine, which leaks Metal buffer descriptors under long generations —
# see lmstudio-ai/mlx-engine#264).
#
# Usage: scripts/llama_server.sh [path-to-gguf] [extra llama-server flags...]
# Default model: first Qwen3-Coder GGUF found under ~/.lmstudio/models or ~/models.
# Extra flags go straight to llama-server -- e.g. the measured accuracy pick:
#   scripts/llama_server.sh ~/models/Qwen3.8-27B-Q6_K.gguf \
#     --reasoning-format deepseek --reasoning-budget 0
set -euo pipefail

MODEL="${1:-}"
if [[ "$MODEL" == -* ]]; then MODEL=""; else if [[ $# -gt 0 ]]; then shift; fi; fi
if [[ -z "$MODEL" ]]; then
  MODEL=$(find ~/.lmstudio/models ~/models -iname "*qwen3-coder*.gguf" ! -iname "*mmproj*" 2>/dev/null | head -1 || true)
fi
[[ -n "$MODEL" && -f "$MODEL" ]] || { echo "No GGUF found — pass a path: scripts/llama_server.sh <model.gguf>" >&2; exit 1; }

echo "Serving: $MODEL"
exec llama-server \
  -m "$MODEL" \
  --alias local-reviewer \
  --port 8080 \
  --jinja \
  --ctx-size 49152 \
  --parallel 1 \
  --cache-type-k q8_0 \
  --flash-attn on \
  "$@"
# --jinja: required for Qwen3-Coder's chat template + tool-call parsing.
# --ctx-size: bounded on purpose — huge contexts are what blow up KV memory.
# --parallel 1: codex is a single client; parallel N splits ctx into N slots.
# --cache-type-k q8_0: halves K-cache memory; community-standard for agent work.
