// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The incident log (EMG-075): every notice with the block it was read at, its recipients and what each channel
// answered, one JSON line per notice, appended and flushed before the next notice is handled.

import { appendFileSync } from "node:fs";
import type { Notice } from "./types.ts";

export interface Delivery {
  readonly channel: string;
  readonly ok: boolean;
  readonly error?: string;
}

export interface IncidentEntry {
  readonly type: "monitor.notice";
  readonly transition: Notice["transition"];
  readonly signal: string;
  readonly level: string;
  readonly chainId: number;
  readonly blockNumber: string;
  readonly timestamp: number;
  readonly subject: string;
  readonly detail: Readonly<Record<string, string>>;
  readonly recipients: readonly string[];
  readonly deliveries: readonly Delivery[];
}

export function incidentEntry(n: Notice, recipients: readonly string[], deliveries: readonly Delivery[]): IncidentEntry {
  const a = n.alert;
  return {
    type: "monitor.notice",
    transition: n.transition,
    signal: a.signal,
    level: a.level,
    chainId: a.chainId,
    blockNumber: a.blockNumber.toString(10),
    timestamp: n.timestamp,
    subject: a.subject,
    detail: a.detail,
    recipients,
    deliveries,
  };
}

export interface IncidentLog {
  write(entry: IncidentEntry): void;
}

/** Appends to a file, synchronously, so a crash never loses a notice that was already sent. */
export function fileIncidentLog(path: string): IncidentLog {
  return { write: (entry) => appendFileSync(path, `${JSON.stringify(entry)}\n`, "utf8") };
}
