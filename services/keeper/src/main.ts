// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Process entry: configuration and manifest checks, kill switch, metrics, then one loop per chain. Startup order
// and failure handling are in DESIGN.md. An unexpected error stops the process (the supervisor restarts it with the
// persisted halt flag); it never logs and carries on with an unknown state.

import { createServer } from "node:http";
import { KMSClient } from "@aws-sdk/client-kms";
import { type Address, type PublicClient, createPublicClient, parseAbi, parseAbiItem, webSocket } from "viem";
import { debtOracleAbi, marketRegistryAbi } from "@avana/protocol/abis";
import { awsKmsKey } from "./adapters/awsKms.ts";
import { localKeystoreSigner } from "./adapters/localKeystore.ts";
import { logAlertSink } from "./adapters/logAlertSink.ts";
import { monitorSink, teeSink } from "./adapters/monitorSink.ts";
import { readClient } from "./chain/client.ts";
import { l1DataFee, paysL1DataFee } from "./chain/gas.ts";
import { kmsSigner } from "./chain/signer.ts";
import { type ChainConfig, loadConfig } from "./config.ts";
import { AccountCache } from "./discovery/accountCache.ts";
import { getLogsChunked } from "./discovery/backfill.ts";
import { IndexerStream, applyStreamRecords } from "./discovery/indexerStream.ts";
import { headWatchdog } from "./discovery/stream.ts";
import { InventoryBook } from "./inventory.ts";
import { ChainMetrics, renderMetrics, valueInWei } from "./metrics.ts";
import { type AlertSink, HeldAlerts } from "./monitoring/alerts.ts";
import { DiscoveryWatch, discoveryThrough } from "./monitoring/discovery.ts";
import { SpendTracker, fundingCheck } from "./monitoring/funding.ts";
import { HubBook, SpendBook, attributeSubject, liquidationReward } from "./runtime/budget.ts";
import { chainLoop } from "./runtime/chainLoop.ts";
import { type IncludedSpend, type SpendSink, Submitter } from "./runtime/submitter.ts";
import type { JobClass } from "./types.ts";
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
/** A sweep from the manifest's start block, once a day; the other sweeps resume from the last one's finalized block. */
const FULL_SWEEP_MS = 24 * 60 * 60 * 1000;
const NATIVE_FEED_ABI = parseAbi(["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)", "function decimals() view returns (uint8)"]);
const CLASSES: readonly JobClass[] = ["urgent", "scheduled", "lazy"];
const line = (record: Record<string, unknown>) => process.stdout.write(`${JSON.stringify(record, (_k, v: unknown) => (typeof v === "bigint" ? v.toString(10) : v))}\n`);

const config = loadConfig(process.env);
const safety: SafetyState = { halted: false, codeMismatch: null, frozenHelperChains: new Set() };
startKillSwitch(config.killSwitch, safety, (halted, by) => process.stdout.write(`${JSON.stringify({ type: "keeper.killSwitch", halted, by })}\n`));

