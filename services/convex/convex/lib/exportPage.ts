// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Export page helpers the import needs beyond the checks in `@avana/export` (README, "Scheduled pull", step 4).

import type { ExportPage } from "@avana/services-common/export";

/** Block timestamps of a page in milliseconds, for the `at` of each record. */
export function blockTimes(page: ExportPage): Map<string, number> {
  return new Map(page.blocks.map((b) => [b.number, Number(b.timestamp) * 1000]));
}
