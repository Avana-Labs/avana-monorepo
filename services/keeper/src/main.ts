// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot runner: loads its configuration and the LiquidationBot's keystore signer, starts the kill switch and the
// metrics endpoint, then runs one pass per poll interval over every integration of the release manifest. Any startup
// failure stops the process before it can sign.
//
//   AVANA_MANIFEST=/manifests/base-v1.0.0.json LIQUIDATION_BOT_RPC_URL=... LIQUIDATION_BOT_CHAIN_ID=8453 \
//   LIQUIDATION_BOT_KEYSTORE=/keys/avana-liquidator LIQUIDATION_BOT_PASSWORD_FILE=/run/secrets/liquidator \
//   KEEPER_HALT_STATE_PATH=/data/halt.json npm start

import { createServer } from "node:http";
import { setTimeout as sleep } from "node:timers/promises";
import { createPublicClient, http } from "viem";
import { AccountSet, LiquidationBot, loadSigner, viemChain } from "@avana/liquidator/bot";
import { monitorSink, teeSink } from "./monitorSink.ts";
import { integrationsOf, loadRunnerConfig, spokeDebtReservesOf } from "./config.ts";
import { readHalt, startKillSwitch } from "./killSwitch.ts";
import { type Instance, Runner, instanceConfig } from "./runner.ts";
import { IndexerStream, PAGES_PER_PASS, accountsFromRecords, readStreamKey } from "./stream.ts";
import type { Alert } from "./alerts.ts";

const log = (message: string, fields: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ t: new Date().toISOString(), type: "keeper", message, ...fields }, (_, v) => (typeof v === "bigint" ? v.toString() : v)));

process.on("uncaughtException", (e) => {
  log("fatal", { message: e.message });
  process.exit(1);
});
process.on("unhandledRejection", (e) => {
  log("fatal", { message: e instanceof Error ? e.message : String(e) });
  process.exit(1);
});

async function main(): Promise<void> {
  const config = loadRunnerConfig(process.env);
  const { settings, manifest } = config;
  const signer = await loadSigner(settings.keystore, settings.passwordFile);
  const chain = viemChain(settings.rpcUrl, settings.chainId, signer);
  const reserves = spokeDebtReservesOf(manifest);
  const instances: Instance[] = integrationsOf(manifest, signer.address).map((x) => ({
    integrationId: x.integrationId,
    adapter: x.aaveAdapter.toLowerCase(),
    bot: new LiquidationBot(chain, instanceConfig(settings, x, reserves), signer.address, (m, f) => log(m, { integrationId: x.integrationId, ...f })),
    rpcAccounts: new AccountSet(chain, x.aaveAdapter, BigInt(Math.min(...manifest.avana.integrations.map((i) => i.aaveAdapter.startBlock)))),
  }));
  if (!manifest.roles.keepers.some((k) => k.toLowerCase() === signer.address.toLowerCase())) {
    log("warning: this signer is not in the RiskModules' keeper registry of the manifest", { signer: signer.address });
  }

  const state = { halted: readHalt(config.haltStatePath) };
  if (config.killSwitch) startKillSwitch({ ...config.killSwitch, statePath: config.haltStatePath }, state, (halted, by) => log(halted ? "halted" : "resumed", { by }));

  const logSink = { send: async (a: Alert) => log("alert", { ...a }) };
  const monitor = config.monitor ? monitorSink(config.monitor, { log: (r) => log("monitorSink", r) }) : null;
  const sink = monitor ? teeSink(logSink, monitor) : logSink;

  let stream: (() => Promise<{ ok: boolean; accounts: ReadonlyMap<string, readonly { account: `0x${string}`; marketId: bigint }[]> }>) | null = null;
  if (config.indexer) {
    const s = new IndexerStream(config.indexer.url, settings.chainId, readStreamKey(config.indexer.keyFile));
    let first = true;
    stream = async () => {
      const r = await s.poll(first ? Number.MAX_SAFE_INTEGER : PAGES_PER_PASS);
      first = r.kind !== "ok" || !r.caughtUp ? first : false;
      return { ok: r.kind === "ok", accounts: accountsFromRecords(r.records) };
    };
  }
  const runner = new Runner(settings.chainId, instances, sink, state, stream, (b) => monitor?.heartbeat(b), log);

  const counters = { passes: 0, liquidations: 0, failures: 0, lastBlock: 0n };
  if (config.metricsPort !== null) {
    createServer((req, res) => {
      if (req.url !== "/metrics") return void res.writeHead(404).end();
      res.writeHead(200, { "content-type": "text/plain; version=0.0.4" }).end(
        [
          `keeper_passes_total ${counters.passes}`,
          `keeper_liquidations_sent_total ${counters.liquidations}`,
          `keeper_liquidation_failures_total ${counters.failures}`,
          `keeper_last_block ${counters.lastBlock}`,
          `keeper_halted ${state.halted ? 1 : 0}`,
        ].join("\n") + "\n",
      );
    }).listen(config.metricsPort);
  }

  const client = createPublicClient({ transport: http(settings.rpcUrl) });
  log("started", { signer: signer.address, chainId: settings.chainId, integrations: instances.map((i) => i.integrationId), stream: config.indexer !== null, monitor: config.monitor?.instance ?? null });
  for (;;) {
    try {
      const block = await client.getBlock();
      const report = await runner.pass({ number: block.number, timestamp: Number(block.timestamp) });
      counters.passes++;
      counters.lastBlock = block.number;
      for (const o of report.outcomes) {
        if ((o as { hash?: string }).hash) counters.liquidations++;
        if (o.decision.kind === "error") counters.failures++;
        log("outcome", { integrationId: o.integrationId, account: o.account, marketId: o.marketId, kind: o.decision.kind, hash: (o as { hash?: string }).hash ?? null });
      }
    } catch (e) {
      log("pass failed", { message: e instanceof Error ? e.message : String(e) });
    }
    await sleep(settings.pollMs);
  }
}

main().catch((e) => {
  log("fatal", { message: e instanceof Error ? e.message : String(e) });
  process.exit(1);
});
