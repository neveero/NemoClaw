#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SANDBOX_NAME="${NEMOCLAW_SANDBOX:-my-assistant}"
REPO_DIR="${NEMOCLAW_REPO_DIR:-$HOME/NemoClaw}"
NODE_BIN="${NODE_BIN:-}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-}"
OPENSHELL_BIN="${OPENSHELL_BIN:-}"

usage() {
  cat <<'EOF'
Usage: setup-headless-services.sh [--sandbox NAME] [--repo-dir PATH]

Installs systemd --user units for:
  - Telegram bridge
  - Cloudflared named tunnel
  - OpenShell dashboard forward (18789 -> sandbox)
  - OpenClaw scheduler (default every 10 minutes)

Required env vars:
  TELEGRAM_BOT_TOKEN
  and at least one of: OPENAI_API_KEY, NVIDIA_API_KEY

Optional env vars:
  ALLOWED_CHAT_IDS
  TELEGRAM_CHAT_ID
  TELEGRAM_BRIDGE_DEBUG (0|1)
  OPENAI_TRANSCRIPTION_MODEL
  CLOUDFLARED_TUNNEL_NAME (default: nemoclaw)
  SCHEDULER_ON_CALENDAR (default: *:0/10)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox)
      SANDBOX_NAME="${2:?--sandbox requires a value}"
      shift 2
      ;;
    --repo-dir)
      REPO_DIR="${2:?--repo-dir requires a value}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "TELEGRAM_BOT_TOKEN is required" >&2
  exit 1
fi
if [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${NVIDIA_API_KEY:-}" ]; then
  echo "Set OPENAI_API_KEY or NVIDIA_API_KEY before running setup" >&2
  exit 1
fi

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$(command -v cloudflared || true)}"
OPENSHELL_BIN="${OPENSHELL_BIN:-$(command -v openshell || true)}"

if [ -z "$NODE_BIN" ]; then
  echo "node not found on PATH" >&2
  exit 1
fi
if [ -z "$CLOUDFLARED_BIN" ]; then
  echo "cloudflared not found on PATH" >&2
  exit 1
fi
if [ -z "$OPENSHELL_BIN" ]; then
  echo "openshell not found on PATH" >&2
  exit 1
fi

mkdir -p "$HOME/.config/systemd/user" "$HOME/.config/nemoclaw"

ENV_FILE="$HOME/.config/nemoclaw/telegram-bridge.env"
cat >"$ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
NVIDIA_API_KEY=${NVIDIA_API_KEY:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
ALLOWED_CHAT_IDS=${ALLOWED_CHAT_IDS:-}
TELEGRAM_BRIDGE_DEBUG=${TELEGRAM_BRIDGE_DEBUG:-0}
OPENAI_TRANSCRIPTION_MODEL=${OPENAI_TRANSCRIPTION_MODEL:-whisper-1}
SANDBOX_NAME=${SANDBOX_NAME}
EOF
chmod 600 "$ENV_FILE"

NODE_DIR="$(dirname "$NODE_BIN")"
CF_TUNNEL_NAME="${CLOUDFLARED_TUNNEL_NAME:-nemoclaw}"
SCHEDULER_ON_CALENDAR="${SCHEDULER_ON_CALENDAR:-*:0/10}"

cat >"$HOME/.config/systemd/user/telegram-bridge-nemoclaw.service" <<EOF
[Unit]
Description=NemoClaw Telegram Bridge
After=network-online.target

[Service]
WorkingDirectory=${REPO_DIR}
Environment=PATH=${NODE_DIR}:/usr/local/bin:/usr/bin
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${REPO_DIR}/scripts/telegram-bridge.js
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

cat >"$HOME/.config/systemd/user/openshell-forward-18789.service" <<EOF
[Unit]
Description=OpenShell forward 18789 -> ${SANDBOX_NAME}
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/local/bin:/usr/bin
ExecStart=/bin/bash -lc '${OPENSHELL_BIN} forward stop 18789 || true; ${OPENSHELL_BIN} forward start --background 18789 ${SANDBOX_NAME}'
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF

cat >"$HOME/.config/systemd/user/cloudflared-nemoclaw.service" <<EOF
[Unit]
Description=Cloudflared Tunnel (NemoClaw)
After=network-online.target openshell-forward-18789.service
Wants=openshell-forward-18789.service

[Service]
ExecStart=${CLOUDFLARED_BIN} tunnel run ${CF_TUNNEL_NAME}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

cat >"$HOME/.config/systemd/user/openclaw-scheduler.service" <<EOF
[Unit]
Description=Run scheduled OpenClaw task

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${REPO_DIR}/scripts/run-scheduled-agent.sh ${SANDBOX_NAME}
EOF

cat >"$HOME/.config/systemd/user/openclaw-scheduler.timer" <<EOF
[Unit]
Description=OpenClaw scheduler timer

[Timer]
OnCalendar=${SCHEDULER_ON_CALENDAR}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now telegram-bridge-nemoclaw openshell-forward-18789 cloudflared-nemoclaw openclaw-scheduler.timer

echo "Installed and started user services."
echo "Enable linger once so they survive logout/reboot:"
echo "  sudo loginctl enable-linger $USER"
