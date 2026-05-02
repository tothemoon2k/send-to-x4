#!/bin/bash
# Prompts for an Anthropic API key (input hidden) and POSTs it to the
# running sendtox4d daemon. The key never appears in shell history.
set -euo pipefail

PORT="${SENDTOX4_PORT:-47821}"
URL="http://127.0.0.1:${PORT}/settings/api-key"

if ! curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
  echo "Daemon isn't running on port ${PORT}." >&2
  echo "Start it first:  swift run sendtox4d" >&2
  exit 1
fi

printf "Anthropic API key (input hidden): "
stty -echo
IFS= read -r KEY
stty echo
printf "\n"

if [[ -z "$KEY" ]]; then
  echo "No key entered, aborting." >&2
  exit 1
fi

# Build JSON via python so weird characters in the key are escaped safely.
BODY=$(KEY="$KEY" python3 -c 'import json,os; print(json.dumps({"key": os.environ["KEY"]}))')

RESPONSE=$(curl -s -X POST "$URL" \
  -H 'Content-Type: application/json' \
  --data-binary "$BODY")

echo "$RESPONSE"
unset KEY BODY