// Metric names and labels are listed in metrics.ts; dashboards depend on them.
const metrics = new Map(config.chains.map((c) => [c.chain.id, new ChainMetrics()] as const));
createServer((req, res) => {
  if (req.url !== "/metrics") return void res.writeHead(404).end();
  const text = renderMetrics(
    config.chains.map((c) => ({ chain: c.chain.key, mode: effectiveMode(config.mode, Boolean(c.kmsKeyId || c.localKeystore), safety), metrics: metrics.get(c.chain.id)! })),
  );
  res.writeHead(200, { "content-type": "text/plain; version=0.0.4; charset=utf-8" }).end(text);
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

/**
 * Accounts only one discovery source holds, up to the block both have read; each is kept and logged after each full
 * backfill (REQ-LENS-004). M-30 judges the same set at every head (monitoring/discovery.ts).
 */
function reportOneSided(cfg: ChainConfig, cache: AccountCache, rpcThrough: bigint, stream: IndexerStream) {
  const through = discoveryThrough(rpcThrough, stream.indexedBlock);
  if (through < 0n) return;
  const oneSided = cache.oneSided(cfg.chain.id, through);
  if (oneSided.length === 0) return;
  line({ type: "keeper.discoveryMismatch", chainId: cfg.chain.id, through, accounts: oneSided.map((a) => ({ spoke: a.spoke, proxy: a.proxy, indexer: a.seenBy.indexer, rpc: a.seenBy.rpc })) });
}

/**
 * The block-cadence spend alerts, then M-16, M-17 and M-33: the rolling 24 h spend per class for the metrics, M-32 for a
 * class at its budget and M-31 for a spend anomaly, from the spend log; they are judged before the funding reads, so a
 * failed read never hides them. The funding reads run at the slow-cadence heads only; at the heads in between, the
 * alerts the last reads raised are posted again (HeldAlerts), so the monitor holds them as before.
 */
function spendAndFunding(
  book: SpendBook,
  m: ChainMetrics,
  alerts: AlertSink,
  held: HeldAlerts,
  funding: (head: { number: bigint; timestamp: bigint }) => Promise<void>,
) {
  return async (head: { number: bigint; timestamp: bigint }, slow: boolean) => {
    book.watchFrom(head.timestamp);
    m.spend24h = new Map(CLASSES.map((c) => [c, book.spent24h(head.timestamp, c)] as const));
    for (const a of book.alerts(head)) await alerts.send(a);
    if (!slow) return held.replay(head.number);
    held.begin();
    await funding(head);
  };
}

for (const cfg of config.chains) {
  // Reads made together at one block travel as one Multicall3 eth_call (chain/client.ts).
  const primary = readClient(cfg.chain.id, cfg.rpc.primary);
  const fallback = readClient(cfg.chain.id, cfg.rpc.fallback);
  const heads = createPublicClient({ transport: webSocket(cfg.rpc.ws, { keepAlive: true, reconnect: true }) });
  const cache = new AccountCache();
  const inventory = new InventoryBook();

  // Alerts go to the log and, when configured, to the monitoring service as this chain's instance. An alert raised
  // outside a pass (the Submitter's gas ceiling) carries the last processed head, so the monitor can hold it.
  let lastHead = 0n;
  const chainMetrics = metrics.get(cfg.chain.id)!;
  const toMonitor = cfg.monitor ? monitorSink(cfg.monitor, { log: line }) : null;
  const sink = toMonitor ? teeSink(logAlertSink, toMonitor) : logAlertSink;
  const alerts: AlertSink = {
    send: (a) => {
      const alert = a.blockNumber === 0n ? { ...a, blockNumber: lastHead } : a;
      chainMetrics.alert(alert);
      return sink.send(alert);
    },
  };

  const kms = cfg.kmsKeyId ? awsKmsKey(new KMSClient({}), cfg.kmsKeyId) : null;
  // The KMS signer, or on the local rehearsal network only, an encrypted keystore (config.ts refuses it elsewhere).
  const signer = kms ? kmsSigner(kms, await kms.address()) : cfg.localKeystore ? await localKeystoreSigner(cfg.localKeystore) : null;
  const signerAddress = signer ? signer.address : null;
  const helperEntry = signerAddress
    ? cfg.manifest.avana.operatorHelpers.find((h) => h.signer.toLowerCase() === signerAddress.toLowerCase())
    : cfg.manifest.avana.operatorHelpers[0];
  if (!helperEntry) throw new Error(`no operator helper in the manifest for chain ${cfg.chain.id}`);
  // The spend log (runtime/budget.ts): each included transaction's cost by class, market and Hub; the class budgets
  // (M-32) and the spend anomaly (M-31) are judged from it at each head.
  const spendBook = new SpendBook(cfg.chain.id, cfg.dailyBudgetWei, cfg.gasDailySpendWei ?? 0n);
  const hubs = new HubBook((spoke) => primary.readContract({ address: cfg.manifest.avana.marketRegistry.address, abi: marketRegistryAbi, functionName: "hubOf", args: [spoke] }));
  /**
   * D4: a liquidation's reward Kr valued in wei of the gas token, from the debt asset's accepted USD price (its
   * DebtOracle; GHO's is fixed at 1 USD) and KEEPER_NATIVE_USD_FEED_<CHAIN>, at the block it was mined. Without that
   * feed the metric is not reported; the spend line still carries the cost.
   */
  const smallAccount = async (s: IncludedSpend) => {
    const feed = cfg.nativeUsdFeed;
    const reward = liquidationReward(s.logs, cfg.manifest.avana.lpVaultSwap.address);
    if (!feed || !reward) return;
    const reserve = cfg.manifest.debtReserves.find((r) => r.asset.toLowerCase() === reward.debtAsset.toLowerCase());
    if (!reserve) return;
    const at = { blockNumber: s.blockNumber } as const;
    const assetUsd8 = reserve.debtOracle
      ? (await primary.readContract({ ...at, address: reserve.debtOracle.address, abi: debtOracleAbi, functionName: "lastAcceptedPrice" }))[0]
      : 10n ** 8n;
    const [round, feedDecimals] = await Promise.all([
      primary.readContract({ ...at, address: feed, abi: NATIVE_FEED_ABI, functionName: "latestRoundData" }),
      primary.readContract({ ...at, address: feed, abi: NATIVE_FEED_ABI, functionName: "decimals" }),
    ]);
    if (round[1] <= 0n) return;
    const rewardWei = valueInWei(reward.keeperReward, reserve.decimals, assetUsd8 * 10n ** BigInt(feedDecimals), round[1] * 10n ** 8n);
    chainMetrics.smallAccounts.record({ hub: s.hub, gasCostWei: s.costWei, rewardWei });
  };
  const spendSink: SpendSink = {
    attribute: async (plan) => {
      const a = attributeSubject(cfg.manifest, plan.subject, (proxy) => cache.ofChain(cfg.chain.id).find((x) => x.proxy.toLowerCase() === proxy.toLowerCase())?.marketId);
      return { market: a.market, hub: await hubs.of(a.spoke) };
    },
    record: (s) => {
      spendBook.record({ chainId: cfg.chain.id, jobClass: s.plan.jobClass, at: s.at, costWei: s.costWei, market: s.market, hub: s.hub });
      chainMetrics.spent({ jobClass: s.plan.jobClass, hub: s.hub, costWei: s.costWei });
      if (s.plan.job === "liquidation") {
        smallAccount(s).catch((err: unknown) => line({ type: "keeper.smallAccountSpend", chainId: cfg.chain.id, txHash: s.txHash, error: String(err) }));
      }
    },
  };
  const submitter = signer
    ? new Submitter(cfg, primary, signer, inventory, post, helperEntry.fundingSafe, {
        ceilingWei: cfg.gasCeilingWei!,
        l1Fee: paysL1DataFee(cfg.chain) ? (tx) => l1DataFee(primary, tx) : null,
        onCeiling: (detail) =>
          void alerts.send({ signal: "M-17", level: "page", chainId: cfg.chain.id, blockNumber: 0n, subject: detail.subject ?? "", detail: { ...detail, note: "gas ceiling" } }),
        fees: cfg.feePolicy,
        budget: spendBook,
        spend: spendSink,
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
  /**
   * One provider's sweep: logs from `fromBlock` to its head. Returns the head read to and the provider's finalized block
   * before the read, where the next incremental sweep starts: logs at or below a finalized block never change.
   */
  const sweep = async (client: PublicClient, fromBlock: bigint) => {
    const finalized = (await client.getBlock({ blockTag: "finalized" })).number;
    const through = await backfill(cfg, client, cache, fromBlock, await client.getBlockNumber());
    return { through, next: finalized };
  };
  const s1 = await sweep(primary, start);
  const s2 = await sweep(fallback, start);
  // Where each provider's next incremental sweep starts.
  const resume = { primary: s1.next, fallback: s2.next };
  // The block both providers' logs have been read to; set again by each sweep.
  let rpcThrough = s1.through < s2.through ? s1.through : s2.through;
  reportOneSided(cfg, cache, rpcThrough, stream);

  // M-30 at each head, after the stream poll: warns on any one-sided account, pages once one stays one-sided for
  // KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS, and stops (the monitor then resolves it) once the sources agree.
  const discovery = new DiscoveryWatch(cfg.chain, config.discoveryPageSeconds);
  const judgeDiscovery = (head: bigint) => {
    const through = discoveryThrough(rpcThrough, stream.indexedBlock);
    const r = discovery.check(through < 0n ? [] : cache.oneSided(cfg.chain.id, through), head, through);
    chainMetrics.indexedBlock = stream.indexedBlock < 0n ? null : stream.indexedBlock;
    chainMetrics.rpcThrough = rpcThrough;
    chainMetrics.accounts = cache.ofChain(cfg.chain.id).length;
    chainMetrics.oneSided = { indexer: r.indexerOnly, rpc: r.rpcOnly };
    if (r.alert) void alerts.send(r.alert);
  };

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

  const heldFunding = new HeldAlerts(alerts);
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
    // The indexer stream refreshes the cache before each pass; its reconnect or reorg re-reads RPC logs from finality
    // first. The two discovery sources are then compared (M-30).
    beforePass: async (head) => {
      await pollStream();
      judgeDiscovery(head.number);
    },
    funding: spendAndFunding(spendBook, chainMetrics, alerts, heldFunding, fundingCheck({
      chainId: cfg.chain.id,
      primary,
      fallback,
      alerts: heldFunding.sink,
      assets: [...new Map(cfg.manifest.debtReserves.map((r) => [r.asset.toLowerCase(), r.asset])).values()],
      fundingSafe: helperEntry.fundingSafe,
      helper: helperEntry.address,
      largest: cfg.largestDebtToCover,
      free: (asset, safeBalance) => inventory.free(cfg.chain.id, asset, safeBalance),
      gas: signerAddress ? { signer: signerAddress, dailyFloorWei: cfg.gasDailySpendWei!, spend: new SpendTracker() } : null,
      standby: cfg.standby,
    })),
    processed: (head) => {
      lastHead = head.number;
      chainMetrics.processed(head.number);
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

  // Sweep: enumerate proxies from logs over both providers every 10 minutes, then compare with the indexer's set. Each
  // sweep resumes from the provider's finalized block of the previous one; once a day it starts again from the
  // manifest's start block, which repairs anything a provider left out of an earlier answer.
  let lastFull = Date.now();
  setInterval(() => {
    running = running.then(async () => {
      const full = Date.now() - lastFull >= FULL_SWEEP_MS;
      if (full) lastFull = Date.now();
      const a = await sweep(primary, full ? start : resume.primary);
      const b = await sweep(fallback, full ? start : resume.fallback);
      resume.primary = a.next;
      resume.fallback = b.next;
      rpcThrough = a.through < b.through ? a.through : b.through;
      reportOneSided(cfg, cache, rpcThrough, stream);
    });
  }, SWEEP_MS);
}
