// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Ponder's virtual modules exist only inside a Ponder build; the handler tests load the handlers against stand-ins
// (test/harness): a registry that records each handler, the indexer's own schema and an inert API module.

import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const harness = (file: string) => fileURLToPath(new URL(`./test/harness/${file}`, import.meta.url));

export default defineConfig({
  resolve: {
    alias: {
      "ponder:registry": harness("registry.ts"),
      "ponder:schema": harness("schema.ts"),
      "ponder:api": harness("api.ts"),
    },
  },
});
