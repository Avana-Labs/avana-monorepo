// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Process entry: configuration and manifest checks, kill switch, metrics, then one loop per chain. Startup order
// and failure handling are in DESIGN.md. An unexpected error stops the process (the supervisor restarts it with the
// persisted halt flag); it never logs and carries on with an unknown state.

import { createServer } from "node:http";
import { KMSClient } from "@aws-sdk/client-kms";
import { type Address, type PublicClient, createPublicClient, http, parseAbiItem, webSocket } from "viem";
import { awsKmsKey } from "./adapters/awsKms.ts";
import { logAlertSink } from "./adapters/logAlertSink.ts";
import { monitorSink, teeSink } from "./adapters/monitorSink.ts";
import { l1DataFee, paysL1DataFee } from "./chain/gas.ts";
import { kmsSigner } from "./chain/signer.ts";
import { type ChainConfig, loadConfig } from "./config.ts";
import { AccountCache } from "./discovery/accountCache.ts";
import { getLogsChunked } from "./discovery/backfill.ts";
import { IndexerStream, applyStreamRecords } from "./discovery/indexerStream.ts";
import { headWatchdog } from "./discovery/stream.ts";
import { InventoryBook } from "./inventory.ts";
import type { AlertSink } from "./monitoring/alerts.ts";
import { SpendTracker, fundingCheck } from "./monitoring/funding.ts";
import { chainLoop } from "./runtime/chainLoop.ts";
import { Submitter } from "./runtime/submitter.ts";
import { type SafetyState, effectiveMode } from "./safety/guards.ts";
import { startKillSwitch } from "./safety/killSwitch.ts";

const fatal = (kind: string) => (err: unknown) => {
  process.stderr.write(`${JSON.stringify({ type: "keeper.fatal", kind, error: String(err) })}\n`);
  process.exit(1);
};
process.on("uncaughtException", fatal("uncaughtException"));
process.on("unhandledRejection", fatal("unhandledRejection"));

const USER_PROXY_CREATED = parseAbiItem("event UserProxyCreated(address indexed wallet, address indexed spoke, uint256 indexed marketId, address proxy)");
const OPERATOR_HELPER_ABI = [parseAbiItem("function MAX_TOP_UP_BPS() view returns (uint256)")] as const;
const SWEEP_MS = 10 * 60 * 1000;
const line = (record: Record<string, unknown>) => process.stdout.write(`${JSON.stringify(record, (_k, v: unknown) => (typeof v === "bigint" ? v.toString(10) : v))}\n`);

const config = loadConfig(process.env);
const safety: SafetyState = { halted: false, codeMismatch: null, frozenHelperChains: new Set() };
startKillSwitch(config.killSwitch, safety, (halted, by) => process.stdout.write(`${JSON.stringify({ type: "keeper.killSwitch", halted, by })}\n`));

createServer((req, res) => {
  if (req.url !== "/metrics") return void res.writeHead(404).end();
  const lines = config.chains.map((c) => `keeper_mode{chain="${c.chain.key}",mode="${effectiveMode(config.mode, Boolean(c.kmsKeyId), safety)}"} 1`);
  res.writeHead(200, { "content-type": "text/plain" }).end(`${lines.join("\n")}\n`);
}).listen(config.metricsPort);

const post = async (url: string, body: unknown) => {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const json = (await r.json()) as { error?: { message: string } };
  if (!r.ok || json.error) throw new Error(json.error?.message ?? `HTTP ${r.status}`);
  return json;
};

