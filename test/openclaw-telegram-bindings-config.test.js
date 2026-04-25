// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { describe, it } from "vitest";

const dockerfile = fs.readFileSync(path.join(import.meta.dirname, "..", "Dockerfile"), "utf8");

describe("OpenClaw Telegram bindings Dockerfile config", () => {
  it("exposes a dedicated build arg for host-managed Telegram bindings", () => {
    assert.match(dockerfile, /^ARG NEMOCLAW_TELEGRAM_BINDINGS_B64=e30=$/m);
    assert.match(dockerfile, /NEMOCLAW_TELEGRAM_BINDINGS_B64=\$\{NEMOCLAW_TELEGRAM_BINDINGS_B64\}/);
  });

  it("reapplies Telegram thread bindings after doctor normalization", () => {
    assert.ok(dockerfile.includes("bindings = json.loads("));
    assert.ok(dockerfile.includes("NEMOCLAW_TELEGRAM_BINDINGS_B64"));
    assert.ok(dockerfile.includes("account['threadBindings'] = thread_bindings"));
    assert.ok(dockerfile.includes("groups[str(chat_id)] = merged_group"));
    assert.ok(dockerfile.includes("topics[str(topic_id)] = merged_topic"));
  });
});
