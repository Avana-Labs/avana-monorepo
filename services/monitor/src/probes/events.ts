// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Signals read from contract events since the last round (at most 2,000 blocks per round; the first round starts at
// the head, so a restart never re-sends old events):
//   M-10  LPVaultSwap RouteFailed per market (1 in the hour warns, 3 page) and the share of a market's collateral
//         seized by LiquidationSettled (10 % in the hour warns, 20 % pages), the on-chain half beside the keeper's;
//   M-20  Aave configuration events of every CDP Spoke (warn) and the RiskModule's ConfigDriftDetected (page);
//   M-21  Collateralization CounterSaturated (page);
//   M-22  Timelock CallScheduled (warn; page for role changes, upgrades, setShortDelaySelector, setNormalDelay,
//         unfreezeAddress and restorePriceRoute), and role grants or revocations on the Timelock (page);
//   M-24  MarketRegistry address freezes, the standby route switch and pause reasons (warn);
//   M-25  a token issuer's blocklist naming LPVaultSwap, an LPVault, Collateralization or the AaveAdapter (page) or
//         another Avana contract (warn).

import { aaveV4SpokeAbi, avanaTimelockAbi, collateralizationAbi, lpVaultSwapAbi, marketRegistryAbi, riskModuleAbi } from "@avana/protocol/abis";
import { type Abi, type Address, type Hex, decodeEventLog, parseAbi, toEventSelector, toFunctionSelector } from "viem";
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

/** Selectors whose scheduling pages M-22. */
export const PAGE_SELECTORS: ReadonlyMap<Hex, string> = new Map(
  [
    "grantRole(bytes32,address)",
    "revokeRole(bytes32,address)",
    "renounceRole(bytes32,address)",
    "upgradeTo(address)",
    "upgradeToAndCall(address,bytes)",
    "setShortDelaySelector(address,bytes4,bool)",
    "setNormalDelay(uint256)",
    "unfreezeAddress(address)",
    "restorePriceRoute(address)",
  ].map((sig) => [toFunctionSelector(sig), sig.slice(0, sig.indexOf("("))]),
);

type Rule = { readonly signal: SignalId; readonly from: "spokes" | "riskModule" | "collateralization" | "timelock" | "registry" | "lpVaultSwap" | "tokens" };

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
  ConfigDriftDetected: { signal: "M-20", from: "riskModule" },
  CounterSaturated: { signal: "M-21", from: "collateralization" },
  CallScheduled: { signal: "M-22", from: "timelock" },
  RoleGranted: { signal: "M-22", from: "timelock" },
  RoleRevoked: { signal: "M-22", from: "timelock" },
  AddressFrozen: { signal: "M-24", from: "registry" },
  AddressUnfrozen: { signal: "M-24", from: "registry" },
  StandbyRouteActivated: { signal: "M-24", from: "registry" },
  StandbySwitchCancelled: { signal: "M-24", from: "registry" },
  PauseReasonChanged: { signal: "M-24", from: "registry" },
  RouteFailed: { signal: "M-10", from: "lpVaultSwap" },
  LiquidationSettled: { signal: "M-10", from: "lpVaultSwap" },
  Blacklisted: { signal: "M-25", from: "tokens" },
  AddedBlackList: { signal: "M-25", from: "tokens" },
};

