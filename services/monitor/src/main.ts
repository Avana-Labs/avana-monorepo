// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Process entry: configuration (refused when any recipient has no channel or a chain has no second provider), the
// ingest and status server, then one round per chain every interval. A failed round is logged and retried on the
// next interval; /healthz answers 503 once a chain has gone 5 intervals without a successful round, for the external
// uptime check that watches the monitor itself.

import { MULTICALL3_ADDRESS } from "@avana/services-common";
import { type CallResult, type ContractCall, type ViewClient, readChainSnapshot } from "@avana/services-common/views";
import { type PublicClient, createPublicClient, http } from "viem";
import { AlertBook } from "./alertBook.ts";
import { type ChainConfig, type ChannelConfig, loadConfig } from "./config.ts";
import { fileIncidentLog } from "./incidentLog.ts";
import { KeeperFeed } from "./keeper.ts";
import { type ChainReads, runRound } from "./monitor.ts";
import { type Channel, logChannel, pagerDutyChannel, webhookChannel } from "./notify/channels.ts";
import { SnapshotMemory } from "./rules/snapshot.ts";
import { monitorServer } from "./server.ts";

const out = (o: unknown) => process.stdout.write(`${JSON.stringify(o)}\n`);
const fatal = (kind: string) => (err: unknown) => {
  process.stderr.write(`${JSON.stringify({ type: "monitor.fatal", kind, error: String(err) })}\n`);
  process.exit(1);
};
process.on("uncaughtException", fatal("uncaughtException"));
process.on("unhandledRejection", fatal("unhandledRejection"));

function pinned(client: PublicClient, blockNumber: bigint): ViewClient {
  return {
    multicall: async (calls: readonly ContractCall[]) =>
      (await client.multicall({ contracts: calls as never, allowFailure: true, blockNumber, multicallAddress: MULTICALL3_ADDRESS })) as unknown as readonly CallResult[],
  };
}

function chainReads(c: ChainConfig): ChainReads {
  const primary = createPublicClient({ transport: http(c.rpc.primary) }) as PublicClient;
  const second = createPublicClient({ transport: http(c.rpc.second) }) as PublicClient;
  const read = (client: PublicClient) => (b: { number: bigint; timestamp: number }) => readChainSnapshot(pinned(client, b.number), c.deployment, { blockNumber: b.number, timestamp: b.timestamp });
  return {
    chainId: c.chain.id,
    head: async () => {
      const b = await primary.getBlock({ blockTag: "latest" });
      return { number: b.number, timestamp: Number(b.timestamp) };
    },
    primary: read(primary),
    second: read(second),
  };
}

function channelOf(c: ChannelConfig): Channel {
  if (c.kind === "pagerduty") return pagerDutyChannel(c.name, c.routingKey, fetch);
  if (c.kind === "webhook") return webhookChannel(c.name, c.url, fetch);
  return logChannel(c.name, (line) => process.stdout.write(`${line}\n`));
}

const config = loadConfig(process.env);
const book = new AlertBook();
const feed = new KeeperFeed(config.keeperInstances);
const channels = new Map(config.channels.map((c) => [c.name, channelOf(c)]));
const log = fileIncidentLog(config.incidentLogPath);
const lastSuccess = new Map<number, number>(config.chains.map((c) => [c.chain.id, Date.now()]));

monitorServer({ keeperTokens: config.keeperTokens, statusToken: config.statusToken }, feed, () => book.open(), () => {
  const stale = config.chains.filter((c) => Date.now() - lastSuccess.get(c.chain.id)! > 5 * config.intervalSeconds * 1_000).map((c) => c.chain.key);
  return { ok: stale.length === 0, stale };
}).listen(config.port);
out({ type: "monitor.start", chains: config.chains.map((c) => c.chain.key), channels: config.channels.map((c) => `${c.name}:${c.kind}`), keeperInstances: config.keeperInstances.map((i) => i.name) });

for (const c of config.chains) {
  const reads = chainReads(c);
  const memory = new SnapshotMemory();
  let running = false;
  const tick = async () => {
    if (running) return; // a slow round is not overlapped by the next one
    running = true;
    try {
      const sent = await runRound(reads, { book, memory, feed, routing: config.routing, channels, log });
      lastSuccess.set(c.chain.id, Date.now());
      if (sent.length > 0) out({ type: "monitor.round", chain: c.chain.key, notices: sent.length });
    } catch (err) {
      out({ type: "monitor.roundFailed", chain: c.chain.key, error: err instanceof Error ? err.message : String(err) });
    } finally {
      running = false;
    }
  };
  void tick();
  setInterval(tick, config.intervalSeconds * 1_000);
}
