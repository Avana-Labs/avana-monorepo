// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Delivers logs to the indexer's registered handlers against the in-memory store, as Ponder would: each log is
// encoded with its source's ABI and decoded again, with addresses in lower case as Ponder's decoder returns them, carries its block number, block hash, timestamp, log index and transaction hash, and runs the handler
// registered under `<Source>:<Event>`. Block hashes depend on a branch label, so a reorg is two branches that share
// their blocks up to a common ancestor.

import { type Abi, type Address, type Hex, decodeEventLog, encodeAbiParameters, encodeEventTopics, keccak256, toHex } from "viem";
import { clPoolAbi, uniswapV4PoolManagerAbi } from "@avana/services-common/views";
import { abis } from "../../src/config/abis.ts";
import { useManifests } from "../../src/config/integrations.ts";
import { MemoryStore } from "./store.ts";
import { HARNESS_MANIFESTS } from "./manifest.ts";
import { registered } from "./registry.ts";
// Every handler file but the hourly sampler, which reads a manifest at import; each registers on import.
import "../../src/handlers/accounts.ts";
import "../../src/handlers/adapter.ts";
import "../../src/handlers/aave.ts";
import "../../src/handlers/collateral.ts";
import "../../src/handlers/governance.ts";
import "../../src/handlers/hubs.ts";
import "../../src/handlers/liquidation.ts";
import "../../src/handlers/markets.ts";
import "../../src/handlers/premium.ts";
import "../../src/handlers/pools.ts";
import "../../src/handlers/poolManager.ts";
import "../../src/handlers/progress.ts";

export { registered };
useManifests(HARNESS_MANIFESTS);

/** The ABI each Ponder source decodes with (ponder.config.ts). */
export function abiOfSource(source: string): Abi {
  if (source.startsWith("AaveSpoke")) return abis.AaveSpoke as Abi;
  if (source.startsWith("AaveHub")) return abis.AaveHub as Abi;
  if (source === "AmmPool") return clPoolAbi as Abi;
  if (source === "UniswapV4PoolManager") return uniswapV4PoolManagerAbi as Abi;
  if (source === "DaoDeficitOffset" || source === "FirstLossReserveListed") return abis.FirstLossReserve as Abi;
  if (source === "VaultTokenListed") return abis.VaultToken as Abi;
  const abi = (abis as unknown as Record<string, Abi>)[source];
  if (!abi) throw new Error(`no ABI for source ${source}`);
  return abi;
}

export interface LogSpec {
  readonly source: string;
  readonly event: string;
  readonly args: Readonly<Record<string, unknown>>;
  readonly address: Address;
  readonly block: bigint;
  readonly logIndex: number;
}

export const blockHash = (n: bigint, branch = "a"): Hex => keccak256(toHex(`${branch}:${n}`));
export const txHash = (n: bigint, logIndex: number, branch = "a"): Hex => keccak256(toHex(`${branch}:${n}:${logIndex}`));
export const blockTime = (n: bigint) => 1_767_225_600n + n * 12n;

/** Encodes then decodes the log with the source's ABI, as Ponder decodes it from the RPC. */
function decoded(spec: LogSpec): Record<string, unknown> {
  const abi = abiOfSource(spec.source);
  const item = abi.find((i) => i.type === "event" && i.name === spec.event);
  if (!item || item.type !== "event") throw new Error(`${spec.source} has no event ${spec.event}`);
  const topics = encodeEventTopics({ abi: [item], eventName: spec.event, args: spec.args as never } as never);
  const nonIndexed = item.inputs.filter((i) => !i.indexed);
  const data = encodeAbiParameters(nonIndexed, nonIndexed.map((i) => {
    const v = spec.args[i.name!];
    if (v === undefined) throw new Error(`${spec.event}: argument ${i.name} missing`);
    return v;
  }));
  return lowerAddresses(decodeEventLog({ abi: [item], topics: topics as [Hex, ...Hex[]], data, strict: true }).args) as Record<string, unknown>;
}

/** Ponder decodes event addresses in lower case (`formatAddress: toLowerCase`); viem checksums them. */
function lowerAddresses(v: unknown): unknown {
  if (typeof v === "string") return /^0x[0-9a-fA-F]{40}$/.test(v) ? v.toLowerCase() : v;
  if (Array.isArray(v)) return v.map(lowerAddresses);
  if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, lowerAddresses(x)]));
  return v;
}

export function eventOf(spec: LogSpec, branch = "a") {
  return {
    args: decoded(spec),
    block: { number: spec.block, hash: blockHash(spec.block, branch), timestamp: blockTime(spec.block) },
    log: { logIndex: spec.logIndex, address: spec.address.toLowerCase() as Address },
    transaction: { hash: txHash(spec.block, spec.logIndex, branch) },
  };
}

/** One chain's indexing run: an in-memory store and the context handlers receive. */
export class Run {
  readonly store = new MemoryStore();
  /** Contract reads a handler makes (`context.client`); a test sets what they return. */
  readonly client: Record<string, (...a: never[]) => Promise<unknown>> = {
    readContract: async () => {
      throw new Error("no readContract stub set");
    },
    multicall: async () => {
      throw new Error("no multicall stub set");
    },
  };

  constructor(readonly chainId = 1) {}

  async deliver(spec: LogSpec, branch = "a"): Promise<void> {
    const handler = registered.get(`${spec.source}:${spec.event}`);
    if (!handler) throw new Error(`no handler for ${spec.source}:${spec.event}`);
    await handler({ event: eventOf(spec, branch), context: { db: this.store.api(), chain: { id: this.chainId, name: "test" }, client: this.client } });
  }

  /** Delivers a later log of the transaction `hash` (an earlier log's), as a contract call emitting several logs. */
  async deliverIn(hash: Hex, spec: LogSpec, branch = "a"): Promise<void> {
    const handler = registered.get(`${spec.source}:${spec.event}`);
    if (!handler) throw new Error(`no handler for ${spec.source}:${spec.event}`);
    const event = { ...eventOf(spec, branch), transaction: { hash } };
    await handler({ event, context: { db: this.store.api(), chain: { id: this.chainId, name: "test" }, client: this.client } });
  }

  async deliverAll(specs: readonly LogSpec[], branch = "a"): Promise<void> {
    for (const s of specs) await this.deliver(s, branch);
  }

  /** The Progress block handler at `n`, which the export and history read as the indexed head. */
  async progress(n: bigint, branch = "a"): Promise<void> {
    const handler = registered.get("Progress:block")!;
    await handler({ event: { block: { number: n, hash: blockHash(n, branch), timestamp: blockTime(n) } }, context: { db: this.store.api(), chain: { id: this.chainId, name: "test" }, client: this.client } });
  }
}

export { addr } from "./addr.ts";
