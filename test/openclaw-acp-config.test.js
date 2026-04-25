// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { describe, it } from "vitest";

const dockerfile = fs.readFileSync(path.join(import.meta.dirname, "..", "Dockerfile"), "utf8");

describe("OpenClaw ACP Dockerfile config", () => {
  it("bakes ACP runtime dispatch enablement into openclaw.json", () => {
    assert.match(
      dockerfile,
      /'acp': \{\s*'enabled': True,\s*'dispatch': \{'enabled': True\}\s*\}/s,
    );
  });
});
