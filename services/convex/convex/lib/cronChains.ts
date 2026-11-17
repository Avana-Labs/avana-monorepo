// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The chains crons.ts schedules its per-chain jobs on (the export pull, the current-value sampler, the intent tracker
// and the Merkl incentives), from the deployment environment variable AVANA_CHAIN_IDS: comma-separated chain IDs,
// Ethereum and Base (1,8453) when unset. Sepolia and Base Sepolia (11155111,84532) are enabled by setting it on their
// deployment. Each job's interval follows the chain's block time: an Ethereum-like chain (12 s blocks) pulls every 30 s
// and tracks intents every 12 s, a Base-like chain (2 s blocks) every 10 s and 4 s. crons.ts is read when the functions
// are pushed, so a change of AVANA_CHAIN_IDS takes effect at the next push.

export const CHAIN_IDS_ENV = "AVANA_CHAIN_IDS";
export const DEFAULT_CHAIN_IDS: readonly number[] = [1, 8453];

/** Block time in seconds of each chain a deployment may serve: the networks, the test networks and the local nodes. */
const BLOCK_SECONDS: Readonly<Record<number, number>> = { 1: 12, 8453: 2, 11155111: 12, 84532: 2, 31337: 12, 31338: 2 };

export interface ChainSchedule {
  readonly chainId: number;
  /** Seconds between export pulls. */
  readonly pullSeconds: number;
  /** Seconds between intent-tracker runs (about one block). */
  readonly intentSeconds: number;
  /** The hourly Merkl refresh's cron expression (Ethereum-like chains at :17, Base-like chains at :47). */
  readonly merklCron: string;
}

/** The chain IDs of AVANA_CHAIN_IDS, or the default; an unknown, repeated or malformed ID stops the push. */
export function cronChainIds(env: Readonly<Record<string, string | undefined>>): number[] {
  const raw = env[CHAIN_IDS_ENV]?.trim();
  if (!raw) return [...DEFAULT_CHAIN_IDS];
  const ids = raw.split(",").map((s) => s.trim()).filter((s) => s !== "");
  if (ids.length === 0) throw new Error(`${CHAIN_IDS_ENV} names no chain`);
  const out: number[] = [];
  for (const s of ids) {
    if (!/^\d+$/.test(s)) throw new Error(`${CHAIN_IDS_ENV}: "${s}" is not a chain ID`);
    const id = Number(s);
    if (BLOCK_SECONDS[id] === undefined) throw new Error(`${CHAIN_IDS_ENV}: chain ${id} is not one Convex serves (${Object.keys(BLOCK_SECONDS).join(", ")})`);
    if (out.includes(id)) throw new Error(`${CHAIN_IDS_ENV}: chain ${id} is listed twice`);
    out.push(id);
  }
  return out;
}

export function chainSchedule(chainId: number): ChainSchedule {
  const block = BLOCK_SECONDS[chainId];
  if (block === undefined) throw new Error(`no schedule for chain ${chainId}`);
  const slow = block >= 12;
  return { chainId, pullSeconds: slow ? 30 : 10, intentSeconds: slow ? 12 : 4, merklCron: slow ? "17 * * * *" : "47 * * * *" };
}

/** Every scheduled chain with its intervals. */
export function cronChains(env: Readonly<Record<string, string | undefined>>): ChainSchedule[] {
  return cronChainIds(env).map(chainSchedule);
}
