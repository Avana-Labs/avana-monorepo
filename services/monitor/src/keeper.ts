// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The keeper's side of monitoring (services/README.md, Keeper > Monitoring and alerting). Each keeper instance posts
// its alert lines (M-09, M-10, M-16, M-17, M-26; pages already confirmed on its second provider) and a heartbeat with
// the block it has processed. A keeper re-sends an alert every block while it holds, so an alert is a condition that
// stays open while it keeps arriving and resolves once `graceBlocks` pass without it. An instance whose heartbeat
// falls 3 blocks behind the head pages its on-call engineer (reported as M-09: accounts below HF 1 are then not
// being watched by that instance).

import { type SignalId, signal } from "./signals.ts";
import type { Finding } from "./types.ts";

export interface KeeperInstance {
  readonly name: string;
  readonly chainId: number;
}

/** One alert line as the keeper writes it (`type: "keeper.alert"`, blockNumber as a decimal string). */
export interface KeeperAlertLine {
  readonly signal: string;
  readonly level: string;
  readonly chainId: number;
  readonly blockNumber: string;
  readonly subject: string;
  readonly detail?: Readonly<Record<string, string>>;
}

interface Held {
  readonly signal: SignalId;
  level: "warn" | "page";
  lastBlock: bigint;
  detail: Readonly<Record<string, string>>;
  instance: string;
}

export const SILENT_BLOCKS = 3n;

/** Checks one posted line; returns why it is refused, or null. */
export function refusal(instance: KeeperInstance, line: KeeperAlertLine): string | null {
  if (!/^M-\d\d$/.test(line.signal)) return `unknown signal ${line.signal}`;
  try {
    signal(line.signal as SignalId);
  } catch {
    return `unknown signal ${line.signal}`;
  }
  if (line.level !== "warn" && line.level !== "page") return `level ${line.level} is not warn or page`;
  if (line.chainId !== instance.chainId) return `instance ${instance.name} reports chain ${instance.chainId}, not ${line.chainId}`;
  if (!/^\d{1,20}$/.test(line.blockNumber)) return `block ${line.blockNumber} is not a decimal integer`;
  if (typeof line.subject !== "string" || line.subject.length === 0 || line.subject.length > 200) return "subject missing or too long";
  for (const [k, v] of Object.entries(line.detail ?? {})) if (typeof v !== "string" || k.length > 64 || v.length > 1_000) return `detail ${k} is not a short string`;
  return null;
}

export class KeeperFeed {
  readonly #held = new Map<string, Held>();
  readonly #heartbeat = new Map<string, bigint>();
  readonly #firstHead = new Map<number, bigint>();

  constructor(readonly instances: readonly KeeperInstance[], readonly graceBlocks = 2n) {}

  /** Records a checked alert line; two instances reporting the same subject are one alert. */
  alert(instance: KeeperInstance, line: KeeperAlertLine): void {
    const block = BigInt(line.blockNumber);
    const key = `${line.chainId}|${line.signal}|keeper:${line.subject}`;
    const held = this.#held.get(key);
    if (held && block < held.lastBlock) return;
    const level = line.level as Held["level"];
    // Within one block the worse level of the instances wins.
    if (held && block === held.lastBlock && held.level === "page" && level === "warn") return;
    this.#held.set(key, { signal: line.signal as SignalId, level, lastBlock: block, detail: line.detail ?? {}, instance: instance.name });
    this.heartbeat(instance, block);
  }

  /** Records the block an instance has processed; never moves backwards. */
  heartbeat(instance: KeeperInstance, block: bigint): void {
    const last = this.#heartbeat.get(instance.name);
    if (last === undefined || block > last) this.#heartbeat.set(instance.name, block);
  }

  /**
   * The keeper findings of one chain at `head`: each held alert while it is fresh, then `ok` once it is older than the
   * grace (it is forgotten after that), and each instance's silence check. A complete evaluation of the source.
   */
  findings(chainId: number, head: bigint): Finding[] {
    const out: Finding[] = [];
    for (const [key, h] of this.#held) {
      if (!key.startsWith(`${chainId}|`)) continue;
      const subject = key.slice(key.indexOf("|keeper:") + 1);
      const fresh = head - h.lastBlock <= this.graceBlocks;
      out.push({ signal: h.signal, kind: "condition", level: fresh ? h.level : "ok", subject, detail: { ...h.detail, instance: h.instance, lastReportedBlock: h.lastBlock.toString(10) } });
      if (!fresh) this.#held.delete(key);
    }
    if (!this.#firstHead.has(chainId)) this.#firstHead.set(chainId, head);
    const watched = head - this.#firstHead.get(chainId)!;
    for (const inst of this.instances) {
      if (inst.chainId !== chainId) continue;
      const last = this.#heartbeat.get(inst.name);
      // An instance never heard from counts from the monitor's own start, so a restart of the monitor pages nobody.
      const silent = (last === undefined ? watched : head - last) >= SILENT_BLOCKS;
      out.push({ signal: "M-09", kind: "condition", level: silent ? "page" : "ok", subject: `keeperInstance:${inst.name}`, detail: { instance: inst.name, lastBlock: last === undefined ? "never" : last.toString(10), head: head.toString(10), note: "keeper instance silent" } });
    }
    return out;
  }
}
