// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The chains crons.ts schedules its jobs for (the export pull, the current-value sampler and the Merkl incentives),
// from the deployment environment variable AVANA_CHAIN_IDS: comma-separated chain IDs, for example 1,8453 on the
// production deployment and 11155111,84532 on the test deployment. Unset or blank, the deployment schedules no cron at
// all: a development deployment does not spend function calls and RPC requests on a schedule nobody reads. The sampler
// and the pull run every 60 s on every chain (the pull reads finalized blocks only); the intent tracker is not a cron
// but runs while a chain has open intents, about once a block (intents.ts). crons.ts is read when the functions are
// pushed, so a change of AVANA_CHAIN_IDS takes effect at the next push.

export const CHAIN_IDS_ENV = "AVANA_CHAIN_IDS";

/** Seconds between current-value samples of each chain. */
export const SAMPLE_SECONDS = 60;
/** Seconds between export pulls of each chain. */
export const PULL_SECONDS = 60;

/** Block time in seconds of each chain a deployment may serve: the networks, the test networks and the local nodes. */
const BLOCK_SECONDS: Readonly<Record<number, number>> = { 1: 12, 8453: 2, 11155111: 12, 84532: 2, 31337: 12, 31338: 2 };

export interface ChainSchedule {
  readonly chainId: number;
  /** Seconds between current-value samples. */
  readonly sampleSeconds: number;
  /** Seconds between export pulls. */
  readonly pullSeconds: number;
  /** Seconds between intent-tracker runs while the chain has open intents (about one block). */
  readonly intentSeconds: number;
  /** The hourly Merkl refresh's cron expression (Ethereum-like chains at :17, Base-like chains at :47). */
  readonly merklCron: string;
}

/** The chain IDs of AVANA_CHAIN_IDS, none when unset; an unknown, repeated or malformed ID stops the push. */
export function cronChainIds(env: Readonly<Record<string, string | undefined>>): number[] {
  const raw = env[CHAIN_IDS_ENV]?.trim();
  if (!raw) return [];
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
  return { chainId, sampleSeconds: SAMPLE_SECONDS, pullSeconds: PULL_SECONDS, intentSeconds: slow ? 12 : 4, merklCron: slow ? "17 * * * *" : "47 * * * *" };
}

/** Every scheduled chain with its intervals. */
export function cronChains(env: Readonly<Record<string, string | undefined>>): ChainSchedule[] {
  return cronChainIds(env).map(chainSchedule);
}
