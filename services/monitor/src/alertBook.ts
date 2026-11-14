// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Turns findings into notices: a condition is sent when it opens and each time its level changes, and resolved when
// a later evaluation of the same source reports it ok or no longer reports its subject (a delisted market); an event
// is sent every time. Nothing is sent again while a condition stays at the same level, so a page that stays true is
// one page, not one per block.

import type { Alert, Finding, Notice } from "./types.ts";

interface Open {
  readonly alert: Alert;
  readonly source: string;
}

export interface Evaluation {
  /** The probe or feed the findings come from (`keeper`, `snapshot`, `oracle`, ...). */
  readonly source: string;
  readonly chainId: number;
  readonly blockNumber: bigint;
  readonly timestamp: number;
  readonly findings: readonly Finding[];
  /**
   * True when `findings` cover every subject of the source on this chain (a full snapshot); open alerts of the source
   * whose subject is missing are then resolved. False for partial inputs such as one keeper alert.
   */
  readonly complete: boolean;
}

const keyOf = (chainId: number, a: Pick<Finding, "signal" | "subject">) => `${chainId}|${a.signal}|${a.subject}`;

export class AlertBook {
  readonly #open = new Map<string, Open>();

  /** The notices of one evaluation, in the order of its findings, then the resolutions of missing subjects. */
  apply(e: Evaluation): Notice[] {
    const out: Notice[] = [];
    const seen = new Set<string>();
    const notice = (alert: Alert, transition: Notice["transition"], from?: Alert["level"]) => out.push({ alert, transition, timestamp: e.timestamp, ...(from ? { from } : {}) });

    for (const f of e.findings) {
      const key = keyOf(e.chainId, f);
      seen.add(key);
      if (f.kind === "event") {
        if (f.level !== "ok") notice(this.#alert(e, f, f.level), "event");
        continue;
      }
      const open = this.#open.get(key);
      if (f.level === "ok") {
        if (open) {
          this.#open.delete(key);
          notice({ ...open.alert, blockNumber: e.blockNumber, detail: f.detail }, "resolve");
        }
        continue;
      }
      const alert = this.#alert(e, f, f.level);
      if (!open) notice(alert, "open");
      else if (open.alert.level !== f.level) notice(alert, f.level === "page" ? "escalate" : "deescalate", open.alert.level);
      else continue;
      this.#open.set(key, { alert, source: e.source });
    }

    if (e.complete) {
      for (const [key, open] of this.#open) {
        if (open.source !== e.source || open.alert.chainId !== e.chainId || seen.has(key)) continue;
        this.#open.delete(key);
        notice({ ...open.alert, blockNumber: e.blockNumber, detail: { ...open.alert.detail, note: "subject no longer read" } }, "resolve");
      }
    }
    return out;
  }

  /** Open alerts, for the status endpoint. */
  open(): Alert[] {
    return [...this.#open.values()].map((o) => o.alert);
  }

  #alert(e: Evaluation, f: Finding, level: Alert["level"]): Alert {
    return { signal: f.signal, level, chainId: e.chainId, blockNumber: e.blockNumber, subject: f.subject, detail: f.detail };
  }
}
