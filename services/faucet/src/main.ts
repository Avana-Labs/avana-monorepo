// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Starts the faucet: one setup strategy per configured chain, the grant store and the HTTP endpoint. On a test network
// the minter's keystore is decrypted in memory (never written) and signs the grants' mints.

import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { decryptKeystore } from "@avana/services-common/keystore";
import { loadConfig } from "./config.ts";
import { Faucet } from "./faucet.ts";
import type { ChainName } from "./grants.ts";
import { faucetServer } from "./server.ts";
import { forkStrategy, testnetStrategy, type Minter, type SetupStrategy } from "./setup.ts";
import { loadExternal, loadPositionsManifest } from "./manifest.ts";
import { GrantStore } from "./store.ts";

const config = loadConfig(process.env);
const account = config.signer
  ? privateKeyToAccount(await decryptKeystore(readFileSync(config.signer.keystore, "utf8"), readFileSync(config.signer.passwordFile, "utf8").replace(/\r?\n$/, "")))
  : undefined;

/** The minter on one chain: viem's wallet client with the keystore's account, receipts read from the same RPC. */
function minterOn(url: string, client: PublicClient): Minter {
  const wallet = createWalletClient({ account: account!, transport: http(url) });
  return {
    address: account!.address,
    nonce: () => client.getTransactionCount({ address: account!.address, blockTag: "pending" }),
    send: (tx) => wallet.sendTransaction({ to: tx.to, data: tx.data, value: tx.value, nonce: tx.nonce, chain: null }),
    confirmed: async (hash) => (await client.waitForTransactionReceipt({ hash, timeout: 180_000 })).status === "success",
  };
}

const strategies: Partial<Record<ChainName, SetupStrategy>> = {};
for (const [chain, url] of Object.entries(config.rpc) as [ChainName, string][]) {
  const rpc = createPublicClient({ transport: http(url) }) as PublicClient;
  const manifest = config.manifest[chain];
  strategies[chain] =
    config.kind === "fork"
      ? forkStrategy(rpc, config.chainIds, loadExternal(manifest), loadPositionsManifest(manifest))
      : testnetStrategy({ rpc, allowedChainIds: config.chainIds, external: loadExternal(manifest), minter: minterOn(url, rpc), gasEth: config.gasEth });
}

const server = faucetServer(new Faucet(strategies, new GrantStore(config.dataDir)));
server.listen(config.port, config.host, () => {
  const signer = account ? `; minter ${account.address}` : "";
  process.stdout.write(`faucet listening on http://${config.host}:${config.port} (${config.kind}; chains ${Object.keys(strategies).join(", ")}${signer})\n`);
});
