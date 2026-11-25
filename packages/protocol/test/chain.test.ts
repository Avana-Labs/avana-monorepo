// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// getLogsChunked: the role replay of the manifest verification reads its logs in ranges a provider accepts.

import { type PublicClient, parseAbiItem } from "viem";
import { describe, expect, it } from "vitest";
import { LOG_RANGE, getLogsChunked } from "../src/manifest/chain.ts";

const GRANTED = parseAbiItem("event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)");
const ADDRESS = "0x00000000000000000000000000000000000000a1" as const;
const PROVIDER_LIMIT = 10_000n;

/** A client that refuses a range over 10,000 blocks, records each range and returns one log per block of the range. */
function fakeClient() {
  const ranges: [bigint, bigint][] = [];
  const client = {
    getLogs: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) => {
      if (toBlock - fromBlock + 1n > PROVIDER_LIMIT) throw new Error("eth_getLogs is limited to a 10,000 range");
      ranges.push([fromBlock, toBlock]);
      const logs = [];
      for (let b = fromBlock; b <= toBlock; b++) logs.push({ blockNumber: b, logIndex: 0 });
      return logs;
    },
  } as unknown as Pick<PublicClient, "getLogs">;
  return { client, ranges };
}

/** The ranges are consecutive and cover [from, to] exactly once. */
function expectCover(ranges: [bigint, bigint][], from: bigint, to: bigint, step: bigint) {
  expect(ranges[0]![0]).toBe(from);
  expect(ranges.at(-1)![1]).toBe(to);
  for (const [i, [a, b]] of ranges.entries()) {
    expect(a <= b).toBe(true);
    expect(b - a + 1n <= step).toBe(true);
    if (i > 0) expect(a).toBe(ranges[i - 1]![1] + 1n);
  }
}

describe("getLogsChunked", () => {
  it("covers a span beyond the provider limit in ranges of 5,000 blocks, in block order", async () => {
    const { client, ranges } = fakeClient();
    const from = 37_123_456n;
    const head = from + 23_456n;
    await expect(client.getLogs({ fromBlock: from, toBlock: head } as never)).rejects.toThrow("limited to a 10,000 range");
    const logs = await getLogsChunked(client, { address: ADDRESS, events: [GRANTED], fromBlock: from, toBlock: head });
    expect(ranges.length).toBe(5);
    expectCover(ranges, from, head, LOG_RANGE);
    expect(logs.map((l) => l.blockNumber)).toEqual(Array.from({ length: Number(head - from + 1n) }, (_, i) => from + BigInt(i)));
  });

  it("takes an exact multiple of the step without an empty last range", async () => {
    const { client, ranges } = fakeClient();
    const logs = await getLogsChunked(client, { address: ADDRESS, events: [GRANTED], fromBlock: 10n, toBlock: 10n + 3n * LOG_RANGE - 1n });
    expect(ranges).toEqual([
      [10n, 5_009n],
      [5_010n, 10_009n],
      [10_010n, 15_009n],
    ]);
    expect(logs.length).toBe(15_000);
  });

  it("asks for one range on a short span, one block included, and none when from is past to", async () => {
    const { client, ranges } = fakeClient();
    await getLogsChunked(client, { address: ADDRESS, events: [GRANTED], fromBlock: 0n, toBlock: 42n });
    await getLogsChunked(client, { address: ADDRESS, events: [GRANTED], fromBlock: 7n, toBlock: 7n });
    expect(await getLogsChunked(client, { address: ADDRESS, events: [GRANTED], fromBlock: 8n, toBlock: 7n })).toEqual([]);
    expect(ranges).toEqual([
      [0n, 42n],
      [7n, 7n],
    ]);
  });

  it("honours a smaller step and refuses a step that is not positive", async () => {
    const { client, ranges } = fakeClient();
    await getLogsChunked(client, { address: ADDRESS, events: [GRANTED], fromBlock: 100n, toBlock: 1_099n }, 300n);
    expectCover(ranges, 100n, 1_099n, 300n);
    expect(ranges.length).toBe(4);
    await expect(getLogsChunked(client, { address: ADDRESS, events: [GRANTED], fromBlock: 0n, toBlock: 1n }, 0n)).rejects.toThrow("not positive");
  });
});
