#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

PRIVATE_HELPERS_DIR="${NEMOCLAW_PRIVATE_HELPERS_DIR:-}"
if [ -z "$PRIVATE_HELPERS_DIR" ]; then
  echo "NEMOCLAW_PRIVATE_HELPERS_DIR is required." >&2
  echo "Set it to your private helpers repo bin path (example: \$HOME/nemoclaw-private-ops/bin)." >&2
  exit 1
fi

TARGET="${PRIVATE_HELPERS_DIR}/run-scheduled-agent.sh"

if [ ! -x "$TARGET" ]; then
  echo "Missing private helper: $TARGET" >&2
  echo "Set NEMOCLAW_PRIVATE_HELPERS_DIR to your private helpers repo/bin path." >&2
  exit 1
fi

exec "$TARGET" "$@"
