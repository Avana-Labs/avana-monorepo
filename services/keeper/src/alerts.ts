// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The alert lines the bot runner posts to the monitoring service (services/monitor, `/v1/keeper/alerts`): signals the
// monitor's catalog takes from the keeper feed (M-09, M-10, M-16).

export type Level = "ok" | "warn" | "page";

export interface Alert {
  readonly signal: `M-${string}`;
  readonly level: Exclude<Level, "ok">;
  readonly chainId: number;
  readonly blockNumber: bigint;
  readonly subject: string;
  readonly detail: Readonly<Record<string, string>>;
}

export interface AlertSink {
  send(alert: Alert): Promise<void>;
}
