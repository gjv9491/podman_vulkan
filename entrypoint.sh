#!/bin/sh
# Start ollama serve, and optionally colibri serve alongside it.
# COLIBRI_MODEL and COLIBRI_PORT are set by setup.sh when --colibri is used.

ollama serve &
OLLAMA_PID=$!

if [ -n "$COLIBRI_MODEL" ] && [ -d "$COLIBRI_MODEL" ]; then
  echo "[entrypoint] Starting colibri on :${COLIBRI_PORT:-8080} with $COLIBRI_MODEL"
  export COLI_ALLOW_INSECURE_BIND=1
  coli serve \
    --model "$COLIBRI_MODEL" \
    --host 0.0.0.0 \
    --port "${COLIBRI_PORT:-8080}" \
    --allowed-host ollama-sandbox \
    --auto-tier &
  COLI_PID=$!
elif [ -n "$COLIBRI_MODEL" ]; then
  echo "[entrypoint] COLIBRI_MODEL=$COLIBRI_MODEL not found — skipping colibri serve"
fi

wait $OLLAMA_PID
