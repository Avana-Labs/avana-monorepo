// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Publishes a fresh OCR2 round, at each feed's current answer, on every feed of the test-network world
// (deployments-local/<network>/world.json): the local rehearsal moves the chain clock by the timelock delays (5 days,
// 12 hours), after which every feed is older than its 86,400 s heartbeat plus margin and no LPOracle or debt price
// would be fresh. A live Chainlink network publishes at least once per heartbeat; this does the same.
// `--symbols A,B` limits the refresh to those tokens; `--price SYMBOL=answer8` moves one token's feeds to a new answer.
// `--every <seconds>` keeps running and publishes a round on every feed at that interval (a test network's feeds,
// whose heartbeat is 86,400 s: script/testnet/testnet.ts feeds). The oracles sign from the encrypted keystores of
// AVANA_OCR_KEYSTORE_DIR (scenarios/ocr2.ts); the node is RPC_ANVIL, else AVANA_RPC_URL (never printed).
//
// Usage, from contracts/:  node script/e2e/refresh-feeds.ts --network anvil [--symbols USDC,WETH] [--price WETH=150000000000] [--every 3600]

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type Address, type Hex, type PublicClient, createPublicClient, createWalletClient, encodeFunctionData, http } from "viem";
import { OCR2_ABI, oracleAccounts, signedTransmit } from "./scenarios/ocr2.ts";

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
/** A loaded machine answers a burst of transmits slowly: viem's default 10 s request timeout failed a refresh there. */
export const RPC_TIMEOUT_MS = 120_000;
/** The node: the local rehearsal's RPC_ANVIL, else the deploy steps' AVANA_RPC_URL. */
export const feedsRpc = () => process.env.RPC_ANVIL ?? process.env.AVANA_RPC_URL ?? "http://127.0.0.1:8545";

/** A node's refusal of a nonce it already counts as used (geth's and some providers' wording). */
export const isStaleNonce = (e: unknown) => /nonce too low|lower than the current nonce/i.test((e as Error)?.message ?? String(e));

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

/** At most this many rounds in flight at once on a live chain. */
export const LIVE_BURST = 50;
/**
 * Rounds signed, and receipts read, at the same time (a round takes about four reads): more hits a provider's rate limit
 * (QuickNode answered 429 to 50 at once).
 */
export const PREPARE_AT_ONCE = 8;

/** How `sendRounds` reaches the chain (a fake in the tests). `P` is a round signed and ready to send. */
export type RoundSender<R, P> = {
  /** Reads and signs one round; sends nothing. */
  prepare: (round: R) => Promise<P>;
  /** The signer's next nonce, counting its pending transactions (and anything else a burst's sends share). */
  start: () => Promise<number>;
  /** Sends one prepared round with `nonce`; returns its hash. */
  send: (prepared: P, nonce: number) => Promise<Hex>;
  /** Waits for the receipt of `hash`. */
  receipt: (hash: Hex) => Promise<{ status: string }>;
};

/**
 * Sends every round in bursts: each burst's rounds are signed in parallel, sent one after another on consecutive nonces
 * from one read of the pending nonce, and only then are their receipts awaited. A burst holds at most `burst` rounds and
 * never two for the same aggregator (`key`), since each round's epoch comes from the aggregator's last one. A
 * load-balanced RPC can answer the pending nonce from a node one block behind (QuickNode on Base Sepolia): the send on
 * that nonce is then refused as "nonce too low" and nothing from it on went out, so after the receipts of what did go
 * out, the rest is sent again on a fresh nonce after `waitMs`, at most `tries` times in all. Any other error, and a
 * reverted round, is thrown. Returns the hashes in the order sent.
 */
