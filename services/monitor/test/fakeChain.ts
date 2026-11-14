// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A scripted chain for probe and round tests: contract reads answered by (address, function, args) handlers, logs
// and storage from lists, the snapshot from a function of the block.

import { CHAINS, type ServiceManifest } from "@avana/services-common";
import { FIXTURE_HUB, FIXTURE_LEND, FIXTURE_U, FIXTURE_X, fixtureHubAsset, fixtureMarkets, fixtureSlices, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import type { CallResult, ChainSnapshot, ContractCall, ViewClient } from "@avana/services-common/views";
import type { Address, Hex } from "viem";
import type { Block, ChainReads, ProviderReads } from "../src/monitor.ts";
import type { CallOutcome, Override, RawLog, ReadContext } from "../src/probe.ts";

/** Answers a call, or throws to make it fail (a revert). Return `undefined` for "not handled". */
export type Handler = (call: ContractCall) => unknown;

export interface FakeProvider {
  handlers: Handler[];
  logs: RawLog[];
  storage: Map<string, Hex>;
  snapshot: (b: Block) => ChainSnapshot;
  down?: boolean;
  /** Answers simulated calls (`eth_call` with overrides). */
  call?: (from: Address, to: Address, data: Hex, overrides: readonly Override[]) => Promise<CallOutcome> | CallOutcome;
}

export function fixtureSnapshot(b: Block, edit: (s: ChainSnapshot) => ChainSnapshot = (s) => s): ChainSnapshot {
  return edit({
    chainId: 1,
    blockNumber: b.number.toString(10),
    timestamp: b.timestamp,
    hubs: [{ chainId: 1, hub: FIXTURE_HUB, label: "Stable", tier: 1, recorded: true, applicationState: 0, assetCount: 1, lendAssetIds: ["1"], lendSpokes: [FIXTURE_LEND], cdpSpokes: [FIXTURE_U, FIXTURE_X], blockNumber: b.number.toString(10) }],
    creditLines: [],
    hubAssets: [fixtureHubAsset],
    slices: fixtureSlices,
    spokeReserves: fixtureSpokeReserves,
    markets: fixtureMarkets,
  });
}

export function fakeProvider(init: Partial<FakeProvider> = {}): FakeProvider {
  return { handlers: [], logs: [], storage: new Map(), snapshot: (b) => fixtureSnapshot(b), ...init };
}

export function views(p: FakeProvider): ViewClient {
  return {
    multicall: async (calls) => {
      if (p.down) throw new Error("ECONNREFUSED");
      return calls.map((call): CallResult => {
        for (const h of p.handlers) {
          try {
            const r = h(call);
            if (r !== undefined) return { status: "success", result: r };
          } catch (error) {
            return { status: "failure", error };
          }
        }
        return { status: "failure", error: new Error(`unscripted ${call.functionName} on ${call.address}`) };
      });
    },
  };
}

export function provider(p: FakeProvider): ProviderReads {
  return {
    snapshot: async (b) => {
      if (p.down) throw new Error("ECONNREFUSED");
      return p.snapshot(b);
    },
    views: () => views(p),
    rpc: (b) => ({
      getLogs: async (addresses, topic0s, from, to) => {
        if (p.down) throw new Error("ECONNREFUSED");
        if (to > b.number) throw new Error("logs past the block");
        const set = new Set(addresses.map((a) => a.toLowerCase()));
        const topics = new Set(topic0s.map((t) => t.toLowerCase()));
        return p.logs.filter((l) => set.has(l.address.toLowerCase()) && topics.has((l.topics[0] ?? "").toLowerCase()) && l.blockNumber >= from && l.blockNumber <= to);
      },
      getStorageAt: async (address: Address, slot: Hex) => p.storage.get(`${address.toLowerCase()}:${slot}`) ?? `0x${"00".repeat(32)}`,
      call: async (from, to, data, overrides = []) => {
        if (p.down) throw new Error("ECONNREFUSED");
        if (!p.call) return { ok: false, error: "no call handler" };
        return p.call(from, to, data, overrides);
      },
    }),
  };
}

export const EMPTY_MANIFEST = { chainId: 1, avana: { lens: { address: "0x00000000000000000000000000000000000000e1" }, marketRegistry: { address: "0x00000000000000000000000000000000000000e2" }, parameterStore: { address: "0x00000000000000000000000000000000000000e3" }, firstLossReserves: [] }, markets: [], debtReserves: [], aave: { hubs: [], lendSpokes: [], borrowSpokes: [] } } as unknown as ServiceManifest;

export function fakeChain(head: () => Block, primary: FakeProvider, second: FakeProvider, manifest: ServiceManifest = EMPTY_MANIFEST): ChainReads {
  return { chain: CHAINS.mainnet, manifest, head: async () => head(), primary: provider(primary), second: provider(second) };
}

export async function contextOf(p: FakeProvider, b: Block, manifest: ServiceManifest = EMPTY_MANIFEST): Promise<ReadContext> {
  const r = provider(p);
  return { chain: CHAINS.mainnet, manifest, block: b, views: r.views(b), rpc: r.rpc(b), snapshot: await r.snapshot(b) };
}

/** A handler answering `fn` (on any address, or on `address`) with `answer(args)`. */
export const on = (fn: string, answer: (args: readonly unknown[]) => unknown, address?: string): Handler => (call) =>
  call.functionName === fn && (address === undefined || call.address.toLowerCase() === address.toLowerCase()) ? answer(call.args ?? []) : undefined;