/** Account set from RPC logs over [fromBlock, toBlock], independent of the indexer (REQ-LENS-004). Returns `toBlock`. */
async function backfill(cfg: ChainConfig, client: PublicClient, cache: AccountCache, fromBlock: bigint, toBlock: bigint): Promise<bigint> {
  const logs = await getLogsChunked(client, cfg.manifest.avana.aaveAdapter.address, USER_PROXY_CREATED, fromBlock, toBlock);
  for (const log of logs) {
    const a = (log as unknown as { args: { wallet: Address; spoke: Address; marketId: bigint; proxy: Address } }).args;
    const market = cfg.manifest.markets.find((m) => m.marketId === a.marketId);
    if (!market) continue;
    cache.upsert({ chainId: cfg.chain.id, spoke: a.spoke, proxy: a.proxy, wallet: a.wallet, marketId: a.marketId, vaultToken: market.vaultToken.address, createdBlock: log.blockNumber ?? toBlock }, "rpc");
  }
  return toBlock;
}

/** Accounts only one discovery source holds, up to the block both have read; each is kept and reported (REQ-LENS-004). */
function reportOneSided(cfg: ChainConfig, cache: AccountCache, rpcThrough: bigint, stream: IndexerStream) {
  const through = rpcThrough < stream.indexedBlock ? rpcThrough : stream.indexedBlock;
  if (through < 0n) return;
  const oneSided = cache.oneSided(cfg.chain.id, through);
  if (oneSided.length === 0) return;
  line({ type: "keeper.discoveryMismatch", chainId: cfg.chain.id, through, accounts: oneSided.map((a) => ({ spoke: a.spoke, proxy: a.proxy, indexer: a.seenBy.indexer, rpc: a.seenBy.rpc })) });
}

