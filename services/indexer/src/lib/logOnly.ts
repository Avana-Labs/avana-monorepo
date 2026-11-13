// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Registers events that only need the event log row: the export, monitoring and the public history read them
// from `event_log` by kind. Each name must be an event of the contract's ABI; Ponder rejects an unknown name at
// startup, so a renamed event stops the indexer instead of being skipped.

import { ponder } from "ponder:registry";
import { type LogEventLike, recordLog } from "./record.ts";

type EventName = Parameters<typeof ponder.on>[0];

/** `kindOf` names the log kind when the contract is one of several sources of the same Aave contract (aaveSources.ts). */
export function logOnly(contract: string, events: readonly string[], kindOf: string = contract): void {
  for (const name of events) {
    const full = `${contract}:${name}` as EventName;
    ponder.on(full, async ({ event, context }) => {
      await recordLog(event as unknown as LogEventLike, context, `${kindOf}.${name}`);
    });
  }
}

/** Decodes a Solidity enum value into its name; an unknown value stops the indexer (fail closed). */
export function enumName<T extends readonly string[]>(names: T, value: number | bigint): T[number] {
  const name = names[Number(value)];
  if (name === undefined) throw new Error(`enum value ${value} outside ${names.join("|")}`);
  return name;
}

export const PRICE_STATE = ["Live", "Drifting", "Cached", "Expired"] as const;
export const PAUSE_STATE = ["None", "Frozen", "Paused"] as const;
export const PAUSE_REASON = ["None", "General", "MintPathSuspect"] as const;
