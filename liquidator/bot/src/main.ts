// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Runs the bot: loads the settings and the keystore signer, then discovers accounts and liquidates every pass.
//
//   LIQUIDATION_BOT_KEYSTORE=~/.foundry/keystores/avana-liquidator LIQUIDATION_BOT_PASSWORD_FILE=/run/secrets/liquidator \
//   LIQUIDATION_BOT_RPC_URL=... LIQUIDATION_BOT_CHAIN_ID=8453 LIQUIDATION_BOT_ADAPTER=0x... LIQUIDATION_BOT_LIQUIDATION_MODULE=0x... \
//   LIQUIDATION_BOT_DEBT_RESERVES=1,2 npm start

import { setTimeout as sleep } from "node:timers/promises";
import { loadConfig } from "./config.ts";
import { AccountSet } from "./discovery.ts";
import { LiquidationBot } from "./pass.ts";
import { loadSigner } from "./signer.ts";
import { viemChain } from "./viemChain.ts";

const log = (message: string, fields: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ t: new Date().toISOString(), message, ...fields }, (_, v) => (typeof v === "bigint" ? v.toString() : v)));

async function main(): Promise<void> {
  const config = loadConfig(process.env);
  const signer = await loadSigner(config.keystore, config.passwordFile);
  const chain = viemChain(config.rpcUrl, config.chainId, signer);
  const accounts = new AccountSet(chain, config.adapter, config.fromBlock);
  const bot = new LiquidationBot(chain, config, signer.address, log);
  log("started", { operator: signer.address, flash: config.flashLiquidator ?? null });
  for (;;) {
    try {
      const outcomes = await bot.pass(await accounts.refresh());
      for (const o of outcomes) log("outcome", { account: o.account, kind: o.decision.kind, hash: o.hash ?? null });
    } catch (e) {
      log("pass failed", { message: e instanceof Error ? e.message : String(e) });
    }
    await sleep(config.pollMs);
  }
}

main().catch((e) => {
  log("fatal", { message: e instanceof Error ? e.message : String(e) });
  process.exit(1);
});
