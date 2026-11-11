// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Alerts as structured log lines. The log shipper forwards them off the host and the monitoring service routes
// them to the responders of services/README.md, so the keeper holds no paging credentials.

import type { Alert, AlertSink } from "../monitoring/alerts.ts";

export const logAlertSink: AlertSink = {
  async send(alert: Alert) {
    process.stdout.write(`${JSON.stringify({ type: "keeper.alert", ...alert, blockNumber: alert.blockNumber.toString(10) })}\n`);
  },
};