for (const cfg of config.chains) {
  const primary = createPublicClient({ transport: http(cfg.rpc.primary) }) as PublicClient;
  const fallback = createPublicClient({ transport: http(cfg.rpc.fallback) }) as PublicClient;
  const heads = createPublicClient({ transport: webSocket(cfg.rpc.ws, { keepAlive: true, reconnect: true }) });
  const cache = new AccountCache();
  const inventory = new InventoryBook();

  // Alerts go to the log and, when configured, to the monitoring service as this chain's instance. An alert raised
  // outside a pass (the Submitter's gas ceiling) carries the last processed head, so the monitor can hold it.
  let lastHead = 0n;
  const toMonitor = cfg.monitor ? monitorSink(cfg.monitor, { log: line }) : null;
  const sink = toMonitor ? teeSink(logAlertSink, toMonitor) : logAlertSink;
  const alerts: AlertSink = { send: (a) => sink.send(a.blockNumber === 0n ? { ...a, blockNumber: lastHead } : a) };

  const kms = cfg.kmsKeyId ? awsKmsKey(new KMSClient({}), cfg.kmsKeyId) : null;
  const signerAddress = kms ? await kms.address() : null;
  const helperEntry = signerAddress
    ? cfg.manifest.avana.operatorHelpers.find((h) => h.signer.toLowerCase() === signerAddress.toLowerCase())
    : cfg.manifest.avana.operatorHelpers[0];
  if (!helperEntry) throw new Error(`no operator helper in the manifest for chain ${cfg.chain.id}`);
  const submitter = kms && signerAddress
    ? new Submitter(cfg, primary, kmsSigner(kms, signerAddress), inventory, post, helperEntry.fundingSafe, {
        ceilingWei: cfg.gasCeilingWei!,
        l1Fee: paysL1DataFee(cfg.chain) ? (tx) => l1DataFee(primary, tx) : null,
        onCeiling: (detail) =>
          void alerts.send({ signal: "M-17", level: "page", chainId: cfg.chain.id, blockNumber: 0n, subject: detail.subject ?? "", detail: { ...detail, note: "gas ceiling" } }),
      })
    : null;

  const maxTopUpBps = await primary.readContract({ address: helperEntry.address, abi: OPERATOR_HELPER_ABI, functionName: "MAX_TOP_UP_BPS" });
  const start = BigInt(cfg.manifest.avana.aaveAdapter.startBlock);

  // Startup: the indexer's account set, read to the indexer's head, and independently the RPC logs over both
  // providers; the cache keeps the union and reports accounts only one source holds. An indexer that is down at
  // startup leaves the RPC set, and the stream catches up once it answers.
  const stream = new IndexerStream(config.indexerUrl, cfg.chain.id, config.indexerKey);
  const first = await stream.poll(Number.MAX_SAFE_INTEGER);
  applyStreamRecords(first.records, cache, cfg.manifest, cfg.chain.id);
  if (first.kind !== "ok") line({ type: "keeper.stream", chainId: cfg.chain.id, event: first.kind, detail: first.kind === "failed" ? first.error : first.finalized });
  const p1 = await backfill(cfg, primary, cache, start, await primary.getBlockNumber());
  const p2 = await backfill(cfg, fallback, cache, start, await fallback.getBlockNumber());
  reportOneSided(cfg, cache, p1 < p2 ? p1 : p2, stream);

  /** RPC logs from the last finalized block: after a stream failure, a stream reorg or a stalled head subscription. */
  const backfillFromFinalized = async () => {
    const finalized = await primary.getBlock({ blockTag: "finalized" });
    await backfill(cfg, primary, cache, finalized.number, await primary.getBlockNumber());
  };
  let streamDown = first.kind === "failed";
  const pollStream = async () => {
    const r = await stream.poll();
    applyStreamRecords(r.records, cache, cfg.manifest, cfg.chain.id);
    if (r.kind === "failed") {
      if (!streamDown) line({ type: "keeper.stream", chainId: cfg.chain.id, event: "failed", detail: r.error });
      streamDown = true;
      return;
    }
    if (r.kind === "reorg" || r.reconnected) {
      line({ type: "keeper.stream", chainId: cfg.chain.id, event: r.kind === "reorg" ? "reorg" : "reconnected", ...(r.kind === "reorg" ? { finalized: r.finalized } : {}) });
      await backfillFromFinalized();
    }
    streamDown = false;
  };

  const onHead = chainLoop({
    keeper: config,
    cfg,
    primary,
    fallback,
    cache,
    safety,
    alerts,
    submitter,
    from: helperEntry.signer,
    helper: { address: helperEntry.address, maxTopUpBps },
    onReorg: async () => {
      for (const a of cache.ofChain(cfg.chain.id)) a.liquidatableSince = null;
    },
    // The indexer stream refreshes the cache before each pass; its reconnect or reorg re-reads RPC logs from finality first.
    beforePass: pollStream,
    funding: fundingCheck({
      chainId: cfg.chain.id,
      primary,
      fallback,
      alerts,
      assets: [...new Map(cfg.manifest.debtReserves.map((r) => [r.asset.toLowerCase(), r.asset])).values()],
      fundingSafe: helperEntry.fundingSafe,
      helper: helperEntry.address,
      largest: cfg.largestDebtToCover,
      free: (asset, safeBalance) => inventory.free(cfg.chain.id, asset, safeBalance),
      gas: signerAddress ? { signer: signerAddress, dailyFloorWei: cfg.gasDailySpendWei!, spend: new SpendTracker() } : null,
    }),
    processed: (head) => {
      lastHead = head.number;
      toMonitor?.heartbeat(head.number);
    },
  });

  // Reconnect backfill: after a stalled stream, logs from the last finalized block are re-read before new heads.
  const watchdog = headWatchdog(cfg.chain, backfillFromFinalized);

  let running = Promise.resolve();
  heads.watchBlocks({
    emitMissed: true,
    onBlock: (b) => {
      watchdog.seen();
      const head = { number: b.number, hash: b.hash, parentHash: b.parentHash, timestamp: b.timestamp };
      running = running.then(() => onHead(head));
    },
    onError: fatal("headStream"),
  });

  // Full sweep: re-enumerate proxies from logs over both providers every 10 minutes, then compare with the indexer's set.
  setInterval(() => {
    running = running.then(async () => {
      const a = await backfill(cfg, primary, cache, start, await primary.getBlockNumber());
      const b = await backfill(cfg, fallback, cache, start, await fallback.getBlockNumber());
      reportOneSided(cfg, cache, a < b ? a : b, stream);
    });
  }, SWEEP_MS);
}
