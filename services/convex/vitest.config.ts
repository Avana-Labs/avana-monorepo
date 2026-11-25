// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Ask AI tests run the Convex agent and rate-limiter components inside convex-test, which takes longer than the
// default 5 s on a loaded machine; the rest of the suite is unaffected by the longer limit.

import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 30_000,
    server: { deps: { inline: ["convex-test"] } },
  },
});
