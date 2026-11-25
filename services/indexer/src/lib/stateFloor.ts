// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The state floor of a development node restored from a saved state (`anvil --load-state`):
// the node keeps every block and log, but the state only from the block it was restored at, so a read pinned to an
// earlier block fails. INDEXER_STATE_FLOOR gives that block per chain ("<chainId>:<block>,..."); the hourly sampler
// samples only from it, and a read a log handler pins to an earlier block is made at the floor. Logs before the floor
// are indexed as usual. Only development nodes (31337, 31338) take a floor: a network's archive node keeps every state.

import { DEV_CHAIN_IDS } from "@avana/services-common";

export function parseStateFloors(raw: string | undefined): ReadonlyMap<number, bigint> {
  const floors = new Map<number, bigint>();
  for (const entry of (raw ?? "").split(",").map((e) => e.trim()).filter(Boolean)) {
    const m = /^(\d+):(\d+)$/.exec(entry);
    if (!m) throw new Error(`INDEXER_STATE_FLOOR: "${entry}" is not <chainId>:<block>`);
    const chainId = Number(m[1]);
    if (!DEV_CHAIN_IDS.has(chainId)) throw new Error(`INDEXER_STATE_FLOOR: chain ${chainId} is not a development node (${[...DEV_CHAIN_IDS].join(", ")})`);
    floors.set(chainId, BigInt(m[2]!));
  }
  return floors;
}

let fromEnv: ReadonlyMap<number, bigint> | undefined;
const envFloors = () => (fromEnv ??= parseStateFloors(process.env.INDEXER_STATE_FLOOR));

/** The first block whose state the chain's node serves (0 unless INDEXER_STATE_FLOOR sets one). */
export const stateFloor = (chainId: number, from: ReadonlyMap<number, bigint> = envFloors()): bigint => from.get(chainId) ?? 0n;

/** The block a read pinned to `block` is made at: `block`, or the chain's state floor when that is later. */
export function stateReadBlock(chainId: number, block: bigint, from: ReadonlyMap<number, bigint> = envFloors()): bigint {
  const floor = stateFloor(chainId, from);
  return block < floor ? floor : block;
}
