// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Signals read from contract events since the last round (at most 2,000 blocks per round; the first round starts at
// the head, so a restart never re-sends old events):
//   M-10  the share of a market's collateral seized by LiquidationModule.Liquidated (10 % in the hour warns, 20 %
//         pages), the on-chain half beside the LiquidationBot's own reports;
//   M-20  Aave configuration events of every CDP Spoke (warn);
//   M-22  the Avana AccessManager: an operation scheduled warns; a role granted or revoked, a function's role changed
//         or a target closed pages;
//   M-25  a token issuer's blocklist naming an LPVault, an AaveAdapter, a LiquidationModule or a FlashloanRepay
//         (page) or another Avana contract (warn).

import { aaveV4SpokeAbi, accessManagerAbi, liquidationModuleAbi } from "@avana/protocol/abis";
import { type Abi, type Address, type Hex, decodeEventLog, parseAbi, toEventSelector } from "viem";
import { type Probe, type RawLog, text } from "../probe.ts";
import type { Level, SignalId } from "../signals.ts";
import type { Finding } from "../types.ts";

const extraAbi = parseAbi([
  "event Upgraded(address indexed implementation)",
  "event Blacklisted(address indexed _account)",
  "event AddedBlackList(address _user)",
]);

const MAX_RANGE = 2_000n;
const HOUR = 3_600;

type Rule = { readonly signal: SignalId; readonly from: "spokes" | "accessManager" | "liquidationModules" | "tokens" };

/** Event name → the signal it feeds and the contracts it is read from. */
const EVENTS: Readonly<Record<string, Rule>> = {
  UpdateReserveConfig: { signal: "M-20", from: "spokes" },
  UpdateDynamicReserveConfig: { signal: "M-20", from: "spokes" },
  AddDynamicReserveConfig: { signal: "M-20", from: "spokes" },
  UpdateLiquidationConfig: { signal: "M-20", from: "spokes" },
  UpdateReservePriceSource: { signal: "M-20", from: "spokes" },
  UpdatePositionManager: { signal: "M-20", from: "spokes" },
  AuthorityUpdated: { signal: "M-20", from: "spokes" },
  Upgraded: { signal: "M-20", from: "spokes" },
  OperationScheduled: { signal: "M-22", from: "accessManager" },
  RoleGranted: { signal: "M-22", from: "accessManager" },
  RoleRevoked: { signal: "M-22", from: "accessManager" },
  TargetFunctionRoleUpdated: { signal: "M-22", from: "accessManager" },
  TargetClosed: { signal: "M-22", from: "accessManager" },
  Liquidated: { signal: "M-10", from: "liquidationModules" },
  Blacklisted: { signal: "M-25", from: "tokens" },
  AddedBlackList: { signal: "M-25", from: "tokens" },
};

const ABI = [...aaveV4SpokeAbi, ...accessManagerAbi, ...liquidationModuleAbi, ...extraAbi] as Abi;

/** topic0 → event name, for the events above (first definition wins; the same signature has the same topic). */
const TOPICS: ReadonlyMap<Hex, string> = new Map(
  ABI.filter((e): e is Extract<Abi[number], { type: "event" }> => e.type === "event" && e.name in EVENTS)
    .map((e) => [toEventSelector(e), e.name] as const)
    .filter(([t], i, all) => all.findIndex(([u]) => u === t) === i),
);

export interface EventsInput {
  readonly from: bigint;
  readonly to: bigint;
  readonly timestamp: number;
  readonly logs: readonly RawLog[];
  /** The contracts each log comes from, by role. */
  readonly roles: ReadonlyMap<string, Rule["from"]>;
  /** Each integration's LPVault, AaveAdapter, LiquidationModule and FlashloanRepay: a blocklist naming one pages M-25. */
  readonly critical: ReadonlySet<string>;
  readonly avana: ReadonlySet<string>;
  /** Supplied units per market at the block, for the seized share. */
  readonly supplied: ReadonlyMap<string, bigint>;
}

const logSubject = (l: RawLog) => `log:${l.transactionHash}:${l.logIndex}`;
const s = (v: unknown) => (typeof v === "bigint" ? v.toString(10) : String(v));

interface Decoded {
  readonly name: string;
  readonly args: Record<string, unknown>;
}

function decode(l: RawLog): Decoded | null {
  try {
    const d = decodeEventLog({ abi: ABI, data: l.data, topics: l.topics as [Hex, ...Hex[]] });
    return d.eventName === undefined ? null : { name: String(d.eventName), args: (d.args ?? {}) as Record<string, unknown> };
  } catch {
    return null;
  }
}

