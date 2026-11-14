// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Who receives a notice (services/README.md, Monitoring and alerting, Rules): warns reach the on-call engineer and
// the signal's responders; pages also reach the governance Safe's and the Emergency Guardian's signers and the Aave
// Protocol Guardian contact. A resolution goes to whoever received the level it closes. Every recipient must have a
// channel before the service starts, so no alert can be routed to nobody.

import { type Responder, signal } from "./signals.ts";
import type { Notice } from "./types.ts";

export type Recipient = Responder | "onCall" | "governanceSafeSigners" | "emergencyGuardianSigners" | "aaveProtocolGuardian";

export const RECIPIENTS: readonly Recipient[] = [
  "onCall",
  "governanceSafeSigners",
  "emergencyGuardianSigners",
  "aaveProtocolGuardian",
  "operators",
  "emergencyGuardian",
  "guardians",
  "riskProviders",
  "governance",
  "standbyKeeper",
  "keeperOnCall",
  "avanaLabs",
  "aaveDao",
  "aave",
  "coverageRole",
  "engineering",
  "cancellers",
  "signers",
];

const PAGE_ALSO: readonly Recipient[] = ["governanceSafeSigners", "emergencyGuardianSigners", "aaveProtocolGuardian"];

export function recipientsOf(n: Notice): Recipient[] {
  const out: Recipient[] = ["onCall", ...signal(n.alert.signal).responders];
  if (n.alert.level === "page" || n.from === "page") out.push(...PAGE_ALSO);
  return [...new Set(out)];
}

/** Recipient → channel names, as configured. */
export type RoutingTable = Readonly<Record<Recipient, readonly string[]>>;

/** Refuses a table that leaves a recipient without a channel or names a channel that is not defined. */
export function checkRouting(table: Partial<Record<Recipient, readonly string[]>>, channels: ReadonlySet<string>): RoutingTable {
  const missing = RECIPIENTS.filter((r) => (table[r] ?? []).length === 0);
  if (missing.length > 0) throw new Error(`no channel for ${missing.join(", ")}`);
  const unknown = RECIPIENTS.flatMap((r) => table[r]!.filter((c) => !channels.has(c)).map((c) => `${r} -> ${c}`));
  if (unknown.length > 0) throw new Error(`undefined channel in ${unknown.join(", ")}`);
  return table as RoutingTable;
}

/** The distinct channels a notice goes to. */
export function channelsOf(n: Notice, table: RoutingTable): string[] {
  return [...new Set(recipientsOf(n).flatMap((r) => table[r]))];
}
