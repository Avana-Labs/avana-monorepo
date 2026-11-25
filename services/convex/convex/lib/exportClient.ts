// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The export client (`@avana/export`) configured from Convex's environment: INDEXER_EXPORT_URL,
// INDEXER_EXPORT_KEY_ID and INDEXER_EXPORT_SECRET (base64, at least 32 bytes).

import { type ExportClient, createExportClient } from "@avana/export";
import { requireEnv } from "@avana/services-common/env";

export function exportClient(): ExportClient {
  return createExportClient({
    baseUrl: requireEnv(process.env, "INDEXER_EXPORT_URL"),
    keyId: requireEnv(process.env, "INDEXER_EXPORT_KEY_ID"),
    secretBase64: requireEnv(process.env, "INDEXER_EXPORT_SECRET"),
  });
}