export function eventsProbe(): Probe<EventsInput> {
  let next: bigint | null = null;
  let range: { head: bigint; from: bigint } | null = null;
  const seized = new Map<string, { t: number; units: bigint }[]>();

  return {
    name: "events",

    async read(ctx) {
      const head = ctx.block.number;
      // The confirming read on the second provider comes after `evaluate` moved `next` on: it must read the same range.
      const from = range?.head === head ? range.from : (next ?? head);
      range = { head, from };
      const to = from + MAX_RANGE - 1n < head ? from + MAX_RANGE - 1n : head;
      const m = ctx.manifest;
      const roles = new Map<string, Rule["from"]>();
      const add = (role: Rule["from"], xs: readonly string[]) => xs.forEach((a) => roles.set(a.toLowerCase(), role));
      add("spokes", [...m.aave.borrowSpokes.map((x) => x.address), ...ctx.snapshot.hubs.flatMap((h) => h.cdpSpokes)]);
      add("accessManager", [m.avana.accessManager.address]);
      add("liquidationModules", m.avana.integrations.map((x) => x.liquidationModule.address));
      add("tokens", [...ctx.snapshot.markets.flatMap((x) => x.tokens), ...m.debtReserves.map((d) => d.asset)]);
      const logs = from > to ? [] : await ctx.rpc.getLogs([...roles.keys()] as Address[], [...TOPICS.keys()], from, to);
      const core = m.avana.integrations.flatMap((x) => [x.lpVault, x.aaveAdapter, x.liquidationModule, x.flashloanRepay].map((c) => c.address.toLowerCase()));
      const critical = new Set(core);
      const avana = new Set([...core, m.avana.accessManager.address.toLowerCase(), ...m.avana.integrations.map((x) => x.riskModule.address.toLowerCase()), ...m.avana.flashLiquidators.map((f) => f.address.toLowerCase()), ...m.markets.map((x) => x.vaultToken.address.toLowerCase())]);
      const supplied = new Map(ctx.snapshot.markets.map((x) => [x.marketId, BigInt(x.suppliedUnits)]));
      return { from, to, timestamp: ctx.block.timestamp, logs, roles, critical, avana, supplied };
    },

    evaluate(input) {
      next = input.to + 1n;
      const out: Finding[] = [];
      const event = (signal: SignalId, level: Level, l: RawLog, detail: Record<string, string>) =>
        out.push({ signal, kind: "event", level, subject: logSubject(l), detail: { ...detail, contract: l.address, tx: l.transactionHash, block: l.blockNumber.toString(10) } });
      const touched = new Set<string>();

      for (const l of input.logs) {
        const d = decode(l);
        if (!d) continue;
        const rule = EVENTS[d.name];
        // An event counts only from the contract the rule reads it from (a token's RoleGranted is not the AccessManager's).
        if (!rule || input.roles.get(l.address.toLowerCase()) !== rule.from) continue;
        const a = d.args;
        switch (d.name) {
          case "Liquidated": {
            const market = s(a.marketId);
            seized.set(market, [...(seized.get(market) ?? []), { t: input.timestamp, units: a.seized as bigint }]);
            touched.add(market);
            break;
          }
          case "OperationScheduled":
            event("M-22", "warn", l, { event: d.name, operationId: s(a.operationId), schedule: s(a.schedule), target: s(a.target), data: s(a.data) });
            break;
          case "RoleGranted":
          case "RoleRevoked":
          case "TargetFunctionRoleUpdated":
          case "TargetClosed":
            event("M-22", "page", l, { event: d.name, ...Object.fromEntries(Object.entries(a).map(([k, v]) => [k, typeof v === "object" ? text(v) : s(v)])) });
            break;
          case "Blacklisted":
          case "AddedBlackList": {
            const account = s(a._account ?? a._user).toLowerCase();
            if (input.critical.has(account)) event("M-25", "page", l, { event: d.name, token: l.address, account });
            else if (input.avana.has(account)) event("M-25", "warn", l, { event: d.name, token: l.address, account });
            break;
          }
          default:
            event(rule.signal, "warn", l, { event: d.name, ...Object.fromEntries(Object.entries(a).map(([k, v]) => [k, typeof v === "object" ? text(v) : s(v)])) });
        }
      }

      // M-10 counts over the hour, as conditions per market, for every market with activity in the hour.
      const since = input.timestamp - HOUR;
      for (const [market, xs] of seized) {
        const recent = xs.filter((x) => x.t > since);
        if (recent.length === 0) seized.delete(market);
        const units = recent.reduce((sum, x) => sum + x.units, 0n);
        // The share of what the market held over the hour: what is left now plus what was seized.
        const base = (input.supplied.get(market) ?? 0n) + units;
        const bps = base === 0n ? 0n : (units * 10_000n) / base;
        const level: Level = bps >= 2_000n ? "page" : bps >= 1_000n ? "warn" : "ok";
        out.push({ signal: "M-10", kind: "condition", level, subject: `market:${market}:seized`, detail: { seizedUnitsInHour: units.toString(10), seizedBps: bps.toString(10) } });
      }
      return out;
    },

    // The next block to read, so a restart catches up on what happened while the monitor was down, and the hour's
    // seizures.
    save: () => ({ next, seized: new Map(seized) }),
    restore(s) {
      const saved = s as { next: bigint | null; seized?: Map<string, { t: number; units: bigint }[]> };
      next = saved.next;
      for (const [k, v] of saved.seized ?? []) seized.set(k, [...v]);
    },

    evidence(input, subject) {
      if (subject.startsWith("log:")) {
        const l = input.logs.find((x) => logSubject(x) === subject);
        return l ? text(l) : null;
      }
      const market = subject.split(":")[1];
      const logs = input.logs.filter((l) => {
        const d = decode(l);
        return d !== null && d.name === "Liquidated" && s(d.args.marketId) === market;
      });
      return text({ range: [input.from, input.to], logs, supplied: input.supplied.get(market ?? "") ?? null });
    },
  };
}

/** For the ABI check: every event the probe reads, and how many of them the ABIs give a topic for. */
export const EVENT_NAMES: readonly string[] = Object.keys(EVENTS);
export const TOPIC_COUNT = new Set(TOPICS.values()).size;