const ABI = [...aaveV4SpokeAbi, ...riskModuleAbi, ...collateralizationAbi, ...avanaTimelockAbi, ...marketRegistryAbi, ...lpVaultSwapAbi, ...extraAbi] as Abi;

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
  /** LPVaultSwap, the LPVaults, Collateralization, the AaveAdapter: a blocklist naming one pages M-25. */
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
  const routeFailures = new Map<string, number[]>();
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
      add("riskModule", [m.avana.riskModule.address]);
      add("collateralization", [m.avana.collateralization.address]);
      add("timelock", [m.avana.timelock.address]);
      add("registry", [m.avana.marketRegistry.address]);
      add("lpVaultSwap", [m.avana.lpVaultSwap.address]);
      add("tokens", [...ctx.snapshot.markets.flatMap((x) => x.tokens), ...m.debtReserves.map((d) => d.asset)]);
      const logs = from > to ? [] : await ctx.rpc.getLogs([...roles.keys()] as Address[], [...TOPICS.keys()], from, to);
      const critical = new Set([m.avana.lpVaultSwap.address, m.avana.collateralization.address, m.avana.aaveAdapter.address, ...m.avana.lpVaults.map((v) => v.address)].map((a) => a.toLowerCase()));
      const avana = new Set(Object.values(m.avana).flatMap((v) => (Array.isArray(v) ? v.map((x) => (x as { address: string }).address) : typeof v === "object" && v && "address" in v ? [(v as { address: string }).address] : [])).map((a) => a.toLowerCase()));
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
        // An event counts only from the contract the rule reads it from (a token's RoleGranted is not the Timelock's).
        if (!rule || input.roles.get(l.address.toLowerCase()) !== rule.from) continue;
        const a = d.args;
        switch (d.name) {
          case "ConfigDriftDetected":
            event("M-20", "page", l, { event: d.name, spoke: s(a.spoke), reason: s(a.reason) });
            break;
          case "CounterSaturated":
            event("M-21", "page", l, { event: d.name, counterKind: s(a.counterKind), hub: s(a.hub), key: s(a.key), valueBefore: s(a.valueBefore), subtracted: s(a.subtracted) });
            break;
          case "CallScheduled": {
            const data = String(a.data);
            const selector = data.slice(0, 10).toLowerCase() as Hex;
            const named = PAGE_SELECTORS.get(selector);
            event("M-22", named ? "page" : "warn", l, { event: d.name, id: s(a.id), target: s(a.target), selector, ...(named ? { call: named } : {}), delay: s(a.delay) });
            break;
          }
          case "RoleGranted":
          case "RoleRevoked":
            event("M-22", "page", l, { event: d.name, role: s(a.role), account: s(a.account), sender: s(a.sender) });
            break;
          case "RouteFailed": {
            const market = s(a.marketId);
            routeFailures.set(market, [...(routeFailures.get(market) ?? []), input.timestamp]);
            touched.add(market);
            break;
          }
          case "LiquidationSettled": {
            const market = s(a.marketId);
            const result = Object.values(a).find((v) => typeof v === "object" && v !== null && "unitsSeized" in v) as { unitsSeized: bigint } | undefined;
            if (result) seized.set(market, [...(seized.get(market) ?? []), { t: input.timestamp, units: result.unitsSeized }]);
            touched.add(market);
            break;
          }
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
      for (const [market, ts] of routeFailures) {
        const recent = ts.filter((t) => t > since);
        if (recent.length === 0) routeFailures.delete(market);
        const level: Level = recent.length >= 3 ? "page" : recent.length >= 1 ? "warn" : "ok";
        out.push({ signal: "M-10", kind: "condition", level, subject: `market:${market}:routeFailed`, detail: { routeFailedInHour: String(recent.length) } });
      }
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

    evidence(input, subject) {
      if (subject.startsWith("log:")) {
        const l = input.logs.find((x) => logSubject(x) === subject);
        return l ? text(l) : null;
      }
      const market = subject.split(":")[1];
      const logs = input.logs.filter((l) => {
        const d = decode(l);
        return d !== null && (d.name === "RouteFailed" || d.name === "LiquidationSettled") && s(d.args.marketId) === market;
      });
      return text({ range: [input.from, input.to], logs, supplied: input.supplied.get(market ?? "") ?? null });
    },
  };
}

/** For the ABI check: every event the probe reads, and how many of them the ABIs give a topic for. */
export const EVENT_NAMES: readonly string[] = Object.keys(EVENTS);
export const TOPIC_COUNT = new Set(TOPICS.values()).size;
