// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Publishes a fresh OCR2 round, at each feed's current answer, on every feed of the test-network world
// (deployments-local/<network>/world.json): the local rehearsal moves the chain clock by the timelock delays (5 days,
// 12 hours), after which every feed is older than its 86,400 s heartbeat plus margin and every LPOracle and DebtOracle
// would read Cached or Expired. A live Chainlink network publishes at least once per heartbeat; this does the same.
// `--symbols A,B` limits the refresh to those tokens; `--price SYMBOL=answer8` moves one token's feeds to a new answer.
//
// Usage, from contracts/:  node script/e2e/refresh-feeds.ts --network anvil [--symbols USDC,WETH] [--price WETH=150000000000]

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type Address, type Hex, type PublicClient, createPublicClient, createWalletClient, http } from "viem";
import { OCR2_ABI, transmit } from "./scenarios/ocr2.ts";

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

/** Every (symbol, aggregator, proxy) of the world, or of `symbols` when given. */
export function worldFeeds(network: string, symbols?: readonly string[]) {
  const world = JSON.parse(readFileSync(join(CONTRACTS, "deployments-local", network, "world.json"), "utf8")) as {
    feeds: Record<string, Record<string, Address>>;
  };
  const out: { symbol: string; role: string; aggregator: Address; proxy: Address }[] = [];
  for (const [symbol, f] of Object.entries(world.feeds)) {
    if (symbols && !symbols.includes(symbol)) continue;
    for (const [key, aggregator] of Object.entries(f)) {
      if (!key.endsWith("Aggregator")) continue;
      const role = key.slice(0, -"Aggregator".length);
      out.push({ symbol, role, aggregator, proxy: f[role]! });
    }
  }
  return out;
}

/** One fresh round on each feed, at `prices[symbol]` when given, else at the feed's current answer. */
export async function refreshFeeds(
  client: PublicClient,
  network: string,
  opts: { symbols?: readonly string[]; prices?: Record<string, bigint> } = {},
) {
  const wallet = createWalletClient({ transport: http(process.env.RPC_ANVIL ?? "http://127.0.0.1:8545") });
  const feeds = worldFeeds(network, opts.symbols);
  const hashes: Hex[] = [];
  for (const f of feeds) {
    const answer =
      opts.prices?.[f.symbol] ??
      ((await client.readContract({ address: f.proxy, abi: OCR2_ABI, functionName: "latestRoundData" })) as readonly bigint[])[1]!;
    hashes.push(await transmit(client, wallet, f.aggregator, answer));
  }
  for (const h of hashes) {
    const r = await client.waitForTransactionReceipt({ hash: h });
    if (r.status !== "success") throw new Error(`transmit ${h} reverted`);
  }
  return feeds.length;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const arg = (n: string) => {
    const i = process.argv.indexOf(`--${n}`);
    return i === -1 ? undefined : process.argv[i + 1];
  };
  const client = createPublicClient({ transport: http(process.env.RPC_ANVIL ?? "http://127.0.0.1:8545") }) as PublicClient;
  const prices: Record<string, bigint> = {};
  for (const p of (arg("price") ?? "").split(",").filter(Boolean)) {
    const [s, v] = p.split("=");
    prices[s!] = BigInt(v!);
  }
  refreshFeeds(client, arg("network") ?? "anvil", { symbols: arg("symbols")?.split(","), prices })
    .then((n) => process.stdout.write(`refreshed ${n} feeds\n`))
    .catch((e: unknown) => {
      process.stderr.write(`${(e as Error).message}\n`);
      process.exit(1);
    });
}
