// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Configuration from the environment (.env.example lists every name).

import { listEnv, optionalEnv } from "@avana/services-common";
import { TEST_NETWORK_IDS } from "./chain.ts";
import type { ChainName } from "./grants.ts";
import type { ChainKind } from "./setup.ts";

export interface FaucetConfig {
  readonly host: string;
  readonly port: number;
  readonly dataDir: string;
  /** "fork" on the local chains; "testnet" on Sepolia and Base Sepolia (Ethereum and Base of the test networks). */
  readonly kind: ChainKind;
  /** Chain ids the faucet accepts; any other chain is refused. */
  readonly chainIds: readonly number[];
  readonly rpc: Readonly<Partial<Record<ChainName, string>>>;
  /** Each chain's release manifest (its token and feed addresses): FAUCET_MANIFEST_ETHEREUM, FAUCET_MANIFEST_BASE. */
  readonly manifest: Readonly<Partial<Record<ChainName, string>>>;
  /**
   * On a test network, the test tokens' minter: its encrypted keystore (FAUCET_SIGNER_KEYSTORE) and the file of its
   * password (FAUCET_SIGNER_PASSWORD_FILE), both paths outside the repository; undefined on a fork, which holds no key.
   */
  readonly signer: { readonly keystore: string; readonly passwordFile: string } | undefined;
  /** On a test network, the test ETH a wallet is topped up to from the signer (FAUCET_GAS_ETH, default "0": none). */
  readonly gasEth: string;
}

export function loadConfig(env: NodeJS.ProcessEnv): FaucetConfig {
  const kind = optionalEnv(env, "FAUCET_CHAIN_KIND") ?? "fork";
  if (kind !== "fork" && kind !== "testnet") throw new Error(`FAUCET_CHAIN_KIND must be fork or testnet, not ${kind}`);
  const defaults = kind === "testnet" ? TEST_NETWORK_IDS.map(String) : ["31337", "31338"];
  const chainIds = (listEnv(env, "FAUCET_CHAIN_IDS").length > 0 ? listEnv(env, "FAUCET_CHAIN_IDS") : defaults).map(Number);
  if (chainIds.some((id) => !Number.isSafeInteger(id) || id <= 0)) throw new Error("FAUCET_CHAIN_IDS must be chain ids");
  if (chainIds.includes(1) || chainIds.includes(8453)) throw new Error("FAUCET_CHAIN_IDS must not include Ethereum or Base mainnet");
  if (kind === "testnet" && chainIds.some((id) => !TEST_NETWORK_IDS.includes(id))) {
    throw new Error(`FAUCET_CHAIN_IDS of a test-network faucet must be test networks (${TEST_NETWORK_IDS.join(", ")})`);
  }
  const keystore = optionalEnv(env, "FAUCET_SIGNER_KEYSTORE");
  const passwordFile = optionalEnv(env, "FAUCET_SIGNER_PASSWORD_FILE");
  if (kind === "fork" && (keystore || passwordFile)) throw new Error("a fork faucet holds no key: unset FAUCET_SIGNER_KEYSTORE and FAUCET_SIGNER_PASSWORD_FILE");
  if (kind === "testnet" && (!keystore || !passwordFile)) throw new Error("a test-network faucet needs FAUCET_SIGNER_KEYSTORE and FAUCET_SIGNER_PASSWORD_FILE");
  const gasEth = optionalEnv(env, "FAUCET_GAS_ETH") ?? "0";
  if (!/^\d+(\.\d{1,18})?$/.test(gasEth)) throw new Error("FAUCET_GAS_ETH must be an amount of ETH, such as 0.01");
  const rpc: Partial<Record<ChainName, string>> = {};
  const ethereum = optionalEnv(env, "FAUCET_RPC_ETHEREUM");
  const base = optionalEnv(env, "FAUCET_RPC_BASE");
  if (ethereum) rpc.ethereum = ethereum;
  if (base) rpc.base = base;
  if (!rpc.ethereum && !rpc.base) throw new Error("set FAUCET_RPC_ETHEREUM and/or FAUCET_RPC_BASE");
  const manifest: Partial<Record<ChainName, string>> = {};
  const ethereumManifest = optionalEnv(env, "FAUCET_MANIFEST_ETHEREUM");
  const baseManifest = optionalEnv(env, "FAUCET_MANIFEST_BASE");
  if (ethereumManifest) manifest.ethereum = ethereumManifest;
  if (baseManifest) manifest.base = baseManifest;
  const host = optionalEnv(env, "FAUCET_HOST") ?? "127.0.0.1";
  if (host !== "127.0.0.1" && host !== "localhost") throw new Error("the faucet listens on 127.0.0.1 only");
  return {
    host,
    port: Number(optionalEnv(env, "FAUCET_PORT") ?? "42080"),
    dataDir: optionalEnv(env, "FAUCET_DATA_DIR") ?? ".faucet",
    kind,
    chainIds,
    rpc,
    manifest,
    signer: keystore && passwordFile ? { keystore, passwordFile } : undefined,
    gasEth,
  };
}
