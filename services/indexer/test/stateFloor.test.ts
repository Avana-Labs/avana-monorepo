// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The state floor of a restored development node: reads pinned before it are made at it, only development nodes take
// one, and a log handler's read before the floor goes to the floor while the log itself is indexed.

import { beforeAll, describe, expect, it } from "vitest";
import { parseStateFloors, stateFloor, stateReadBlock } from "../src/lib/stateFloor.ts";

const BASE_DEV = 31338;

describe("state floor", () => {
  it("parses one floor per development chain", () => {
    const f = parseStateFloors("31337:5294, 31338:17882");
    expect([...f]).toEqual([
      [31337, 5294n],
      [31338, 17882n],
    ]);
    expect(stateFloor(31337, f)).toBe(5294n);
    expect(stateFloor(1, f)).toBe(0n);
  });

  it("is empty when unset, so a network's reads stay at their block", () => {
    const f = parseStateFloors(undefined);
    expect(f.size).toBe(0);
    expect(stateReadBlock(8453, 1462n, f)).toBe(1462n);
  });

  it("moves a read before the floor to the floor and leaves a later read", () => {
    const f = parseStateFloors("31338:17882");
    expect(stateReadBlock(BASE_DEV, 1462n, f)).toBe(17882n);
    expect(stateReadBlock(BASE_DEV, 17900n, f)).toBe(17900n);
  });

  it("refuses a floor on a network and a malformed entry", () => {
    expect(() => parseStateFloors("8453:100")).toThrow(/not a development node/);
    expect(() => parseStateFloors("31337")).toThrow(/<chainId>:<block>/);
  });
});

describe("a log handler on a restored node", () => {
  let harness: typeof import("./harness/run.ts");
  beforeAll(async () => {
    // Read when the handlers load.
    process.env.INDEXER_STATE_FLOOR = `${BASE_DEV}:17882`;
    harness = await import("./harness/run.ts");
  });

  it("indexes a market listed before the floor and reads its pool's fee at the floor", async () => {
    const { Run, addr } = harness;
    const run = new Run(BASE_DEV);
    const reads: unknown[] = [];
    run.client.readContract = (async (req: { blockNumber?: bigint }) => {
      reads.push(req.blockNumber);
      return 500;
    }) as never;
    await run.deliver({
      source: "MarketRegistry",
      event: "MarketRegistered",
      args: { marketId: 1n, integrationId: 1, pool: addr(0xf5), poolId: `0x${"00".repeat(32)}`, tokens: [addr(0xf6), addr(0xf7)], vaultToken: addr(0xf0), lpOracle: addr(0xf8), spoke: addr(0xf9) },
      address: addr(0xfa),
      block: 1462n,
      logIndex: 0,
    });
    expect(reads).toEqual([17882n]);
    const schema = (await import("./harness/schema.ts")).default;
    expect(run.store.rows(schema.ammPool)).toMatchObject([{ pool: addr(0xf5), feePips: 500, listedBlock: 1462n }]);
  });
});
