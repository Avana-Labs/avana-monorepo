// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Publishes a fresh OCR2 round, at each feed's current answer, on every feed of the test-network world
// (deployments-local/<network>/world.json): the local rehearsal moves the chain clock by the timelock delays (5 days,
// 12 hours), after which every feed is older than its 86,400 s heartbeat plus margin and every LPOracle and DebtOracle
// would read Cached or Expired. A live Chainlink network publishes at least once per heartbeat; this does the same.
// `--symbols A,B` limits the refresh to those tokens; `--price SYMBOL=answer8` moves one token's feeds to a new answer.
// `--every <seconds>` keeps running and publishes a round on every feed at that interval (a test network's feeds,
// whose heartbeat is 86,400 s: script/testnet/testnet.ts feeds). The oracles sign from the encrypted keystores of
// AVANA_OCR_KEYSTORE_DIR (scenarios/ocr2.ts); the node is RPC_ANVIL, else AVANA_RPC_URL (never printed).
//
// Usage, from contracts/:  node script/e2e/refresh-feeds.ts --network anvil [--symbols USDC,WETH] [--price WETH=150000000000] [--every 3600]

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type Address, type Hex, type PublicClient, createPublicClient, createWalletClient, http } from "viem";
import { OCR2_ABI, transmit } from "./scenarios/ocr2.ts";

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
/** A loaded machine answers a burst of transmits slowly: viem's default 10 s request timeout failed a refresh there. */
export const RPC_TIMEOUT_MS = 120_000;
/** The node: the local rehearsal's RPC_ANVIL, else the deploy steps' AVANA_RPC_URL. */
export const feedsRpc = () => process.env.RPC_ANVIL ?? process.env.AVANA_RPC_URL ?? "http://127.0.0.1:8545";

/** A node's refusal of a nonce it already counts as used (geth's and some providers' wording). */
export const isStaleNonce = (e: unknown) => /nonce too low|lower than the current nonce/i.test((e as Error)?.message ?? String(e));

/**
 * `send`, sent again while the node rejects its nonce as already used. A load-balanced RPC (QuickNode on Base Sepolia)
 * can answer the pending nonce from a node one block behind, even after the previous receipt: the next transmit then
 * carries the mined nonce and is refused. A refused nonce means nothing was broadcast, so a retry after a short wait,
 * which takes a fresh nonce, is safe; any other error is thrown at once.
 */
export async function retryStaleNonce<T>(send: () => Promise<T>, tries = 6, waitMs = 3000): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await send();
    } catch (e) {
      if (i >= tries || !isStaleNonce(e)) throw e;
      await new Promise((r) => setTimeout(r, waitMs));
    }
  }
}

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
  const wallet = createWalletClient({ transport: http(feedsRpc(), { timeout: RPC_TIMEOUT_MS }) });
  const feeds = worldFeeds(network, opts.symbols);
  // A local node takes the whole burst at once; a live chain's RPC may lag on the pending nonce, so each round is mined
  // before the next is sent.
  const live = ![31337, 31338].includes(await client.getChainId());
  const hashes: Hex[] = [];
  for (const f of feeds) {
    const answer =
      opts.prices?.[f.symbol] ??
      ((await client.readContract({ address: f.proxy, abi: OCR2_ABI, functionName: "latestRoundData" })) as readonly bigint[])[1]!;
    const h = live
      ? await retryStaleNonce(() => transmit(client, wallet, f.aggregator, answer))
      : await transmit(client, wallet, f.aggregator, answer);
    if (live) {
      const r = await client.waitForTransactionReceipt({ hash: h });
      if (r.status !== "success") throw new Error(`transmit ${h} reverted`);
    } else hashes.push(h);
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
  const client = createPublicClient({ transport: http(feedsRpc(), { timeout: RPC_TIMEOUT_MS }) }) as PublicClient;
  const prices: Record<string, bigint> = {};
  for (const p of (arg("price") ?? "").split(",").filter(Boolean)) {
    const [s, v] = p.split("=");
    prices[s!] = BigInt(v!);
  }
  const every = Number(arg("every") ?? 0);
  const once = () => refreshFeeds(client, arg("network") ?? "anvil", { symbols: arg("symbols")?.split(","), prices });
  const secret = (m: string) => [process.env.RPC_ANVIL, process.env.AVANA_RPC_URL].reduce<string>((t, u) => (u ? t.split(u).join("<rpc>") : t), m);
  if (every > 0) {
    // Long-lived: a failed round is logged and retried at the next interval, so one RPC hiccup never stops it.
    for (;;) {
      try {
        process.stdout.write(`${new Date().toISOString()} refreshed ${await once()} feeds\n`);
      } catch (e) {
        process.stderr.write(`${new Date().toISOString()} refresh failed: ${secret((e as Error).message)}\n`);
      }
      await new Promise((r) => setTimeout(r, every * 1000));
    }
  }
  once()
    .then((n) => process.stdout.write(`refreshed ${n} feeds\n`))
    .catch((e: unknown) => {
      process.stderr.write(`${secret((e as Error).message)}\n`);
      process.exit(1);
    });
}
