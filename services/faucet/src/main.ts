// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Starts the faucet: one setup strategy per configured chain, the grant store and the HTTP endpoint.

import { createPublicClient, http } from "viem";
import { loadConfig } from "./config.ts";
import { Faucet } from "./faucet.ts";
import type { ChainName } from "./grants.ts";
import { faucetServer } from "./server.ts";
import { forkStrategy, testnetStrategy, type SetupStrategy } from "./setup.ts";
import { GrantStore } from "./store.ts";

const config = loadConfig(process.env);
const strategies: Partial<Record<ChainName, SetupStrategy>> = {};
for (const [chain, url] of Object.entries(config.rpc) as [ChainName, string][]) {
  const rpc = createPublicClient({ transport: http(url) });
  strategies[chain] = config.kind === "fork" ? forkStrategy(rpc, config.chainIds) : testnetStrategy();
}

const server = faucetServer(new Faucet(strategies, new GrantStore(config.dataDir)));
server.listen(config.port, config.host, () => {
  process.stdout.write(`faucet listening on http://${config.host}:${config.port} (${config.kind}; chains ${Object.keys(strategies).join(", ")})\n`);
});
