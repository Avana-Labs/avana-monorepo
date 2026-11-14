// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Delivery channels: PagerDuty (Events API v2), a JSON webhook (Slack and Teams incoming webhooks read its `text`)
// and the log. Each send is retried with backoff; a channel that still fails is recorded in the incident log and
// does not stop delivery to the others.

import { signal } from "../signals.ts";
import type { Notice } from "../types.ts";
import type { Delivery } from "../incidentLog.ts";

export interface Channel {
  readonly name: string;
  /** Resolves once the channel accepted the notice; throws otherwise. */
  send(n: Notice): Promise<void>;
}

export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string }) => Promise<{ ok: boolean; status: number; text(): Promise<string> }>;

export const PAGERDUTY_EVENTS_URL = "https://events.pagerduty.com/v2/enqueue";

/** One line a person reads first: level, signal, subject, chain and block, transition, playbook. */
export function summary(n: Notice): string {
  const a = n.alert;
  const def = signal(a.signal);
  const what = n.transition === "resolve" ? "RESOLVED" : a.level.toUpperCase();
  const details = Object.entries(a.detail).map(([k, v]) => `${k}=${v}`).join(", ");
  const text = `[${what}] ${a.signal} ${def.name}: ${a.subject} on chain ${a.chainId} at block ${a.blockNumber} (${n.transition}). Playbook ${def.playbook}.${details ? ` ${details}` : ""}`;
  return text.length > 1_024 ? `${text.slice(0, 1_021)}...` : text;
}

/** A condition keeps one PagerDuty incident across its level changes; an event gets its own. */
export function dedupKey(n: Notice): string {
  const a = n.alert;
  const base = `avana|${a.chainId}|${a.signal}|${a.subject}`;
  return n.transition === "event" ? `${base}|${a.blockNumber}` : base;
}

async function post(fetchFn: FetchLike, url: string, body: unknown): Promise<void> {
  const r = await fetchFn(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
}

export function pagerDutyChannel(name: string, routingKey: string, fetchFn: FetchLike, url = PAGERDUTY_EVENTS_URL): Channel {
  return {
    name,
    send: (n) => {
      const a = n.alert;
      const def = signal(a.signal);
      if (n.transition === "resolve") return post(fetchFn, url, { routing_key: routingKey, event_action: "resolve", dedup_key: dedupKey(n) });
      return post(fetchFn, url, {
        routing_key: routingKey,
        event_action: "trigger",
        dedup_key: dedupKey(n),
        payload: {
          summary: summary(n),
          source: `avana-monitor chain ${a.chainId}`,
          severity: a.level === "page" ? "critical" : "warning",
          component: a.subject,
          group: a.signal,
          class: n.transition,
          custom_details: { ...a.detail, block: a.blockNumber.toString(10), responders: def.responders.join(", "), playbook: def.playbook, warnLevel: def.warn, pageLevel: def.page },
        },
      });
    },
  };
}

export function webhookChannel(name: string, url: string, fetchFn: FetchLike): Channel {
  return {
    name,
    send: (n) => post(fetchFn, url, { text: summary(n), notice: { ...n, alert: { ...n.alert, blockNumber: n.alert.blockNumber.toString(10) } } }),
  };
}

export function logChannel(name: string, write: (line: string) => void): Channel {
  return {
    name,
    send: async (n) => write(JSON.stringify({ type: "monitor.alert", text: summary(n), transition: n.transition, ...n.alert, blockNumber: n.alert.blockNumber.toString(10) })),
  };
}

export interface RetryPolicy {
  readonly attempts: number;
  readonly backoffMs: number;
  readonly sleep: (ms: number) => Promise<void>;
}

export const DEFAULT_RETRY: RetryPolicy = { attempts: 3, backoffMs: 2_000, sleep: (ms) => new Promise((r) => setTimeout(r, ms)) };

/** Sends to every channel at once, each with its own retries; the answer of each is returned for the incident log. */
export async function deliver(n: Notice, channels: readonly Channel[], retry: RetryPolicy = DEFAULT_RETRY): Promise<Delivery[]> {
  return Promise.all(
    channels.map(async (c): Promise<Delivery> => {
      let last = "";
      for (let i = 0; i < retry.attempts; i++) {
        if (i > 0) await retry.sleep(retry.backoffMs * 2 ** (i - 1));
        try {
          await c.send(n);
          return { channel: c.name, ok: true };
        } catch (err) {
          last = err instanceof Error ? err.message : String(err);
        }
      }
      return { channel: c.name, ok: false, error: last };
    }),
  );
}
