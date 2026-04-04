#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SANDBOX_NAME="${1:-${NEMOCLAW_SANDBOX:-my-assistant}}"

echo "[restart] telegram bridge"
systemctl --user restart telegram-bridge-nemoclaw

echo "[restart] openshell forward"
openshell forward stop 18789 || true
openshell forward start --background 18789 "$SANDBOX_NAME"
systemctl --user restart openshell-forward-18789 || true

echo "[restart] cloudflared tunnel"
systemctl --user restart cloudflared-nemoclaw

echo "[status]"
systemctl --user status telegram-bridge-nemoclaw cloudflared-nemoclaw --no-pager
curl -I http://127.0.0.1:18789/
