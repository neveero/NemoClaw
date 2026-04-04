#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SANDBOX_NAME="${1:-${NEMOCLAW_SANDBOX:-my-assistant}}"
PROMPT="${2:-Daily check-in: summarize status and next actions.}"
SESSION_ID="${SESSION_ID:-scheduler}"
MAX_TELEGRAM_CHARS="${MAX_TELEGRAM_CHARS:-3500}"

announce() {
  local text="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    return 0
  fi
  local payload
  payload="$(
    python3 - <<'PY' "$TELEGRAM_CHAT_ID" "$text"
import json
import sys
print(json.dumps({"chat_id": sys.argv[1], "text": sys.argv[2]}))
PY
  )"
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null || true
}

ssh_cfg="$(mktemp)"
cleanup() {
  rm -f "$ssh_cfg"
}
trap cleanup EXIT

openshell sandbox ssh-config "$SANDBOX_NAME" > "$ssh_cfg"

set +e
output="$(
  ssh -T -F "$ssh_cfg" "openshell-${SANDBOX_NAME}" \
    "nemoclaw-start openclaw agent --agent main --local -m ${PROMPT@Q} --session-id ${SESSION_ID@Q}" 2>&1
)"
status=$?
set -e

if [ $status -eq 0 ]; then
  short="${output:0:${MAX_TELEGRAM_CHARS}}"
  message="$(printf "Scheduler run succeeded (%s)\n\n%s" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$short")"
  announce "$message" || true
  printf "%s\n" "$message"
else
  short="${output:0:${MAX_TELEGRAM_CHARS}}"
  message="$(printf "Scheduler run failed (%s)\n\n%s" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$short")"
  announce "$message" || true
  printf "%s\n" "$message" >&2
  exit $status
fi
