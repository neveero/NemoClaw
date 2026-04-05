#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SANDBOX_NAME="${1:-${NEMOCLAW_SANDBOX:-my-assistant}}"
PROMPT="${2:-In /sandbox/.openclaw/workspace/projects/market-sim, run \`npm run run:scheduled\`. Read the newest generated report in reports/. Return only a concise market briefing with exactly these sections:
What matters now
Why it matters
Current stance
What to watch
Source health
Positions changed
Do not include runtime logs, setup lines, warnings, internal boilerplate, or generic project-status summaries. Keep it concise and readable.}"
SESSION_ID="${SESSION_ID:-scheduler}"
MAX_TELEGRAM_CHARS="${MAX_TELEGRAM_CHARS:-3500}"
TIMESTAMP_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

extract_briefing() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import re
import sys

raw = sys.argv[1]
required = [
    "What matters now",
    "Why it matters",
    "Current stance",
    "What to watch",
    "Source health",
    "Positions changed",
]

def norm(s: str) -> str:
    s = s.strip()
    s = re.sub(r'^[#\-\*\s]+', '', s)
    s = s.rstrip(':').strip()
    return s.lower()

lines = [ln.rstrip() for ln in raw.splitlines()]
sections = {k: [] for k in required}
current = None

for line in lines:
    key = norm(line)
    matched = None
    for wanted in required:
        if key == wanted.lower():
            matched = wanted
            break
    if matched:
        current = matched
        continue
    if current:
        if not line.strip():
            if sections[current] and sections[current][-1] != "":
                sections[current].append("")
            continue
        if line.lstrip().startswith(("[SECURITY]", "Setting up NemoClaw", "(node:", "[gateway]")):
            continue
        sections[current].append(line.strip())

parts = []
for wanted in required:
    content = "\n".join([x for x in sections[wanted]]).strip()
    if not content:
        content = "Not available."
    parts.append(f"{wanted}\n{content}")

print("\n\n".join(parts).strip())
PY
}

announce() {
  local text="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    return 0
  fi
  local payload
  payload="$(
    python3 - "$TELEGRAM_CHAT_ID" "$text" <<'PY'
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

openshell sandbox ssh-config "$SANDBOX_NAME" >"$ssh_cfg"

set +e
output="$(
  ssh -T -F "$ssh_cfg" "openshell-${SANDBOX_NAME}" \
    "nemoclaw-start openclaw agent --agent main --local -m ${PROMPT@Q} --session-id ${SESSION_ID@Q}" 2>&1
)"
status=$?
set -e

if [ $status -eq 0 ]; then
  briefing="$(extract_briefing "$output")"
  if [ -z "$briefing" ] || [ "$(printf "%s" "$briefing" | grep -c "Not available.")" -ge 6 ]; then
    short="${output:0:300}"
    message="$(printf "market-sim scheduler failure\ntime: %s\nerror: unusable briefing output (%s)" "$TIMESTAMP_UTC" "$short")"
    announce "$message" || true
    printf "%s\n" "$message" >&2
    exit 1
  fi
  short="${briefing:0:${MAX_TELEGRAM_CHARS}}"
  message="$(printf "%s" "$short")"
  announce "$message" || true
  printf "%s\n" "$message"
else
  short="${output:0:300}"
  message="$(printf "market-sim scheduler failure\ntime: %s\nerror: %s" "$TIMESTAMP_UTC" "$short")"
  announce "$message" || true
  printf "%s\n" "$message" >&2
  exit $status
fi
