// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";

const repoRoot = path.join(import.meta.dirname, "..");

describe("exec approvals layout", () => {
  it("keeps exec-approvals.json as a regular file in the base image", () => {
    const dockerfile = fs.readFileSync(path.join(repoRoot, "Dockerfile.base"), "utf8");

    expect(dockerfile).toContain("touch /sandbox/.openclaw/exec-approvals.json");
    expect(dockerfile).not.toContain(
      "ln -s /sandbox/.openclaw-data/exec-approvals.json /sandbox/.openclaw/exec-approvals.json",
    );
  });

  it("rejects symlinked exec approvals at startup", () => {
    const script = fs.readFileSync(path.join(repoRoot, "scripts", "nemoclaw-start.sh"), "utf8");

    expect(script).toContain("exec-approvals.json must be a regular file, not a symlink");
    expect(script).toContain("exec-approvals.json missing from /sandbox/.openclaw");
  });
});
