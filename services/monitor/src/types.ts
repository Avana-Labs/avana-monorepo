// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// What a rule reports and what the router sends. `Alert` has the shape of the keeper's alert log line
// (services/keeper/src/monitoring/alerts.ts), so the keeper's alerts are ingested and routed unchanged.

import type { Level, SignalId } from "./signals.ts";

/**
 * One rule's verdict on one subject at one block. A `condition` holds until a later evaluation reports it `ok` (the
 * router then sends a resolve notice); an `event` (a pause change, a rate-curve change) is reported once and never
 * resolves.
 */
export interface Finding {
  readonly signal: SignalId;
  /** `unread`: the subject's inputs could not be read this round; its open alert is neither resolved nor re-sent. */
  readonly kind: "condition" | "event" | "unread";
  readonly level: Level;
  /** The scope the alert is about, stable across blocks: `market:7`, `hubAsset:0xhub:3`, `slice:0xhub:3:0xspoke`. */
  readonly subject: string;
  readonly detail: Readonly<Record<string, string>>;
}

export interface Alert {
  readonly signal: SignalId;
  readonly level: Exclude<Level, "ok">;
  readonly chainId: number;
  readonly blockNumber: bigint;
  readonly subject: string;
  readonly detail: Readonly<Record<string, string>>;
}

/** An alert as the router sends it: a new alert, a level change of an open one, or its resolution. */
export interface Notice {
  readonly alert: Alert;
  readonly transition: "open" | "escalate" | "deescalate" | "resolve" | "event";
  /** The level before an escalation or de-escalation, so whoever received a page also learns it eased. */
  readonly from?: Alert["level"];
  /** Unix seconds of the block the alert was read at. */
  readonly timestamp: number;
}