export async function sendRounds<R, P>(
  rounds: readonly R[],
  key: (round: R) => string,
  s: RoundSender<R, P>,
  burst: number,
  tries = 6,
  waitMs = 3000,
): Promise<Hex[]> {
  const hashes: Hex[] = [];
  let rest = [...rounds];
  while (rest.length > 0) {
    const keys = new Set<string>();
    const group: R[] = [];
    const later: R[] = [];
    for (const r of rest) {
      if (group.length < burst && !keys.has(key(r))) {
        keys.add(key(r));
        group.push(r);
      } else later.push(r);
    }
    rest = later;
    let pending: P[] = [];
    for (let i = 0; i < group.length; i += PREPARE_AT_ONCE) {
      pending.push(...(await Promise.all(group.slice(i, i + PREPARE_AT_ONCE).map((r) => s.prepare(r)))));
    }
    for (let attempt = 1; pending.length > 0; attempt++) {
      let nonce = await s.start();
      const sent: Hex[] = [];
      let refused: unknown;
      for (const p of pending) {
        try {
          sent.push(await s.send(p, nonce));
          nonce++;
        } catch (e) {
          if (!isStaleNonce(e)) throw e;
          refused = e;
          break;
        }
      }
      for (let i = 0; i < sent.length; i += PREPARE_AT_ONCE) {
        const chunk = sent.slice(i, i + PREPARE_AT_ONCE);
        const receipts = await Promise.all(chunk.map((h) => s.receipt(h)));
        const bad = chunk.find((_, j) => receipts[j]!.status !== "success");
        if (bad) throw new Error(`transmit ${bad} reverted`);
      }
      hashes.push(...sent);
      pending = pending.slice(sent.length);
      if (pending.length > 0) {
        if (attempt >= tries) throw refused;
        await new Promise((r) => setTimeout(r, waitMs));
      }
    }
  }
  return hashes;
}

/**
 * One fresh round on each feed, at `prices[symbol]` when given, else at the feed's current answer. On a live chain the
 * rounds go out in bursts of `LIVE_BURST` (`sendRounds`); a local node takes them all in one burst.
 */
export async function refreshFeeds(
  client: PublicClient,
  network: string,
  opts: { symbols?: readonly string[]; prices?: Record<string, bigint> } = {},
) {
  const wallet = createWalletClient({ transport: http(feedsRpc(), { timeout: RPC_TIMEOUT_MS }) });
  const feeds = worldFeeds(network, opts.symbols);
  const [oracle] = await oracleAccounts();
  const chainId = await client.getChainId();
  const live = ![31337, 31338].includes(chainId);
  let fees: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint } | undefined;
  type Feed = (typeof feeds)[number];
  type Prepared = { to: Address; data: Hex; gas: bigint };
  const sender: RoundSender<Feed, Prepared> = {
    prepare: async (f) => {
      const answer =
        opts.prices?.[f.symbol] ??
        ((await client.readContract({ address: f.proxy, abi: OCR2_ABI, functionName: "latestRoundData" })) as readonly bigint[])[1]!;
      const args = await signedTransmit(client, f.aggregator, answer);
      const call = { abi: OCR2_ABI, functionName: "transmit", args } as const;
      const gas = await client.estimateContractGas({ ...call, account: oracle!, address: f.aggregator });
      return { to: f.aggregator, data: encodeFunctionData(call), gas };
    },
    start: async () => {
      const [nonce, f] = await Promise.all([
        client.getTransactionCount({ address: oracle!.address, blockTag: "pending" }),
        client.estimateFeesPerGas(),
      ]);
      fees = { maxFeePerGas: f.maxFeePerGas!, maxPriorityFeePerGas: f.maxPriorityFeePerGas! };
      return nonce;
    },
    send: async (p, nonce) =>
      wallet.sendRawTransaction({
        serializedTransaction: await oracle!.signTransaction({ chainId, type: "eip1559", nonce, ...p, ...fees! }),
      }),
    receipt: (hash) => client.waitForTransactionReceipt({ hash }),
  };
  await sendRounds(feeds, (f) => f.aggregator.toLowerCase(), sender, live ? LIVE_BURST : Math.max(feeds.length, 1));
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
