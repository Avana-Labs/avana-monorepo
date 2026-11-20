// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { defineConfig } from "vitest/config";

export default defineConfig({ test: { include: ["bot/test/**/*.test.ts"] } });
