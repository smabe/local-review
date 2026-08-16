#!/bin/bash
# Serve the local review model via llama-server (stability pick over LM Studio's
# MLX engine, which leaks Metal buffer descriptors under long generations —
# see lmstudio-ai/mlx-engine#264).
#
# Usage: scripts/llama_server.sh [path-to-gguf]
# Default model: first Qwen3-Coder GGUF found under ~/.lmstudio/models or ~/models.
set -euo pipefail

MODEL="${1:-}"
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
  --flash-attn on
# --jinja: required for Qwen3-Coder's chat template + tool-call parsing.
# --ctx-size: bounded on purpose — huge contexts are what blow up KV memory.
# --parallel 1: codex is a single client; parallel N splits ctx into N slots.
# --cache-type-k q8_0: halves K-cache memory; community-standard for agent work.
