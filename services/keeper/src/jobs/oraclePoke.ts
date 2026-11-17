// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Oracle pokes (3.6 REQ-ORACLE-037): `poke()` on every LPOracle and DebtOracle on each new round of any of its feeds,
// and at least once per CHECKPOINT_INTERVAL (3,600 s) or per heartbeat of its fastest leg, whichever is shorter, so
// cached prices, first disagreement observations, the hourly checkpoint and the grace latch are stored (Q-199, Q-248,
// EMG-035). A poke is sent POKE_LEAD_SECONDS before the interval ends, so the transaction lands inside it: these
// pokes are `scheduled` (keeper DESIGN.md, Fees).
// While an oracle is not Live, it is checked every block and poked only when the poke would change what it stores (a
// timer, latch, grace window, state or route): check every block, send on change. Such a poke is `urgent`.
// `poke()` is permissionless and pays nothing.

import { type Address, type Hex, encodeEventTopics, zeroAddress } from "viem";
import { debtOracleAbi, lpOracleAbi } from "@avana/protocol/abis";
import { type OracleKind, POKE_DATA } from "../chain/reads.ts";
import type { BlockContext, Job, JobClass } from "../types.ts";

export interface OracleTarget {
  readonly oracle: Address;
  readonly implementation: Address;
  readonly kind: OracleKind;
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

/** An oracle to poke in this block, with the class of the poke and the price state read at the block. */
export interface OracleDecision {
  readonly target: OracleTarget;
  readonly jobClass: JobClass;
  readonly state: number;
}

/** Last poke, last round and last state seen per oracle; kept in memory, rebuilt from reads after a restart. */
export class PokeBook {
  readonly lastPokeAt = new Map<Address, bigint>();
  readonly lastRound = new Map<Address, bigint>();
  /** The price state the oracle stores as of this instance's last poke of it, or as last read with nothing to write. */
  readonly lastState = new Map<Address, number>();
}

/** `PriceState.Live`; every other state (Drifting, Cached, Expired) is "not Live" for REQ-ORACLE-037. */
export const LIVE = 0;

/** The oracles' CHECKPOINT_INTERVAL: the longest gap REQ-ORACLE-037 allows between two pokes of one oracle. */
export const CHECKPOINT_INTERVAL_SECONDS = 3_600;

/** How long before the interval ends a poke is sent, so it is mined inside it (5 Ethereum, 30 Base blocks). */
export const POKE_LEAD_SECONDS = 60;

/**
 * Events a poke emits only when it changes what the oracle stores: a failure or disagreement timer set or cleared, the
 * Expired latch, a grace window, the decimals latch, the stored state, a route used or a route version observed.
 * `PriceAccepted`, `PriceCheckpointed` and `QuoteChangeCapped` are left out: the first two are the scheduled pokes'
 * work, and the last is emitted by every poke while the quote stays capped.
 */
const CHANGE_EVENTS = {
  lp: ["FailureRecorded", "FailureCleared", "DisagreementRecorded", "DisagreementCleared", "GraceStarted", "OutageExpiredLatched", "PriceStateChanged", "RouteChanged", "PriceRouteVersionObserved", "TokenDecimalsMismatch", "TokenDecimalsRestored"],
  debt: ["DebtFailureRecorded", "DebtFailureCleared", "DebtDisagreementRecorded", "DebtDisagreementCleared", "DebtGraceStarted", "DebtOutageExpiredLatched", "DebtPriceStateChanged", "DebtRouteChanged", "DebtRouteVersionObserved"],
} as const;

const topic0 = (abi: readonly unknown[], eventName: string): string =>
  (encodeEventTopics({ abi: abi as typeof lpOracleAbi, eventName: eventName as "FailureRecorded" })[0] as Hex).toLowerCase();

/** First topics of the state-change events, per oracle kind. */
export const CHANGE_TOPICS: Readonly<Record<OracleKind, ReadonlySet<string>>> = {
  lp: new Set(CHANGE_EVENTS.lp.map((e) => topic0(lpOracleAbi, e))),
  debt: new Set(CHANGE_EVENTS.debt.map((e) => topic0(debtOracleAbi, e))),
};

/** True when the simulated poke's logs include a state-change event of the oracle itself. */
export function logsChangeState(kind: OracleKind, oracle: Address, logs: readonly { readonly address: Address; readonly topics: readonly Hex[] }[]): boolean {
  return logs.some((l) => l.address.toLowerCase() === oracle.toLowerCase() && CHANGE_TOPICS[kind].has((l.topics[0] ?? "0x").toLowerCase()));
}

/**
 * The fallback without `eth_simulateV1`: the poke changes what the oracle stores when the state it would store differs
 * from the one stored at this instance's last poke (`lastState`; unknown after a restart counts as different, so a
 * restart costs at most one more poke per episode), or when the oracle's report read right after the simulated poke, in
 * the same call, differs from the report right before it (a timer, the grace window or a route written).
 */
export function viewsChangeState(state: number, lastState: number | undefined, effect: { readonly before: Hex | null; readonly after: Hex | null; readonly pokeOk: boolean }): boolean {
  if (state !== lastState) return true;
  return effect.pokeOk && effect.before !== null && effect.after !== null && effect.before.toLowerCase() !== effect.after.toLowerCase();
}

/**
 * Whether a poke of a not-Live oracle (or one whose last stored state was not Live) would change what it stores at
 * this block: from the logs of an `eth_simulateV1` of the poke, or, where the provider lacks it, `viewsChangeState`.
 */
export async function pokeWouldChange(ctx: BlockContext, t: OracleTarget, state: number, lastState: number | undefined, from: Address): Promise<boolean> {
  const logs = await ctx.reader.simulateLogs(t.oracle, from);
  if (logs !== null) return logsChangeState(t.kind, t.oracle, logs);
  if (state !== lastState) return true;
  return viewsChangeState(state, lastState, await ctx.reader.pokeEffect(t.oracle));
}

/**
 * The longest gap allowed between two pokes of one oracle: CHECKPOINT_INTERVAL, or the heartbeat of its fastest leg
 * when that is shorter. A heartbeat that is not a positive finite number never lengthens the interval.
 */
export function pokeIntervalSeconds(heartbeats: readonly number[]): number {
  const valid = heartbeats.filter((h) => Number.isFinite(h) && h > 0);
  return Math.min(CHECKPOINT_INTERVAL_SECONDS, ...valid);
}

/**
 * Due on the first sight, when any feed has a new round since the last poke, or when the interval less the lead has
 * passed. `leadSeconds` defaults to POKE_LEAD_SECONDS; a keeper that checks Live oracles only every N seconds passes
 * POKE_LEAD_SECONDS + N, so a poke found due at the latest check still lands inside the interval.
 */
export function pokeDue(now: bigint, lastPoke: bigint | undefined, intervalSeconds: number, newRound: boolean, leadSeconds = POKE_LEAD_SECONDS): boolean {
  if (lastPoke === undefined || newRound) return true;
  const wait = Math.max(0, Math.floor(intervalSeconds) - leadSeconds);
  return now - lastPoke >= BigInt(wait);
}

/**
 * True while the oracle is not Live, or was not Live at its last read: such an oracle is checked every block (send on
 * change). Live oracles may be checked at a slower cadence (runtime/chainLoop.ts).
 */
export function watchedEveryBlock(book: PokeBook, oracle: Address): boolean {
  const last = book.lastState.get(oracle);
  return last !== undefined && last !== LIVE;
}

/**
 * The oracles to check at a head between two slow checks: every oracle whose price state at this block is not Live,
 * and every one that was not Live at its last read. The price states of all oracles are read at each head, together
 * (one batched eth_call), so an oracle leaving Live is checked at the first head it is seen.
 */
export async function everyBlockTargets(ctx: BlockContext, book: PokeBook, targets: readonly OracleTarget[]): Promise<OracleTarget[]> {
  const states = await Promise.all(targets.map((t) => ctx.reader.oracleState(t.oracle, t.kind)));
  return targets.filter((t, i) => states[i] !== LIVE || watchedEveryBlock(book, t.oracle));
}

/**
 * `from` is the instance's signer, the sender of the simulated poke. `leadSeconds` is how long before an interval ends
 * a scheduled poke is sent (POKE_LEAD_SECONDS when unset).
 */
export function oraclePokeJob(book: PokeBook, opts: { readonly from?: Address; readonly leadSeconds?: number } = {}): Job<OracleTarget, OracleDecision> {
  const from = opts.from ?? zeroAddress;
  const lead = opts.leadSeconds ?? POKE_LEAD_SECONDS;
  return {
    kind: "oraclePoke",

    async discover(ctx: BlockContext) {
      const m = ctx.config.manifest;
      const lp = m.markets.map((x): OracleTarget => ({ oracle: x.lpOracle.address, implementation: x.lpOracle.implementation, kind: "lp", feeds: x.feeds }));
      const debt = m.debtReserves.flatMap((r): OracleTarget[] => (r.debtOracle ? [{ oracle: r.debtOracle.address, implementation: r.debtOracle.implementation, kind: "debt", feeds: r.feeds }] : []));
      return [...lp, ...debt];
    },

    // Every feed round and price state `check` reads, in one batch.
    prefetch: (ctx, targets) => Promise.all(targets.flatMap((t) => [...t.feeds.map((f) => ctx.reader.feedRound(f.feed)), ctx.reader.oracleState(t.oracle, t.kind)])),

    async check(ctx, t) {
      let newRound = false;
      for (const f of t.feeds) {
        const [roundId] = await ctx.reader.feedRound(f.feed);
        if (book.lastRound.get(f.feed) !== roundId) {
          newRound = true;
          book.lastRound.set(f.feed, roundId);
        }
      }
      // Not Live, or just back from it: checked every block, poked (urgent) only when the poke would change stored state.
      const state = await ctx.reader.oracleState(t.oracle, t.kind);
      const last = book.lastState.get(t.oracle);
      if (state !== LIVE || (last !== undefined && last !== LIVE)) {
        if (await pokeWouldChange(ctx, t, state, last, from)) return { act: true, decision: { target: t, jobClass: "urgent", state } };
        // Nothing to write: the oracle already stores this state (another caller poked it, or this instance did).
        book.lastState.set(t.oracle, state);
      } else if (last === undefined) {
        book.lastState.set(t.oracle, state);
      }
      // An oracle with no feed legs in the manifest is still poked every CHECKPOINT_INTERVAL.
      const interval = pokeIntervalSeconds(t.feeds.map((f) => f.heartbeatSeconds));
      if (!pokeDue(ctx.blockTimestamp, book.lastPokeAt.get(t.oracle), interval, newRound, lead)) return { act: false, reason: "notDue" };
      return { act: true, decision: { target: t, jobClass: "scheduled", state } };
    },

    async build(ctx, { target: t, jobClass, state }) {
      book.lastPokeAt.set(t.oracle, ctx.blockTimestamp);
      book.lastState.set(t.oracle, state);
      return {
        job: "oraclePoke",
        jobClass,
        subject: `${ctx.config.chain.id}:${t.oracle}`,
        to: t.oracle,
        data: POKE_DATA,
        deadline: null,
        reservations: [],
        targets: [{ kind: "upgradeable", address: t.oracle, implementation: t.implementation }],
        params: { oracle: t.oracle },
      };
    },
  };
}
