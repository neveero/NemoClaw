// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { describe, it } from "vitest";

const dockerfile = fs.readFileSync(path.join(import.meta.dirname, "..", "Dockerfile"), "utf8");

describe("OpenClaw TTS Dockerfile config", () => {
  it("lets OpenClaw resolve OPENAI_API_KEY from the runtime environment", () => {
    const ttsLines = dockerfile.split("\n").filter((line) => line.includes("gpt-4o-mini-tts"));

    assert.equal(ttsLines.length, 2);
    assert.ok(
      dockerfile.includes("'apiKey': '${OPENAI_API_KEY}'")
        || dockerfile.includes("'apiKey': '\\${OPENAI_API_KEY}'"),
    );
    assert.ok(!dockerfile.includes("openshell:resolve:env:OPENAI_API_KEY"));
  });
});
